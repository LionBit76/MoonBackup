#!/bin/bash
# MoonBackup - Restore Script
# This script restores a backup created by MoonBackup

set -o pipefail

# ============================================
# GLOBAL VARIABLES
# ============================================
CONFIG_FILE="$HOME/printer_data/config/MoonBackup.cfg"
LOG_DIR="$HOME/printer_data/logs"
LOG_FILE="$LOG_DIR/moonbackup-restore.log"
BACKUP_DIR="$HOME/Backup"
PID_FILE="/tmp/moonbackup-restore.pid"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ============================================
# LOGGING FUNCTIONS
# ============================================
mkdir -p "$LOG_DIR" 2>/dev/null

log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_entry="[$timestamp] [$level] $message"
    
    echo "$log_entry" >> "$LOG_FILE"
    
    case "$level" in
        DEBUG)
            [ "$LOG_LEVEL" = "DEBUG" ] && echo -e "${BLUE}[DEBUG]${NC} $message"
            ;;
        INFO)
            echo -e "${CYAN}[INFO]${NC} $message"
            ;;
        WARN)
            echo -e "${YELLOW}[WARN]${NC} $message"
            ;;
        ERROR)
            echo -e "${RED}[ERROR]${NC} $message"
            ;;
        SUCCESS)
            echo -e "${GREEN}[SUCCESS]${NC} $message"
            ;;
        *)
            echo "$log_entry"
            ;;
    esac
}

# ============================================
# HELPER FUNCTIONS
# ============================================

# Check if another instance is running
check_pid() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            log "ERROR" "Another MoonBackup restore instance is already running (PID: $pid)"
            echo -e "${RED}ERROR: Another MoonBackup restore instance is already running (PID: $pid)${NC}"
            exit 1
        else
            log "WARN" "Removing stale PID file"
            rm -f "$PID_FILE"
        fi
    fi
    echo $$ > "$PID_FILE"
}

# Cleanup on exit
cleanup() {
    rm -f "$PID_FILE"
    
    # Restart Moonraker if we stopped it
    if [ "$MOONRAKER_WAS_STOPPED" = "1" ]; then
        log "INFO" "Restarting Moonraker..."
        start_moonraker
    fi
}

trap cleanup EXIT

# Parse configuration file
parse_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log "ERROR" "Configuration file not found: $CONFIG_FILE"
        echo -e "${RED}ERROR: Configuration file not found: $CONFIG_FILE${NC}"
        exit 1
    fi
    
    # Source the config file
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    
    # Set defaults
    : ${BACKUP_PREFIX:="voron-backup"}
    : ${LOCAL_BACKUP_DIR:="$HOME/Backup"}
    : ${MOONRAKER_SERVICE:="moonraker"}
    : ${MOONRAKER_STOP_WAIT:=10}
    : ${MOONRAKER_START_WAIT:=15}
    : ${LOG_LEVEL:="INFO"}
    : ${EMAIL_ENABLED:=0}
}

# Check if command exists
command_exists() {
    command -v "$1" > /dev/null 2>&1
}

# Stop Moonraker
stop_moonraker() {
    log "INFO" "Stopping Moonraker service..."
    
    if command_exists systemctl; then
        sudo systemctl stop "$MOONRAKER_SERVICE" 2>/dev/null || true
    else
        if command_exists service; then
            sudo service "$MOONRAKER_SERVICE" stop 2>/dev/null || true
        fi
    fi
    
    local wait_time=0
    while [ "$wait_time" -lt "$MOONRAKER_STOP_WAIT" ]; do
        if ! pgrep -f moonraker > /dev/null 2>&1; then
            log "INFO" "Moonraker stopped successfully"
            MOONRAKER_WAS_STOPPED=1
            return 0
        fi
        sleep 1
        wait_time=$((wait_time + 1))
    done
    
    log "WARN" "Moonraker did not stop cleanly after $MOONRAKER_STOP_WAIT seconds"
    MOONRAKER_WAS_STOPPED=1
    return 1
}

