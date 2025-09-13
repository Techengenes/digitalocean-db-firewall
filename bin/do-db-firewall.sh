#!/bin/bash
set -euo pipefail

# =============================================================================
# Database Access Management Script for CI/CD
# =============================================================================
# This script manages IP whitelisting for DigitalOcean managed databases
# during CI/CD pipeline execution with dynamic GitHub Actions runner IPs
# =============================================================================

# Default values
ACTION="${ACTION:-add}"
DATABASE_CLUSTER_ID="${DATABASE_CLUSTER_ID:-}"
REDIS_CLUSTER_ID="${REDIS_CLUSTER_ID:-}"
DIGITALOCEAN_ACCESS_TOKEN="${DIGITALOCEAN_ACCESS_TOKEN:-}"
VERBOSE="${VERBOSE:-false}"
TIMEOUT="${TIMEOUT:-300}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Global variables
CURRENT_IP=""
RULE_ID_POSTGRES=""
RULE_ID_REDIS=""

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

log_debug() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo -e "${CYAN}[DEBUG]${NC} $1"
    fi
}

# Usage function
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Manage IP access for DigitalOcean managed databases during CI/CD

OPTIONS:
    -a, --action ACTION             Action: add|remove|cleanup [default: add]
    --postgres-id CLUSTER_ID        PostgreSQL cluster ID
    --redis-id CLUSTER_ID           Redis/Valkey cluster ID
    --token TOKEN                   DigitalOcean API token
    --timeout TIMEOUT               Operation timeout in seconds [default: 300]
    -v, --verbose                   Verbose output
    -h, --help                      Show this help message

ACTIONS:
    add         Add current runner IP to database firewall rules
    remove      Remove specific IP from database firewall rules
    cleanup     Remove all CI-added IPs (based on description pattern)

EXAMPLES:
    # Add current IP to both databases
    $0 --action add --postgres-id abc123 --redis-id def456 --token \$DO_TOKEN

    # Remove current IP from databases
    $0 --action remove --postgres-id abc123 --redis-id def456 --token \$DO_TOKEN

    # Cleanup all CI-added IPs
    $0 --action cleanup --postgres-id abc123 --redis-id def456 --token \$DO_TOKEN

ENVIRONMENT VARIABLES:
    ACTION                  Action to perform
    DATABASE_CLUSTER_ID     PostgreSQL cluster ID
    REDIS_CLUSTER_ID        Redis/Valkey cluster ID
    DIGITALOCEAN_ACCESS_TOKEN           DigitalOcean API token
    VERBOSE                 Enable verbose output

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -a|--action)
                ACTION="$2"
                shift 2
                ;;
            --postgres-id)
                DATABASE_CLUSTER_ID="$2"
                shift 2
                ;;
            --redis-id)
                REDIS_CLUSTER_ID="$2"
                shift 2
                ;;
            --token)
                DIGITALOCEAN_ACCESS_TOKEN="$2"
                shift 2
                ;;
            --timeout)
                TIMEOUT="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE="true"
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# Validate inputs
validate_inputs() {
    log_debug "Validating inputs..."
    
    # Validate action
    case "$ACTION" in
        add|remove|cleanup)
            ;;
        *)
            log_error "Invalid action: $ACTION"
            log_error "Valid actions: add, remove, cleanup"
            exit 1
            ;;
    esac
    
    # Validate required parameters
    if [[ -z "$DIGITALOCEAN_ACCESS_TOKEN" ]]; then
        log_error "DigitalOcean API token is required (--token or DIGITALOCEAN_ACCESS_TOKEN)"
        exit 1
    fi
    
    if [[ -z "$DATABASE_CLUSTER_ID" ]] && [[ -z "$REDIS_CLUSTER_ID" ]]; then
        log_error "At least one cluster ID is required (--postgres-id or --redis-id)"
        exit 1
    fi
    
    log_success "Input validation passed"
}

