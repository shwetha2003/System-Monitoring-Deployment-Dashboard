#!/bin/bash

# System Monitoring Dashboard Deployment Script
# Usage: ./deploy.sh [environment]

set -e  # Exit on error

ENVIRONMENT=${1:-staging}
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/backups/monitoring_${TIMESTAMP}"
LOG_FILE="/var/log/monitoring_deploy_${TIMESTAMP}.log"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}" | tee -a "$LOG_FILE"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}" | tee -a "$LOG_FILE"
    exit 1
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}" | tee -a "$LOG_FILE"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root"
fi

# Load environment variables
if [ -f ".env.${ENVIRONMENT}" ]; then
    log "Loading environment variables from .env.${ENVIRONMENT}"
    export $(cat .env.${ENVIRONMENT} | grep -v '^#' | xargs)
elif [ -f ".env" ]; then
    log "Loading environment variables from .env"
    export $(cat .env | grep -v '^#' | xargs)
else
    error "No environment file found"
fi

# Function to check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check Docker
    if ! command -v docker &> /dev/null; then
        error "Docker is not installed"
    fi
    
    # Check Docker Compose
    if ! command -v docker-compose &> /dev/null; then
        error "Docker Compose is not installed"
    fi
    
    # Check disk space
    DISK_SPACE=$(df / | awk 'NR==2 {print $4}')
    if [ "$DISK_SPACE" -lt 5242880 ]; then  # Less than 5GB
        warn "Low disk space: $(($DISK_SPACE/1024))MB available"
    fi
    
    # Check memory
    MEMORY=$(free -m | awk 'NR==2 {print $2}')
    if [ "$MEMORY" -lt 2048 ]; then  # Less than 2GB
        warn "Low memory: ${MEMORY}MB available"
    fi
    
    log "Prerequisites check passed"
}

# Function to backup current state
backup_current_state() {
    log "Creating backup of current state..."
    
    mkdir -p "$BACKUP_DIR"
    
    # Backup Docker volumes
    docker run --rm -v postgres_data:/volume -v "$BACKUP_DIR:/backup" alpine \
        tar czf /backup/postgres_data.tar.gz -C /volume ./
    
    docker run --rm -v grafana_data:/volume -v "$BACKUP_DIR:/backup" alpine \
        tar czf /backup/grafana_data.tar.gz -C /volume ./
    
    docker run --rm -v prometheus_data:/volume -v "$BACKUP_DIR:/backup" alpine \
        tar czf /backup/prometheus_data.tar.gz -C /volume ./
    
    # Backup configuration files
    tar czf "$BACKUP_DIR/config.tar.gz" \
        docker-compose.yml \
        .env* \
        prometheus/ \
        grafana/ \
        nginx/ 2>/dev/null || true
    
    # Backup database dump
    docker-compose exec -T db pg_dump -U postgres monitoring_db > "$BACKUP_DIR/database_dump.sql"
    
    log "Backup created at: $BACKUP_DIR"
}

# Function to update code
update_code() {
    log "Updating code..."
    
    # Pull latest code (if using git)
    if [ -d ".git" ]; then
        git pull origin main
    fi
    
    # Pull latest Docker images
    log "Pulling latest Docker images..."
    docker-compose pull --quiet
}

# Function to run migrations
run_migrations() {
    log "Running database migrations..."
    
    # Wait for database to be ready
    MAX_RETRIES=30
    RETRY_COUNT=0
    
    while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        if docker-compose exec -T db pg_isready -U postgres > /dev/null 2>&1; then
            log "Database is ready"
            break
        fi
        RETRY_COUNT=$((RETRY_COUNT+1))
        log "Waiting for database... ($RETRY_COUNT/$MAX_RETRIES)"
        sleep 2
    done
    
    if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
        error "Database is not ready after $MAX_RETRIES retries"
    fi
    
    # Run SQL migrations
    if [ -f "db/migrations/latest.sql" ]; then
        docker-compose exec -T db psql -U postgres -d monitoring_db -f /docker-entrypoint-initdb.d/latest.sql
    fi
    
    log "Migrations completed"
}

# Function to deploy services
deploy_services() {
    log "Deploying services..."
    
    # Stop existing services
    log "Stopping existing services..."
    docker-compose down --remove-orphans
    
    # Start services with new configuration
    log "Starting services..."
    docker-compose up -d --force-recreate --build
    
    # Wait for services to be healthy
    log "Waiting for services to be healthy..."
    sleep 30
    
    # Check service health
    HEALTH_CHECKS=(
        "http://localhost/health"
        "http://localhost/api/health"
    )
    
    for check in "${HEALTH_CHECKS[@]}"; do
        log "Checking $check"
        if ! curl -f -s -o /dev/null "$check"; then
            error "Service health check failed: $check"
        fi
    done
    
    log "Services deployed successfully"
}

# Function to run smoke tests
run_smoke_tests() {
    log "Running smoke tests..."
    
    # Test API endpoints
    API_TESTS=(
        "/api/dashboard/summary"
        "/api/alerts"
        "/api/servers"
    )
    
    for test in "${API_TESTS[@]}"; do
        log "Testing $test"
        if ! curl -f -s "http://localhost$test" > /dev/null; then
            warn "API test failed: $test"
        fi
    done
    
    # Test Grafana
    if curl -f -s "http://localhost/grafana/api/health" > /dev/null; then
        log "Grafana is healthy"
    else
        warn "Grafana health check failed"
    fi
    
    log "Smoke tests completed"
}

# Function to cleanup old containers and images
cleanup() {
    log "Cleaning up old containers and images..."
    
    # Remove stopped containers
    docker container prune -f
    
    # Remove unused images
    docker image prune -af
    
    # Remove unused volumes (keep recent backups)
    docker volume prune -f
    
    log "Cleanup completed"
}

# Function to rollback if deployment fails
rollback() {
    error "Deployment failed, initiating rollback..."
    
    log "Restoring from backup: $BACKUP_DIR"
    
    # Stop services
    docker-compose down
    
    # Restore volumes
    if [ -f "$BACKUP_DIR/postgres_data.tar.gz" ]; then
        docker run --rm -v postgres_data:/volume -v "$BACKUP_DIR:/backup" alpine \
            tar xzf /backup/postgres_data.tar.gz -C /volume
    fi
    
    # Start services with old configuration
    docker-compose up -d
    
    log "Rollback completed"
    exit 1
}

# Main deployment flow
main() {
    log "Starting deployment for environment: $ENVIRONMENT"
    
    # Set trap for rollback on error
    trap rollback ERR
    
    check_prerequisites
    backup_current_state
    update_code
    deploy_services
    run_migrations
    run_smoke_tests
    cleanup
    
    log "Deployment completed successfully!"
    
    # Send notification
    if [ -n "$SLACK_WEBHOOK" ]; then
        curl -X POST -H 'Content-type: application/json' \
            --data "{\"text\":\"✅ Monitoring system deployed successfully to $ENVIRONMENT at $(date)\"}" \
            "$SLACK_WEBHOOK"
    fi
}

# Execute main function
main