# Start Moonraker
start_moonraker() {
    log "INFO" "Starting Moonraker service..."
    
    if command_exists systemctl; then
        sudo systemctl start "$MOONRAKER_SERVICE" 2>/dev/null || true
    else
        if command_exists service; then
            sudo service "$MOONRAKER_SERVICE" start 2>/dev/null || true
        fi
    fi
    
    local wait_time=0
    while [ "$wait_time" -lt "$MOONRAKER_START_WAIT" ]; do
        if pgrep -f moonraker > /dev/null 2>&1; then
            log "INFO" "Moonraker started successfully"
            return 0
        fi
        sleep 1
        wait_time=$((wait_time + 1))
    done
    
    log "WARN" "Moonraker did not start within $MOONRAKER_START_WAIT seconds"
    return 1
}

# Get latest backup file
get_latest_backup() {
    local backup_dir="$1"
    local prefix="$2"
    
    # Find the newest backup file matching the prefix
    find "$backup_dir" -name "${prefix}_*.tar.gz" -type f -printf '%T@ %p\n' 2>/dev/null | \
        sort -n -r | head -n 1 | awk '{print $2}'
}

# Extract backup
extract_backup() {
    local backup_file="$1"
    local temp_dir="$2"
    
    log "INFO" "Extracting backup: $backup_file to $temp_dir"
    
    if ! tar -xzf "$backup_file" -C "$temp_dir" 2>> "$LOG_FILE"; then
        log "ERROR" "Failed to extract backup"
        return 1
    fi
    
    return 0
}

# Restore database from pre-boot backup
restore_database() {
    local db_backup_dir="$HOME/Backup/db_backup"
    
    if [ ! -d "$db_backup_dir" ]; then
        log "INFO" "No database pre-boot backups found in $db_backup_dir"
        return 0
    fi
    
    # Find latest database backup
    local latest_db
    latest_db=$(find "$db_backup_dir" -name "moonraker_db_*.tar.gz" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n -r | head -n 1 | awk '{print $2}')
    
    if [ -z "$latest_db" ] || [ ! -f "$latest_db" ]; then
        log "INFO" "No database backup found in $db_backup_dir"
        return 0
    fi
    
    log "INFO" "Found database backup: $latest_db"
    log "INFO" "Restoring database from pre-boot backup..."
    
    # Extract database backup
    if ! tar -xzf "$latest_db" -C "$HOME" 2>> "$LOG_FILE"; then
        log "ERROR" "Failed to restore database from pre-boot backup"
        return 1
    fi
    
    log "SUCCESS" "Database restored from pre-boot backup"
    return 0
}

# List available backups
list_backups() {
    echo -e "${GREEN}Available Backups:${NC}"
    echo ""
    
    # Local backups
    if [ -d "$LOCAL_BACKUP_DIR" ]; then
        local backups
        backups=$(find "$LOCAL_BACKUP_DIR" -name "${BACKUP_PREFIX}_*.tar.gz" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n -r)
        
        if [ -n "$backups" ]; then
            echo -e "${CYAN}Local Backups (in $LOCAL_BACKUP_DIR):${NC}"
            echo "$backups" | awk '{print "  " $2}'
            echo ""
        fi
    fi
    
    # Check for GitHub backups (if configured)
    if [ "$DEST_GITHUB" = "1" ] && [ -n "$GITHUB_TOKEN" ] && [ -n "$GITHUB_REPO" ]; then
        echo -e "${CYAN}GitHub Backups:${NC}"
        echo "  Repository: $GITHUB_REPO"
        echo "  Branch: $GITHUB_BRANCH"
        echo ""
    fi
    
    # Check for SCP backups (if configured)
    if [ "$DEST_SCP" = "1" ] && [ -n "$SCP_HOST" ] && [ -n "$SCP_USER" ]; then
        echo -e "${CYAN}SCP Backups:${NC}"
        echo "  Server: ${SCP_USER}@${SCP_HOST}:${SCP_PATH}"
        echo ""
    fi
}