# Check prerequisites
check_prerequisites() {
    log_debug "Checking prerequisites..."
    
    local missing_tools=()
    
    # Check curl
    if ! command -v curl &> /dev/null; then
        missing_tools+=("curl")
    fi
    
    # Check jq
    if ! command -v jq &> /dev/null; then
        missing_tools+=("jq")
    fi
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_error "Install missing tools:"
        for tool in "${missing_tools[@]}"; do
            case "$tool" in
                curl)
                    log_error "  - macOS: brew install curl"
                    log_error "  - Ubuntu/Debian: apt install curl"
                    ;;
                jq)
                    log_error "  - macOS: brew install jq"
                    log_error "  - Ubuntu/Debian: apt install jq"
                    ;;
            esac
        done
        exit 1
    fi
    
    log_success "Prerequisites check passed"
}

# Get current public IP
get_current_ip() {
    log_info "Getting current public IP..."
    
    # Try multiple IP detection services for reliability
    local ip_services=(
        "https://ipv4.icanhazip.com"
        "https://api.ipify.org"
        "https://checkip.amazonaws.com"
        "https://ifconfig.me/ip"
    )
    
    for service in "${ip_services[@]}"; do
        log_debug "Trying IP service: $service"
        
        if CURRENT_IP=$(curl -s --connect-timeout 10 --max-time 15 "$service" | tr -d '[:space:]'); then
            # Validate IP format
            if [[ "$CURRENT_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                log_success "Current IP detected: $CURRENT_IP"
                return 0
            fi
        fi
        
        log_debug "Failed to get IP from $service"
    done
    
    log_error "Failed to detect current public IP from all services"
    exit 1
}

# Make DigitalOcean API call
do_api_call() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"
    local output_file="${4:-/tmp/do_api_response.json}"
    
    log_debug "API Call: $method $endpoint"
    
    local curl_args=(
        -s
        -X "$method"
        -H "Authorization: Bearer $DIGITALOCEAN_ACCESS_TOKEN"
        -H "Content-Type: application/json"
        --connect-timeout 30
        --max-time 60
        -o "$output_file"
        -w "%{http_code}"
    )
    
    if [[ -n "$data" ]]; then
        curl_args+=(-d "$data")
    fi
    
    local http_code
    http_code=$(curl "${curl_args[@]}" "https://api.digitalocean.com/v2$endpoint")
    
    log_debug "HTTP response code: $http_code"
    
    # Check for successful response codes
    case "$http_code" in
        200|201|204)
            return 0
            ;;
        401)
            log_error "API authentication failed. Check DIGITALOCEAN_ACCESS_TOKEN"
            return 1
            ;;
        404)
            log_error "Resource not found. Check cluster IDs"
            return 1
            ;;
        429)
            log_warning "Rate limited. Waiting before retry..."
            sleep 5
            return 1
            ;;
        *)
            log_error "API call failed with HTTP $http_code"
            if [[ -f "$output_file" ]]; then
                log_debug "Response: $(cat "$output_file")"
            fi
            return 1
            ;;
    esac
}

# Add IP to firewall rules
add_ip_to_firewall() {
    local cluster_id="$1"
    local db_type="$2"  # postgres or redis
    
    log_info "Adding IP $CURRENT_IP to $db_type cluster $cluster_id..."
    
    # First, get current firewall rules
    local endpoint="/databases/$cluster_id/firewall"
    local current_rules_file="/tmp/current_firewall_${db_type}.json"
    
    if ! do_api_call "GET" "$endpoint" "" "$current_rules_file"; then
        log_error "Failed to get current firewall rules for $db_type"
        return 1
    fi
    
    # Extract existing rules and add new rule
    local new_rule
    new_rule=$(jq -n \
        --arg ip "$CURRENT_IP" \
        --arg description "GitHub Actions CI/CD - $(date -u +%Y-%m-%dT%H:%M:%SZ) - Job: ${GITHUB_RUN_ID:-manual}" \
        '{
            type: "ip_addr",
            value: $ip,
            description: $description
        }')
    
    # Combine existing rules with new rule
    local all_rules_data
    all_rules_data=$(jq --argjson newRule "$new_rule" \
        '.rules += [$newRule] | {rules: .rules}' \
        "$current_rules_file")
    
    log_debug "Updated rules data: $all_rules_data"
    
    # Make API call to update firewall rules (PUT replaces all rules)
    local response_file="/tmp/add_firewall_${db_type}.json"
    
    if do_api_call "PUT" "$endpoint" "$all_rules_data" "$response_file"; then
        log_success "IP $CURRENT_IP added to $db_type firewall"
        return 0
    else
        log_error "Failed to add IP to $db_type firewall"
        return 1
    fi
}

