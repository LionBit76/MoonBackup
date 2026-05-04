#!/bin/bash
# MoonBackup - Database Pre-Boot Backup Script
# This script copies the Moonraker database to a temporary location before Moonraker starts
# It ensures database consistency for backups without requiring Moonraker to be stopped

set -euo pipefail

# Configuration
DB_SRC="$HOME/printer_data/database"
DB_BACKUP_DIR="$HOME/Backup/db_backup"
LOG_FILE="$HOME/printer_data/logs/moonbackup_preboot.log"
MAX_DB_BACKUPS=3

# Create directories
mkdir -p "$DB_BACKUP_DIR"
mkdir -p "$(dirname "$LOG_FILE")"

# Logging function
log() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1" >> "$LOG_FILE"
}

log "Database pre-boot backup started"

# Check if database exists
if [ ! -d "$DB_SRC" ]; then
    log "Database directory not found: $DB_SRC"
    exit 0
fi

# Get current date for backup name
CURRENT_DATE=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="$DB_BACKUP_DIR/moonraker_db_${CURRENT_DATE}.tar.gz"

# Create backup
if tar -czf "$BACKUP_FILE" -C "$HOME" printer_data/database 2>> "$LOG_FILE"; then
    log "Database backup created: $BACKUP_FILE"
    
    # Rotate old backups
    (cd "$DB_BACKUP_DIR" && ls -t moonraker_db_*.tar.gz 2>/dev/null | tail -n +$((MAX_DB_BACKUPS + 1)) | xargs -I {} rm -f {}) 2>/dev/null
    
    log "Database pre-boot backup completed successfully"
else
    log "ERROR: Failed to create database backup"
fi

exit 0