# Restore from local backup
restore_local() {
    local backup_file="$1"
    local start_time
    start_time=$(date +%s)
    
    if [ ! -f "$backup_file" ]; then
        log "ERROR" "Backup file not found: $backup_file"
        return 1
    fi
    
    log "INFO" "Restoring from: $backup_file"
    
    # Create temporary directory
    local temp_dir
    temp_dir=$(mktemp -d)
    
    # Extract backup to temp directory
    if ! extract_backup "$backup_file" "$temp_dir"; then
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Stop Moonraker before restore
    if [ "$STOP_MOONRAKER_FOR_DB" = "1" ]; then
        stop_moonraker
    fi
    
    # Restore files
    log "INFO" "Copying files from backup..."
    
    # Use rsync to copy files back, preserving permissions
    if command_exists rsync; then
        if ! rsync -a --delete "$temp_dir/" "$HOME/" 2>> "$LOG_FILE"; then
            log "ERROR" "Failed to copy files from backup"
            rm -rf "$temp_dir"
            return 1
        fi
    else
        # Fallback to cp
        if ! cp -a "$temp_dir/." "$HOME/" 2>> "$LOG_FILE"; then
            log "ERROR" "Failed to copy files from backup"
            rm -rf "$temp_dir"
            return 1
        fi
    fi
    
    # Restore latest database from pre-boot backup (overwrites DB from main backup)
    if ! restore_database; then
        log "WARN" "Database restore from pre-boot backup failed, using DB from main backup"
    fi
    
    # Cleanup
    rm -rf "$temp_dir"
    
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    log "SUCCESS" "Restore completed in ${duration}s"
    RESTORE_DURATION="$duration"
    RESTORE_STATUS="SUCCESS"
    
    return 0
}

# Restore from GitHub backup
restore_github() {
    if [ -z "$GITHUB_TOKEN" ] || [ -z "$GITHUB_REPO" ]; then
        log "ERROR" "GitHub restore enabled but token or repo not configured"
        return 1
    fi
    
    log "INFO" "Starting GitHub restore..."
    
    # Create temporary directory
    local temp_dir
    temp_dir=$(mktemp -d)
    local temp_backup="$temp_dir/backup.tar.gz"
    
    local repo_url="https://${GITHUB_TOKEN}@github.com/${GITHUB_REPO}.git"
    local branch="$GITHUB_BRANCH"
    
    # Clone repository
    cd "$temp_dir" || return 1
    
    if ! git clone -q --branch "$branch" "$repo_url" repo 2>> "$LOG_FILE"; then
        log "ERROR" "Failed to clone GitHub repository"
        cd - > /dev/null || return 1
        rm -rf "$temp_dir"
        return 1
    fi
    
    cd repo || return 1
    
    # Find latest backup
    local latest_backup
    latest_backup=$(find . -name "backup.tar.gz" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n -r | head -n 1 | awk '{print $2}')
    
    if [ -z "$latest_backup" ] || [ ! -f "$latest_backup" ]; then
        log "ERROR" "No backup file found in GitHub repository"
        cd - > /dev/null || return 1
        rm -rf "$temp_dir"
        return 1
    fi
    
    log "INFO" "Found backup: $latest_backup"
    
    # Copy backup to temp location
    cp "$latest_backup" "$temp_backup"
    
    cd - > /dev/null || return 1
    rm -rf repo
    cd - > /dev/null || return 1
    
    # Extract and restore
    if ! restore_local "$temp_backup"; then
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Cleanup
    rm -rf "$temp_dir"
    
    return 0
}