# Remove IP from firewall rules
remove_ip_from_firewall() {
    local cluster_id="$1"
    local db_type="$2"
    local specific_ip="${3:-$CURRENT_IP}"
    
    log_info "Removing IP $specific_ip from $db_type cluster $cluster_id..."
    
    # Get current firewall rules
    local endpoint="/databases/$cluster_id/firewall"
    local response_file="/tmp/get_firewall_${db_type}.json"
    
    if ! do_api_call "GET" "$endpoint" "" "$response_file"; then
        log_error "Failed to get current firewall rules for $db_type"
        return 1
    fi
    
    # Find rules with matching IP
    local rule_ids
    rule_ids=$(jq -r ".rules[] | select(.value == \"$specific_ip\") | .uuid" "$response_file" 2>/dev/null || echo "")
    
    if [[ -z "$rule_ids" ]]; then
        log_info "No firewall rules found for IP $specific_ip in $db_type cluster"
        return 0
    fi
    
    # Remove each matching rule
    local removed_count=0
    while IFS= read -r rule_id; do
        [[ -z "$rule_id" ]] && continue
        
        log_debug "Removing rule $rule_id from $db_type"
        
        if do_api_call "DELETE" "$endpoint/$rule_id" "" "/dev/null"; then
            log_success "Removed rule $rule_id from $db_type"
            ((removed_count++))
        else
            log_error "Failed to remove rule $rule_id from $db_type"
        fi
    done <<< "$rule_ids"
    
    log_info "Removed $removed_count firewall rule(s) for IP $specific_ip from $db_type"
    return 0
}

# Cleanup CI-added IPs
cleanup_ci_ips() {
    local cluster_id="$1"
    local db_type="$2"
    
    log_info "Cleaning up CI-added IPs from $db_type cluster $cluster_id..."
    
    # Get current firewall rules
    local endpoint="/databases/$cluster_id/firewall"
    local response_file="/tmp/cleanup_firewall_${db_type}.json"
    
    if ! do_api_call "GET" "$endpoint" "" "$response_file"; then
        log_error "Failed to get current firewall rules for $db_type"
        return 1
    fi
    
    # Find CI-added rules (based on description pattern)
    local rule_ids
    rule_ids=$(jq -r '.rules[] | select(.description | test("GitHub Actions CI/CD")) | .uuid' "$response_file" 2>/dev/null || echo "")
    
    if [[ -z "$rule_ids" ]]; then
        log_info "No CI-added firewall rules found in $db_type cluster"
        return 0
    fi
    
    # Remove each CI-added rule
    local removed_count=0
    while IFS= read -r rule_id; do
        [[ -z "$rule_id" ]] && continue
        
        log_debug "Removing CI rule $rule_id from $db_type"
        
        if do_api_call "DELETE" "$endpoint/$rule_id" "" "/dev/null"; then
            log_success "Removed CI rule $rule_id from $db_type"
            ((removed_count++))
        else
            log_error "Failed to remove CI rule $rule_id from $db_type"
        fi
        
        # Small delay to avoid rate limiting
        sleep 1
    done <<< "$rule_ids"
    
    log_info "Removed $removed_count CI-added firewall rule(s) from $db_type"
    return 0
}

# Wait for database connectivity
wait_for_connectivity() {
    local timeout="$TIMEOUT"
    local start_time=$(date +%s)
    
    log_info "Waiting for database connectivity (timeout: ${timeout}s)..."
    
    while true; do
        local current_time=$(date +%s)
        local elapsed=$((current_time - start_time))
        
        if [[ $elapsed -ge $timeout ]]; then
            log_error "Timeout waiting for database connectivity"
            return 1
        fi
        
        # Simple connectivity test (you can enhance this based on your needs)
        log_debug "Testing connectivity... (${elapsed}s elapsed)"
        
        # In a real scenario, you might test actual database connections here
        # For now, we'll wait a reasonable time for firewall rules to propagate
        if [[ $elapsed -ge 30 ]]; then
            log_success "Firewall rules should be active"
            return 0
        fi
        
        sleep 5
    done
}

