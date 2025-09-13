# DigitalOcean Database Firewall Manager

[![npm version](https://badge.fury.io/js/digitalocean-db-firewall.svg)](https://badge.fury.io/js/digitalocean-db-firewall)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A specialized command-line tool for managing DigitalOcean managed database IP whitelisting, designed for CI/CD pipelines and team access management.

## Why This Tool?

Managing database access in CI/CD environments is challenging because:
- 🔄 **Dynamic IPs**: GitHub Actions and other CI runners use changing IP addresses
- 🧹 **Cleanup Required**: Failed deployments can leave stale firewall rules
- 📊 **Multiple Databases**: Teams often need access to both PostgreSQL and Redis
- 🏷️ **Tracking**: Hard to identify which rules were added by automation vs. manual

This tool solves these problems with intelligent automation, robust error handling, and automatic cleanup.

## Key Features

- ✅ **Automatic IP Detection** - Uses multiple services for reliability
- 🧹 **Smart Cleanup** - Removes old CI rules automatically  
- 🏷️ **Rule Labeling** - Tags rules with timestamps and job IDs
- 🔄 **Multi-Database** - Supports PostgreSQL and Redis/Valkey clusters
- 🛡️ **Error Recovery** - Cleans up on failure to prevent orphaned rules
- 📝 **Rich Logging** - Colored output with verbose debugging options
- ⚡ **Rate Limit Aware** - Handles DigitalOcean API limits gracefully

## Installation

### Global Installation (Recommended)
```bash
npm install -g digitalocean-db-firewall
```

### One-time Use
```bash
npx digitalocean-db-firewall --help
```

## Quick Start

### CI/CD Pipeline (GitHub Actions)
```yaml
- name: Allow database access
  run: |
    npx digitalocean-db-firewall add \
      --postgres-id ${{ secrets.POSTGRES_CLUSTER_ID }} \
      --redis-id ${{ secrets.REDIS_CLUSTER_ID }} \
      --token ${{ secrets.DO_TOKEN }}

- name: Run tests/deployment
  run: npm run deploy

- name: Cleanup database access
  if: always()
  run: |
    npx digitalocean-db-firewall remove \
      --postgres-id ${{ secrets.POSTGRES_CLUSTER_ID }} \
      --redis-id ${{ secrets.REDIS_CLUSTER_ID }} \
      --token ${{ secrets.DO_TOKEN }}
```

### Local Development
```bash
# Add your current IP for development
export DO_TOKEN="your-api-token"
npx digitalocean-db-firewall add --postgres-id abc123

# When done developing
npx digitalocean-db-firewall remove --postgres-id abc123
```

## Prerequisites

The tool requires these system dependencies:
- `curl` - For making API requests
- `jq` - For JSON processing

### Installing Prerequisites

**macOS:**
```bash
brew install curl jq
```

**Ubuntu/Debian:**
```bash
sudo apt update && sudo apt install curl jq
```

**Alpine Linux (Docker):**
```bash
apk add --no-cache curl jq bash
```

## Usage

```bash
do-db-firewall [OPTIONS]
```

### Options

| Option | Description | Default |
|--------|-------------|---------|
| `-a, --action ACTION` | Action: `add`\|`remove`\|`cleanup` | `add` |
| `--postgres-id CLUSTER_ID` | PostgreSQL cluster ID | - |
| `--redis-id CLUSTER_ID` | Redis/Valkey cluster ID | - |
| `--token TOKEN` | DigitalOcean API token | - |
| `--timeout TIMEOUT` | Operation timeout in seconds | `300` |
| `-v, --verbose` | Enable verbose output | `false` |
| `-h, --help` | Show help message | - |

### Actions

| Action | Description |
|--------|-------------|
| `add` | Add current IP to database firewall rules |
| `remove` | Remove current IP from database firewall rules |
| `cleanup` | Remove all CI-added IPs (identified by description pattern) |

### Environment Variables

You can use environment variables instead of command-line options:

| Variable | Description |
|----------|-------------|
| `ACTION` | Action to perform |
| `DATABASE_CLUSTER_ID` | PostgreSQL cluster ID |
| `REDIS_CLUSTER_ID` | Redis/Valkey cluster ID |
| `DIGITALOCEAN_ACCESS_TOKEN` | DigitalOcean API token |
| `VERBOSE` | Enable verbose output (`true`/`false`) |

## Examples

### Basic Usage

**Add current IP to both databases:**
```bash
do-db-firewall --action add \
  --postgres-id abc123 \
  --redis-id def456 \
  --token $DO_TOKEN
```

**Remove current IP from databases:**
```bash
do-db-firewall --action remove \
  --postgres-id abc123 \
  --redis-id def456 \
  --token $DO_TOKEN
```

**Cleanup all CI-added IPs:**
```bash
do-db-firewall --action cleanup \
  --postgres-id abc123 \
  --redis-id def456 \
  --token $DO_TOKEN
```

### Environment Variables

```bash
export DIGITALOCEAN_ACCESS_TOKEN="dop_v1_1234567890abcdef"
export DATABASE_CLUSTER_ID="db-postgresql-abc123"
export REDIS_CLUSTER_ID="db-redis-def456"

# Simple add
do-db-firewall --action add

# With verbose logging
VERBOSE=true do-db-firewall --action add
```

### CI/CD Integration

**GitHub Actions:**
```yaml
name: Deploy with Database Access

env:
  DO_TOKEN: ${{ secrets.DIGITALOCEAN_TOKEN }}
  POSTGRES_ID: ${{ secrets.POSTGRES_CLUSTER_ID }}
  REDIS_ID: ${{ secrets.REDIS_CLUSTER_ID }}

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Allow database access
        run: |
          npx digitalocean-db-firewall add \
            --postgres-id $POSTGRES_ID \
            --redis-id $REDIS_ID \
            --token $DO_TOKEN
      
      - name: Run migrations and tests
        run: |
          npm run migrate
          npm run test:integration
      
      - name: Deploy application
        run: npm run deploy
      
      - name: Cleanup database access
        if: always()
        run: |
          npx digitalocean-db-firewall remove \
            --postgres-id $POSTGRES_ID \
            --redis-id $REDIS_ID \
            --token $DO_TOKEN
```

**GitLab CI:**
```yaml
before_script:
  - npx digitalocean-db-firewall add --postgres-id $POSTGRES_ID --token $DO_TOKEN

after_script:
  - npx digitalocean-db-firewall remove --postgres-id $POSTGRES_ID --token $DO_TOKEN
```

## Setup Guide

### 1. Get Your Cluster IDs

Find your database cluster IDs in the DigitalOcean Control Panel:

1. Go to **Databases** in the sidebar
2. Click on your database cluster
3. The cluster ID is in the URL: `https://cloud.digitalocean.com/databases/db-postgresql-abc123`
4. Or copy from the "Connection Details" section

### 2. Create a DigitalOcean API Token

1. Go to **API** in the DigitalOcean Control Panel
2. Click **Generate New Token**
3. Name: `database-firewall-access` (or similar)
4. Scopes: Select **Read** and **Write** for **Databases**
5. Copy the token immediately (it won't be shown again)

### 3. Store Credentials Securely

**GitHub Actions:**
- Go to repository Settings → Secrets and variables → Actions
- Add secrets:
  - `DIGITALOCEAN_TOKEN`: Your API token
  - `POSTGRES_CLUSTER_ID`: Your PostgreSQL cluster ID
  - `REDIS_CLUSTER_ID`: Your Redis cluster ID (if applicable)

**Local Development:**
```bash
# Add to your shell profile (.bashrc, .zshrc, etc.)
export DIGITALOCEAN_ACCESS_TOKEN="dop_v1_your_token_here"
export DATABASE_CLUSTER_ID="db-postgresql-abc123"
```

## Error Handling & Recovery

The tool includes robust error handling:

- **Automatic Cleanup**: If adding rules fails, it removes any rules that were successfully added
- **Rate Limiting**: Automatically retries with delays when hitting API limits
- **Multiple IP Services**: Falls back to other services if IP detection fails
- **Detailed Logging**: Use `--verbose` flag to see detailed API responses
- **Timeout Protection**: Operations timeout after 5 minutes by default

## Troubleshooting

### Common Issues

**"Missing required tools: curl jq"**
```bash
# macOS
brew install curl jq

# Ubuntu/Debian  
sudo apt install curl jq

# Alpine (Docker)
apk add curl jq bash
```

**"API authentication failed"**
- Verify your token starts with `dop_v1_`
- Check token has database read/write permissions
- Ensure token hasn't expired

**"Resource not found"**
- Double-check cluster IDs in DigitalOcean dashboard
- Ensure clusters exist and are active
- Verify token has access to the specific clusters

**"Failed to detect current public IP"**
- Check internet connectivity
- Try with `--verbose` to see which IP services are failing
- Firewall might be blocking outbound requests

### Debug Mode

Enable verbose logging to see detailed API interactions:

```bash
do-db-firewall --action add --postgres-id abc123 --token $TOKEN --verbose
```

## Security Best Practices

- ✅ **Never commit tokens** to version control
- ✅ **Use environment variables** or secret management systems
- ✅ **Rotate tokens regularly** (every 90 days recommended)
- ✅ **Use minimal permissions** (database read/write only)
- ✅ **Enable cleanup** in CI/CD failure scenarios
- ✅ **Monitor firewall rules** periodically for stale entries

## Contributing

We welcome contributions! Please see our [Contributing Guide](CONTRIBUTING.md) for details.

### Development Setup

```bash
git clone https://github.com/yourusername/digitalocean-db-firewall.git
cd digitalocean-db-firewall
npm install
```

### Running Tests

```bash
npm test
```

### Local Testing

```bash
# Test with your own databases (be careful!)
./bin/do-db-firewall.sh --action add --postgres-id your-test-db --token $TOKEN --verbose
```

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Support

- 🐛 **Bug Reports**: [GitHub Issues](https://github.com/yourusername/digitalocean-db-firewall/issues)
- 💡 **Feature Requests**: [GitHub Discussions](https://github.com/yourusername/digitalocean-db-firewall/discussions)
- 📖 **Documentation**: [Wiki](https://github.com/yourusername/digitalocean-db-firewall/wiki)

## Related Tools

- [DigitalOcean CLI (doctl)](https://docs.digitalocean.com/reference/doctl/) - Official DigitalOcean command-line tool
- [DigitalOcean API](https://docs.digitalocean.com/reference/api/) - Full API documentation
- [Terraform DigitalOcean Provider](https://registry.terraform.io/providers/digitalocean/digitalocean/latest) - Infrastructure as Code

---

**Made with ❤️ by Teceengenes Engineering team for the DigitalOcean developer community**