# Restore from SCP backup
restore_scp() {
    if [ -z "$SCP_HOST" ] || [ -z "$SCP_USER" ]; then
        log "ERROR" "SCP restore enabled but host or user not configured"
        return 1
    fi
    
    log "INFO" "Starting SCP restore from ${SCP_USER}@${SCP_HOST}:${SCP_PATH}..."
    
    # Create temporary directory
    local temp_dir
    temp_dir=$(mktemp -d)
    local temp_backup="$temp_dir/backup.tar.gz"
    
    # Build SCP command to download
    local scp_cmd="scp -P ${SCP_PORT}"
    
    if [ -n "$SCP_KEY" ]; then
        scp_cmd+=" -i \"$SCP_KEY\""
    fi
    
    # Find latest backup on remote server
    # For this we need to list remote files - using sftp or ssh
    local latest_backup
    
    # Try to find the latest backup file
    if command_exists ssh; then
        latest_backup=$(ssh -P "$SCP_PORT" ${SCP_KEY:+-i "$SCP_KEY"} "$SCP_USER@$SCP_HOST" \
            "find ${SCP_PATH} -name \"${BACKUP_PREFIX}_*.tar.gz\" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n -r | head -n 1 | awk '{print \$2}'" 2>> "$LOG_FILE")
    fi
    
    if [ -z "$latest_backup" ]; then
        # Fallback: try to get any backup file
        latest_backup=$(ssh -P "$SCP_PORT" ${SCP_KEY:+-i "$SCP_KEY"} "$SCP_USER@$SCP_HOST" \
            "ls ${SCP_PATH}/${BACKUP_PREFIX}_*.tar.gz 2>/dev/null | head -n 1" 2>> "$LOG_FILE")
    fi
    
    if [ -z "$latest_backup" ]; then
        log "ERROR" "No backup file found on remote server"
        rm -rf "$temp_dir"
        return 1
    fi
    
    log "INFO" "Found remote backup: $latest_backup"
    
    # Download backup
    scp_cmd+=" \"${SCP_USER}@${SCP_HOST}:${latest_backup}\" \"$temp_backup\""
    
    if ! eval "$scp_cmd" 2>> "$LOG_FILE"; then
        log "ERROR" "Failed to download backup from SCP server"
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Extract and restore
    if ! restore_local "$temp_backup"; then
        rm -rf "$temp_dir"
        return 1
    fi
    
    # Cleanup
    rm -rf "$temp_dir"
    
    return 0
}

# Send email notification for restore
send_restore_email() {
    if [ "$EMAIL_ENABLED" != "1" ]; then
        return 0
    fi
    
    if [ -z "$EMAIL_TO" ]; then
        return 1
    fi
    
    log "INFO" "Sending restore notification email..."
    
    local subject
    if [ "$RESTORE_STATUS" = "SUCCESS" ]; then
        subject="MoonBackup Restore: Success - $(date '+%Y-%m-%d %H:%M:%S')"
    else
        subject="MoonBackup Restore: FAILED - $(date '+%Y-%m-%d %H:%M:%S')"
    fi
    
    local body
    body="MoonBackup Restore Notification\n\n"
    body+="Date: $(date '+%Y-%m-%d %H:%M:%S')\n"
    body+="Status: $RESTORE_STATUS\n"
    body+="Duration: ${RESTORE_DURATION:-N/A} seconds\n"
    body+="Restore Source: $RESTORE_SOURCE\n\n"
    
    # Create temporary file with attachment
    local temp_dir
    temp_dir=$(mktemp -d)
    local config_copy="$temp_dir/MoonBackup.cfg"
    
    if [ -f "$CONFIG_FILE" ]; then
        cp "$CONFIG_FILE" "$config_copy"
    fi
    
    local email_sent=0
    
    # Try sendmail
    if command_exists sendmail; then
        local email_file="$temp_dir/email.txt"
        {
            echo "From: $EMAIL_FROM"
            echo "To: $EMAIL_TO"
            echo "Subject: $subject"
            echo "MIME-Version: 1.0"
            echo "Content-Type: multipart/mixed; boundary="BOUNDARY""
            echo ""
            echo "--BOUNDARY"
            echo "Content-Type: text/plain; charset=UTF-8"
            echo ""
            echo -e "$body"
            echo ""
            echo "--BOUNDARY"
            echo "Content-Type: application/octet-stream"
            echo "Content-Disposition: attachment; filename="MoonBackup.cfg""
            echo ""
            cat "$config_copy"
            echo ""
            echo "--BOUNDARY--"
        } > "$email_file"
        
        if sendmail -t < "$email_file" 2>> "$LOG_FILE"; then
            email_sent=1
        fi
    fi
    
    # Try mail command
    if [ "$email_sent" -eq 0 ] && command_exists mail; then
        echo -e "$body" | mail -s "$subject" -a "$config_copy" "$EMAIL_TO" 2>> "$LOG_FILE" && email_sent=1
    fi
    
    # Try swaks
    if [ "$email_sent" -eq 0 ] && command_exists swaks; then
        swaks --to "$EMAIL_TO" --from "$EMAIL_FROM" --server "$EMAIL_SMTP" \
            --port "$EMAIL_PORT" --header "Subject: $subject" \
            --body "$body" --attach "$config_copy" \
            ${EMAIL_USE_TLS:+--tls} ${EMAIL_USE_STARTTLS:+--starttls} \
            ${EMAIL_USER:+--auth LOGIN --auth-user "$EMAIL_USER" --auth-password "$EMAIL_PASSWORD"} \
            2>> "$LOG_FILE" && email_sent=1
    fi
    
    rm -rf "$temp_dir"
    
    if [ "$email_sent" -eq 1 ]; then
        log "SUCCESS" "Restore notification email sent"
        return 0
    else
        log "ERROR" "Failed to send restore notification email"
        return 1
    fi
}