# Cleanup function for script exit
cleanup_on_exit() {
    local exit_code=$?
    
    if [[ "$ACTION" == "add" ]] && [[ $exit_code -ne 0 ]]; then
        log_warning "Script failed, cleaning up added firewall rules..."
        
        # Remove rules we added (best effort)
        if [[ -n "$DATABASE_CLUSTER_ID" ]] && [[ -n "$RULE_ID_POSTGRES" ]]; then
            do_api_call "DELETE" "/databases/$DATABASE_CLUSTER_ID/firewall/$RULE_ID_POSTGRES" "" "/dev/null" || true
        fi
        
        if [[ -n "$REDIS_CLUSTER_ID" ]] && [[ -n "$RULE_ID_REDIS" ]]; then
            do_api_call "DELETE" "/databases/$REDIS_CLUSTER_ID/firewall/$RULE_ID_REDIS" "" "/dev/null" || true
        fi
    fi
    
    # Cleanup temp files
    rm -f /tmp/do_api_response.json /tmp/add_firewall_*.json /tmp/get_firewall_*.json /tmp/cleanup_firewall_*.json
}

# Main function
main() {
    # Setup cleanup on exit
    trap cleanup_on_exit EXIT
    
    log_info "=== DigitalOcean Database Access Management ==="
    
    # Parse arguments
    parse_args "$@"
    
    # Validate inputs
    validate_inputs
    
    # Check prerequisites
    check_prerequisites
    
    # Get current IP (except for cleanup action)
    if [[ "$ACTION" != "cleanup" ]]; then
        get_current_ip
    fi
    
    log_info "Action: $ACTION"
    if [[ -n "$CURRENT_IP" ]]; then
        log_info "Current IP: $CURRENT_IP"
    fi
    if [[ -n "$DATABASE_CLUSTER_ID" ]]; then
        log_info "PostgreSQL Cluster: $DATABASE_CLUSTER_ID"
    fi
    if [[ -n "$REDIS_CLUSTER_ID" ]]; then
        log_info "Redis/Valkey Cluster: $REDIS_CLUSTER_ID"
    fi
    
    # Execute action
    case "$ACTION" in
        add)
            local success=true
            
            if [[ -n "$DATABASE_CLUSTER_ID" ]]; then
                if ! add_ip_to_firewall "$DATABASE_CLUSTER_ID" "postgres"; then
                    success=false
                fi
            fi
            
            if [[ -n "$REDIS_CLUSTER_ID" ]]; then
                if ! add_ip_to_firewall "$REDIS_CLUSTER_ID" "redis"; then
                    success=false
                fi
            fi
            
            if [[ "$success" == "true" ]]; then
                wait_for_connectivity
                log_success "IP access successfully added to databases"
            else
                log_error "Failed to add IP access to some databases"
                exit 1
            fi
            ;;
            
        remove)
            if [[ -n "$DATABASE_CLUSTER_ID" ]]; then
                remove_ip_from_firewall "$DATABASE_CLUSTER_ID" "postgres"
            fi
            
            if [[ -n "$REDIS_CLUSTER_ID" ]]; then
                remove_ip_from_firewall "$REDIS_CLUSTER_ID" "redis"
            fi
            
            log_success "IP removal completed"
            ;;
            
        cleanup)
            if [[ -n "$DATABASE_CLUSTER_ID" ]]; then
                cleanup_ci_ips "$DATABASE_CLUSTER_ID" "postgres"
            fi
            
            if [[ -n "$REDIS_CLUSTER_ID" ]]; then
                cleanup_ci_ips "$REDIS_CLUSTER_ID" "redis"
            fi
            
            log_success "CI cleanup completed"
            ;;
    esac
    
    log_success "=== Database Access Management Complete ==="
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi