#!/bin/bash

# System Monitoring Dashboard Backup Script

set -e

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/backups/monitoring_${TIMESTAMP}"
RETENTION_DAYS=30

# Create backup directory
mkdir -p "$BACKUP_DIR"

echo "Starting backup at $(date)"

# Backup Docker volumes
echo "Backing up Docker volumes..."
for volume in postgres_data grafana_data prometheus_data; do
    if docker volume inspect "$volume" > /dev/null 2>&1; then
        echo "  Backing up $volume..."
        docker run --rm -v "$volume:/volume" -v "$BACKUP_DIR:/backup" alpine \
            tar czf "/backup/${volume}.tar.gz" -C /volume ./
    fi
done

# Backup database dump
echo "Backing up database..."
docker-compose exec -T db pg_dump -U postgres monitoring_db > "$BACKUP_DIR/database_dump.sql"

# Backup configuration files
echo "Backing up configuration files..."
tar czf "$BACKUP_DIR/config.tar.gz" \
    docker-compose.yml \
    .env* \
    prometheus/ \
    grafana/ \
    nginx/ \
    scripts/ 2>/dev/null || true

# Create backup manifest
cat > "$BACKUP_DIR/manifest.json" << EOF
{
    "timestamp": "$(date -Iseconds)",
    "version": "1.0.0",
    "components": {
        "database": "postgres",
        "monitoring": "prometheus",
        "dashboard": "grafana",
        "api": "nodejs",
        "web": "react"
    },
    "files": [
        "postgres_data.tar.gz",
        "grafana_data.tar.gz",
        "prometheus_data.tar.gz",
        "database_dump.sql",
        "config.tar.gz"
    ]
}
EOF

# Calculate backup size
BACKUP_SIZE=$(du -sh "$BACKUP_DIR" | cut -f1)
echo "Backup completed: $BACKUP_DIR (Size: $BACKUP_SIZE)"

# Upload to S3 (if configured)
if [ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$S3_BUCKET" ]; then
    echo "Uploading backup to S3..."
    tar czf - -C "$BACKUP_DIR" . | aws s3 cp - "s3://$S3_BUCKET/backups/monitoring_${TIMESTAMP}.tar.gz"
fi

# Cleanup old backups
echo "Cleaning up old backups..."
find /backups -type d -name "monitoring_*" -mtime +$RETENTION_DAYS -exec rm -rf {} \;

echo "Backup completed successfully at $(date)"