# ============================================
# MAIN SCRIPT
# ============================================

# Initialize variables
MOONRAKER_WAS_STOPPED=0
RESTORE_STATUS=""
RESTORE_DURATION=""
RESTORE_SOURCE=""

# Parse arguments
ACTION="${1:-restore}"
BACKUP_FILE="${2:-}"

# Check PID
check_pid

# Parse configuration
parse_config

# Log start
log "INFO" "MoonBackup Restore started with action: $ACTION"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}       MoonBackup Restore               ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

case "$ACTION" in
    list|ls)
        list_backups
        exit 0
        ;;
    local)
        if [ -z "$BACKUP_FILE" ]; then
            BACKUP_FILE=$(get_latest_backup "$LOCAL_BACKUP_DIR" "$BACKUP_PREFIX")
            if [ -z "$BACKUP_FILE" ]; then
                log "ERROR" "No backup file found in $LOCAL_BACKUP_DIR"
                echo -e "${RED}ERROR: No backup file found in $LOCAL_BACKUP_DIR${NC}"
                exit 1
            fi
        fi
        RESTORE_SOURCE="Local: $BACKUP_FILE"
        echo -e "${CYAN}Restoring from local backup: $BACKUP_FILE${NC}"
        restore_local "$BACKUP_FILE"
        ;;
    github)
        RESTORE_SOURCE="GitHub: $GITHUB_REPO"
        echo -e "${CYAN}Restoring from GitHub backup...${NC}"
        restore_github
        ;;
    scp)
        RESTORE_SOURCE="SCP: ${SCP_USER}@${SCP_HOST}:${SCP_PATH}"
        echo -e "${CYAN}Restoring from SCP backup...${NC}"
        restore_scp
        ;;
    *)
        # Default: restore from latest local backup
        BACKUP_FILE=$(get_latest_backup "$LOCAL_BACKUP_DIR" "$BACKUP_PREFIX")
        if [ -z "$BACKUP_FILE" ]; then
            log "ERROR" "No backup file found in $LOCAL_BACKUP_DIR"
            echo -e "${RED}ERROR: No backup file found in $LOCAL_BACKUP_DIR${NC}"
            echo ""
            echo "Available actions:"
            echo "  restore.sh          - Restore from latest local backup"
            echo "  restore.sh list     - List available backups"
            echo "  restore.sh local <file>  - Restore from specific local backup file"
            echo "  restore.sh github   - Restore from GitHub backup"
            echo "  restore.sh scp      - Restore from SCP backup"
            exit 1
        fi
        RESTORE_SOURCE="Local: $BACKUP_FILE"
        echo -e "${CYAN}Restoring from latest local backup: $BACKUP_FILE${NC}"
        restore_local "$BACKUP_FILE"
        ;;
esac

# Send email notification
if [ "$EMAIL_ENABLED" = "1" ]; then
    send_restore_email
fi

# Final summary
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}       MoonBackup Restore Summary        ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

if [ "$RESTORE_STATUS" = "SUCCESS" ]; then
    echo -e "${GREEN}✓ Restore completed successfully!${NC}"
    echo ""
    echo "IMPORTANT: You may need to restart Moonraker for changes to take effect."
    echo "Run: sudo systemctl restart moonraker"
else
    echo -e "${RED}✗ Restore completed with errors${NC}"
fi

echo ""
echo "Source: $RESTORE_SOURCE"
echo "Duration: ${RESTORE_DURATION:-N/A} seconds"
echo ""

log "INFO" "MoonBackup Restore finished with status: $RESTORE_STATUS"

exit 0
