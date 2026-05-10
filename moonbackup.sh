#!/bin/bash
# MoonBackup - Main Backup Script
# This script creates backups of your VORON printer configuration
# It can backup to local storage, GitHub, or SCP to a remote server

set -o pipefail

# ============================================
# GLOBAL VARIABLES
# ============================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$HOME/printer_data/config/MoonBackup.cfg"
LOG_DIR="$HOME/printer_data/logs"
LOG_FILE="$LOG_DIR/moonbackup.log"
PID_FILE="/tmp/moonbackup.pid"

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
    
    # Also print to console based on level
    case "$level" in
        DEBUG)
            if [ "$LOG_LEVEL" = "DEBUG" ]; then
                echo -e "${BLUE}[DEBUG]${NC} $message"
            fi
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
            log "ERROR" "Another MoonBackup instance is already running (PID: $pid)"
            echo -e "${RED}ERROR: Another MoonBackup instance is already running (PID: $pid)${NC}"
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
}

trap cleanup EXIT

# Parse configuration file
parse_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log "ERROR" "Configuration file not found: $CONFIG_FILE"
        echo -e "${RED}ERROR: Configuration file not found: $CONFIG_FILE${NC}"
        echo "Please install MoonBackup first by running: bash ~/MoonBackup/installer.sh"
        exit 1
    fi
    
    # Source the config file
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    
    # Set default values if not defined
    : ${BACKUP_HOME:=1}
    : ${BACKUP_TIMELAPSE:=0}
    : ${BACKUP_GCODES:=1}
    : ${BACKUP_PRINTER_DATA:=1}
    : ${BACKUP_LOGS:=1}
    : ${BACKUP_DATABASE:=1}
    : ${BACKUP_SYSTEM:=1}
    : ${BACKUP_MOONRAKER:=1}
    : ${BACKUP_KLIPPER:=1}
    : ${BACKUP_WEBCAM:=1}
    : ${CUSTOM_INCLUDE:=""}
    : ${CUSTOM_EXCLUDE:="Backup MoonBackup"}
    : ${BACKUP_TYPE:="full"}
    : ${INCREMENTAL_FULL_KEEP:=3}
    : ${DEST_LOCAL:=1}
    : ${DEST_SCP:=0}
    : ${DEST_NEXTCLOUD:=0}
    : ${DEST_SMB:=0}
    : ${NEXTCLOUD_UPLOAD_DELAY:=1}
    : ${NEXTCLOUD_MAX_RETRIES:=3}
    : ${NEXTCLOUD_RETRY_BACKOFF:=2}
    : ${LOCAL_BACKUP_DIR:="$HOME/Backup"}
    : ${LOCAL_MAX_BACKUPS:=5}
    : ${LOCAL_COMPRESSION:=6}
    : ${BACKUP_PREFIX:="voron-backup"}
    : ${BACKUP_INCLUDE_DATE:=1}
    : ${BACKUP_DATE_FORMAT:="%Y%m%d-%H%M%S"}
    : ${LOG_LEVEL:="INFO"}
    : ${EMAIL_ENABLED:=0}
}

# Check if command exists
command_exists() {
    command -v "$1" > /dev/null 2>&1
}

# Get backup filename
get_backup_filename() {
    local date_str
    if [ "$BACKUP_INCLUDE_DATE" = "1" ]; then
        date_str=$(date "+$BACKUP_DATE_FORMAT")
    else
        date_str=""
    fi
    
    if [ -n "$date_str" ]; then
        echo "${BACKUP_PREFIX}_${date_str}.tar.gz"
    else
        echo "${BACKUP_PREFIX}.tar.gz"
    fi
}

# Create exclude list for tar
create_exclude_list() {
    local excludes=()
    
    # Always exclude backup directory and MoonBackup
    excludes+=("--exclude=./Backup")
    excludes+=("--exclude=./MoonBackup")
    
    # Always exclude cache and socket files (avoid permission errors)
    excludes+=("--exclude=./.cache")
    excludes+=("--exclude=*.sock")
    
    # Exclude based on configuration
    if [ "$BACKUP_HOME" != "1" ]; then
        excludes+=("--exclude=./")
    fi
    if [ "$BACKUP_TIMELAPSE" != "1" ]; then
        excludes+=("--exclude=./timelapse")
    fi
    if [ "$BACKUP_GCODES" != "1" ]; then
        excludes+=("--exclude=./printer_data/gcodes")
    fi
    if [ "$BACKUP_LOGS" != "1" ]; then
        excludes+=("--exclude=./printer_data/logs")
    fi
    
    # Custom excludes
    if [ -n "$CUSTOM_EXCLUDE" ]; then
        for dir in $CUSTOM_EXCLUDE; do
            excludes+=("--exclude=./${dir}")
        done
    fi
    
    # Return excludes as space-separated string
    printf "%s " "${excludes[@]}"
}

# Rotate backups before creating new one (enforce max count)
enforce_backup_rotation() {
    if [ "$LOCAL_MAX_BACKUPS" -gt 0 ] 2>/dev/null; then
        rotate_backups "$LOCAL_BACKUP_DIR" "$LOCAL_MAX_BACKUPS"
    fi
}

# Backup to local
backup_local() {
    # Enforce rotation before creating new backup
    enforce_backup_rotation
    
    local backup_file="$LOCAL_BACKUP_DIR/$(get_backup_filename)"
    local start_time
    start_time=$(date +%s)
    
    log "INFO" "Starting local backup to: $backup_file"
    
    # Create backup directory if it doesn't exist
    mkdir -p "$LOCAL_BACKUP_DIR"
    
    # Get exclude list
    local excludes
    excludes=$(create_exclude_list)
    
    # Build tar command
    local tar_cmd="tar -czf \"$backup_file\" -C \"$HOME\" ${excludes}"
    
    # Add files to include based on configuration
    if [ "$BACKUP_HOME" = "1" ]; then
        tar_cmd+=" ."
    else
        # Add selected directories
        [ "$BACKUP_PRINTER_DATA" = "1" ] && tar_cmd+=" ./printer_data"
        [ "$BACKUP_TIMELAPSE" = "1" ] && tar_cmd+=" ./timelapse"
        [ "$BACKUP_GCODES" = "1" ] && tar_cmd+=" ./printer_data/gcodes"
        [ "$BACKUP_LOGS" = "1" ] && tar_cmd+=" ./printer_data/logs"
        [ "$BACKUP_DATABASE" = "1" ] && tar_cmd+=" ./printer_data/database"
        [ "$BACKUP_SYSTEM" = "1" ] && tar_cmd+=" ./printer_data/system"
        [ "$BACKUP_MOONRAKER" = "1" ] && tar_cmd+=" ./printer_data/moonraker"
        [ "$BACKUP_KLIPPER" = "1" ] && tar_cmd+=" ./printer_data/klipper"
        [ "$BACKUP_WEBCAM" = "1" ] && tar_cmd+=" ./webcam"
    fi
    
    # Add custom includes
    if [ -n "$CUSTOM_INCLUDE" ]; then
        for dir in $CUSTOM_INCLUDE; do
            tar_cmd+=" ./${dir}"
        done
    fi
    
    # Execute tar command
    log "DEBUG" "Executing: $tar_cmd"
    
    if eval "$tar_cmd" 2>> "$LOG_FILE"; then
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))
        local size
        size=$(du -h "$backup_file" | cut -f1)
        
        log "SUCCESS" "Local backup completed: $backup_file (Size: $size, Duration: ${duration}s)"
        
        # Store backup info for email notification
        BACKUP_SIZE="$size"
        BACKUP_DURATION="$duration"
        BACKUP_FILE="$backup_file"
        BACKUP_STATUS="SUCCESS"
        
        # Rotate old backups
        rotate_backups "$LOCAL_BACKUP_DIR" "$LOCAL_MAX_BACKUPS"
        
        return 0
    else
        log "ERROR" "Local backup failed"
        BACKUP_STATUS="FAILED"
        return 1
    fi
}

# Rotate old backups
rotate_backups() {
    local backup_dir="$1"
    local max_keep="$2"
    
    if [ "$max_keep" -le 0 ]; then
        return
    fi
    
    log "INFO" "Rotating backups in $backup_dir (keeping max $max_keep)"
    
    # Get list of backup files sorted by modification time (oldest first)
    local backups
    backups=$(find "$backup_dir" -name "${BACKUP_PREFIX}_*.tar.gz" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | awk '{print $2}')
    
    # Count backups
    local count
    count=$(echo "$backups" | grep -c .)
    
    if [ "$count" -gt "$max_keep" ]; then
        local to_delete=$((count - max_keep))
        log "INFO" "Deleting $to_delete old backup(s)"
        
        echo "$backups" | head -n "$to_delete" | while read -r old_backup; do
            if [ -f "$old_backup" ]; then
                log "INFO" "Deleting old backup: $old_backup"
                rm -f "$old_backup"
            fi
        done
    fi
}

# Backup via SCP
backup_scp() {
    if [ "$DEST_SCP" != "1" ]; then
        log "INFO" "SCP backup is disabled"
        return 0
    fi
    
    if [ -z "$SCP_HOST" ] || [ -z "$SCP_USER" ]; then
        log "ERROR" "SCP backup enabled but host or user not configured"
        return 1
    fi
    
    log "INFO" "Starting SCP backup to ${SCP_USER}@${SCP_HOST}:${SCP_PATH}..."
    
    local start_time
    start_time=$(date +%s)
    
    # Find the latest local backup file
    local backup_file
    backup_file=$(find "$LOCAL_BACKUP_DIR" -name "${BACKUP_PREFIX}_*.tar.gz" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n -r | head -n 1 | awk '{print $2}')
    
    # If no backup found, create one
    if [ -z "$backup_file" ] || [ ! -f "$backup_file" ]; then
        if ! backup_local; then
            log "ERROR" "Failed to create local backup for SCP transfer"
            return 1
        fi
        # Find the backup we just created
        backup_file=$(find "$LOCAL_BACKUP_DIR" -name "${BACKUP_PREFIX}_*.tar.gz" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n -r | head -n 1 | awk '{print $2}')
    fi
    
    # Build SCP command
    local scp_cmd="scp -P ${SCP_PORT}"
    
    if [ -n "$SCP_KEY" ]; then
        scp_cmd+=" -i \"$SCP_KEY\""
    fi
    
    scp_cmd+=" \"$backup_file\" ${SCP_USER}@${SCP_HOST}:${SCP_PATH}/"
    
    log "DEBUG" "Executing: $scp_cmd"
    
    if eval "$scp_cmd" 2>> "$LOG_FILE"; then
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        log "SUCCESS" "SCP backup completed (Duration: ${duration}s)"
        return 0
    else
        log "ERROR" "SCP backup failed"
        return 1
    fi
}

# Helper function for Nextcloud TUS chunked upload
nextcloud_upload_chunk_tus() {
    local chunk_file="$1"
    local uploads_url="$2"
    local offset_hex="$3"
    local max_retries="$4"
    local upload_delay="$5"
    local backoff_base="$6"
    
    local retry_count=0
    local chunk_ok=0
    local current_delay="$upload_delay"
    
    while [ "$retry_count" -le "$max_retries" ]; do
        log "DEBUG" "Uploading chunk at offset ${offset_hex} (attempt $((retry_count + 1))/$((max_retries + 1))..."
        
        if curl -sS -f -T "$chunk_file" -u "${NEXTCLOUD_USER}:${NEXTCLOUD_PASSWORD}" \
            -X PUT "${uploads_url}/${offset_hex}" 2>> "$LOG_FILE"; then
            log "DEBUG" "Chunk at offset ${offset_hex} uploaded successfully"
            chunk_ok=1
            break
        else
            if [ "$retry_count" -lt "$max_retries" ]; then
                log "WARN" "Chunk at offset ${offset_hex} failed, retrying in ${current_delay}s..."
                sleep "$current_delay"
                # Simple backoff: multiply delay by backoff_base each retry
                current_delay=$((current_delay * backoff_base))
            else
                log "ERROR" "Failed to upload chunk at offset ${offset_hex} after $max_retries retries"
            fi
            retry_count=$((retry_count + 1))
        fi
    done
    
    return $((chunk_ok == 1 ? 0 : 1))
}

# Helper function for single file upload to Nextcloud
upload_single_nextcloud() {
    local file="$1"
    local dest="$2"
    
    log "DEBUG" "Uploading file to: $dest"
    
    if curl -sS -f -T "$file" -u "${NEXTCLOUD_USER}:${NEXTCLOUD_PASSWORD}" \
        -X PUT "$dest" 2>> "$LOG_FILE"; then
        return 0
    else
        return 1
    fi
}

# Backup to Nextcloud via WebDAV with TUS protocol support
backup_nextcloud() {
    if [ "$DEST_NEXTCLOUD" != "1" ]; then
        log "INFO" "Nextcloud backup is disabled"
        return 0
    fi
    
    if [ -z "$NEXTCLOUD_URL" ] || [ -z "$NEXTCLOUD_USER" ] || [ -z "$NEXTCLOUD_PASSWORD" ]; then
        log "ERROR" "Nextcloud backup enabled but URL, username, or password not configured"
        return 1
    fi
    
    # Check for curl
    if ! command_exists curl; then
        log "ERROR" "Nextcloud backup requires 'curl' - please install it first"
        return 1
    fi
    
    log "INFO" "Starting Nextcloud backup to ${NEXTCLOUD_USER}@${NEXTCLOUD_URL}${NEXTCLOUD_PATH}..."
    
    local start_time
    start_time=$(date +%s)
    
    # Prepare URLs
    local webdav_url="${NEXTCLOUD_URL%/}"
    local upload_path="${NEXTCLOUD_PATH#/}"
    
    # Find the latest local backup file
    local backup_file
    backup_file=$(find "$LOCAL_BACKUP_DIR" -name "${BACKUP_PREFIX}_*.tar.gz" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n -r | head -n 1 | awk '{print $2}')
    
    # If no backup found, create one
    if [ -z "$backup_file" ] || [ ! -f "$backup_file" ]; then
        if ! backup_local; then
            log "ERROR" "Failed to create local backup for Nextcloud transfer"
            return 1
        fi
        # Find the backup we just created
        backup_file=$(find "$LOCAL_BACKUP_DIR" -name "${BACKUP_PREFIX}_*.tar.gz" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n -r | head -n 1 | awk '{print $2}')
    fi
    
    local filename
    filename=$(basename "$backup_file")
    local file_size
    file_size=$(stat -c%s "$backup_file" 2>/dev/null || echo 0)
    
    # Full destination URL for final file
    local final_dest="${webdav_url}/${upload_path}/${filename}"
    
    # Check chunk size setting
    if [ "$NEXTCLOUD_CHUNK_SIZE" -gt 0 ] 2>/dev/null; then
        local chunk_size_kb="$NEXTCLOUD_CHUNK_SIZE"
        local chunk_size_bytes=$((chunk_size_kb * 1024))
        
        if [ "$file_size" -gt "$chunk_size_bytes" ]; then
            # Try TUS protocol first, fallback to single upload if TUS is not supported
            log "INFO" "Attempting TUS protocol upload (chunk size: ${chunk_size_kb}KB)..."
            
            # Generate unique upload ID
            local upload_id="moonbackup_$(date +%s%N)"
            
            # TUS uploads go to /remote.php/dav/uploads/ (not under /files/USERNAME/)
            # Extract base URL by removing /files/USERNAME/ part
            local base_url="${webdav_url%/files/*}"
            local uploads_url="${base_url}/uploads/${upload_id}"
            
            # Step 1: Create upload directory (try TUS)
            log "DEBUG" "Creating TUS upload directory: ${uploads_url}/"
            local tus_supported=1
            if ! curl -sS -f -X MKCOL -u "${NEXTCLOUD_USER}:${NEXTCLOUD_PASSWORD}" \
                "${uploads_url}/" 2>> "$LOG_FILE"; then
                log "WARN" "TUS protocol not supported (MKCOL failed), falling back to single upload"
                tus_supported=0
            fi
            
            if [ "$tus_supported" -eq 1 ]; then
                # Step 2: Upload chunks using TUS
                local offset=0
                local all_chunks_ok=1
                
                while [ "$offset" -lt "$file_size" ]; do
                    local remaining=$((file_size - offset))
                    local current_chunk_size=$((chunk_size_bytes < remaining ? chunk_size_bytes : remaining))
                    
                    # Extract chunk using dd
                    local chunk_file="${backup_file}.chunk_${offset}"
                    if ! dd if="$backup_file" of="$chunk_file" bs="$current_chunk_size" count=1 skip="$offset" 2>/dev/null; then
                        log "ERROR" "Failed to extract chunk at offset $offset"
                        rm -f "$chunk_file"
                        all_chunks_ok=0
                        break
                    fi
                    
                    # Format offset as 16-digit hexadecimal with leading zeros
                    local offset_hex=$(printf "%016x" "$offset")
                    
                    # Upload chunk with retry
                    if ! nextcloud_upload_chunk_tus "$chunk_file" "$uploads_url" "$offset_hex" \
                        "$NEXTCLOUD_MAX_RETRIES" "$NEXTCLOUD_UPLOAD_DELAY" "$NEXTCLOUD_RETRY_BACKOFF"; then
                        log "ERROR" "Failed to upload chunk at offset $offset"
                        rm -f "$chunk_file"
                        all_chunks_ok=0
                        break
                    fi
                    
                    rm -f "$chunk_file"
                    offset=$((offset + current_chunk_size))
                done
                
                # Cleanup temporary chunks
                rm -f "${backup_file}.chunk_"*
                
                if [ "$all_chunks_ok" -eq 0 ]; then
                    log "ERROR" "Nextcloud TUS chunked upload failed"
                    # Cleanup upload directory
                    curl -sS -f -X DELETE -u "${NEXTCLOUD_USER}:${NEXTCLOUD_PASSWORD}" \
                        "${uploads_url}/" >/dev/null 2>&1
                    return 1
                fi
                
                # Step 3: Finalize upload with MOVE
                log "DEBUG" "Finalizing TUS upload with MOVE to: $final_dest"
                if ! curl -sS -f -X MOVE -u "${NEXTCLOUD_USER}:${NEXTCLOUD_PASSWORD}" \
                    -H "Destination: ${final_dest}" -H "Overwrite: T" \
                    "${uploads_url}/" 2>> "$LOG_FILE"; then
                    log "ERROR" "Failed to finalize TUS upload (MOVE operation)"
                    # Cleanup upload directory
                    curl -sS -f -X DELETE -u "${NEXTCLOUD_USER}:${NEXTCLOUD_PASSWORD}" \
                        "${uploads_url}/" >/dev/null 2>&1
                    return 1
                fi
                
                log "INFO" "TUS upload completed and finalized"
            else
                # Fallback: Single upload (TUS not supported)
                log "INFO" "Falling back to single upload (TUS not available)"
                upload_single_nextcloud "$backup_file" "$final_dest"
            fi
        else
            # File is small enough for single upload
            upload_single_nextcloud "$backup_file" "$final_dest"
        fi
    else
        # Single upload (no chunking)
        upload_single_nextcloud "$backup_file" "$final_dest"
    fi
    
    local upload_result=$?
    
    if [ "$upload_result" -eq 0 ]; then
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        log "SUCCESS" "Nextcloud backup completed (Duration: ${duration}s)"
        return 0
    else
        log "ERROR" "Nextcloud backup failed"
        return 1
    fi
}

# Backup to SMB/CIFS (Windows share)
backup_smb() {
    if [ "$DEST_SMB" != "1" ]; then
        log "INFO" "SMB backup is disabled"
        return 0
    fi
    
    if [ -z "$SMB_SERVER" ] || [ -z "$SMB_SHARE" ] || [ -z "$SMB_USER" ] || [ -z "$SMB_PASSWORD" ]; then
        log "ERROR" "SMB backup enabled but server, share, username, or password not configured"
        return 1
    fi
    
    # Check for smbclient
    if ! command_exists smbclient; then
        log "ERROR" "SMB backup requires 'smbclient' - please install it first (sudo apt install smbclient)"
        return 1
    fi
    
    log "INFO" "Starting SMB backup to //${SMB_SERVER}/${SMB_SHARE}/${SMB_PATH}..."
    
    local start_time
    start_time=$(date +%s)
    
    # Find the latest local backup file
    local backup_file
    backup_file=$(find "$LOCAL_BACKUP_DIR" -name "${BACKUP_PREFIX}_*.tar.gz" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n -r | head -n 1 | awk '{print $2}')
    
    # If no backup found, create one
    if [ -z "$backup_file" ] || [ ! -f "$backup_file" ]; then
        if ! backup_local; then
            log "ERROR" "Failed to create local backup for SMB transfer"
            return 1
        fi
        # Find the backup we just created
        backup_file=$(find "$LOCAL_BACKUP_DIR" -name "${BACKUP_PREFIX}_*.tar.gz" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n -r | head -n 1 | awk '{print $2}')
    fi
    
    local filename
    filename=$(basename "$backup_file")
    
    # SMB destination path (combine share and path)
    local smb_dest_path="${SMB_PATH:+${SMB_PATH}/}${filename}"
    
    # Build smbclient command
    local smb_cmd="smbclient"
    smb_cmd+=" -p ${SMB_PORT}"
    smb_cmd+=" //${SMB_SERVER}/${SMB_SHARE}"
    
    if [ -n "$SMB_DOMAIN" ]; then
        smb_cmd+=" -U ${SMB_DOMAIN}/${SMB_USER}"
    else
        smb_cmd+=" -U ${SMB_USER}"
    fi
    
    smb_cmd+=" -c 'cd ${SMB_PATH} 2>/dev/null; put \"${backup_file}\" \"${filename}\"'"
    
    # Export password for smbclient (it reads from SMB_PASSWORD env var or prompts)
    export SMB_PASSWORD
    
    log "DEBUG" "Executing: smbclient command to //${SMB_SERVER}/${SMB_SHARE}/"
    
    # Execute smbclient with password via stdin
    local smb_result
    smb_result=$(echo -e "${SMB_PASSWORD}\n${SMB_PASSWORD}" | \
        smbclient -p "$SMB_PORT" "//${SMB_SERVER}/${SMB_SHARE}" \
        -U "${SMB_DOMAIN:+${SMB_DOMAIN}/}${SMB_USER}" \
        -c "cd ${SMB_PATH} 2>/dev/null; put \"${backup_file}\" \"${filename}\"" 2>> "$LOG_FILE")
    
    local smb_exit=$?
    
    # Clear exported password
    unset SMB_PASSWORD
    
    if [ "$smb_exit" -eq 0 ]; then
        local end_time
        end_time=$(date +%s)
        local duration=$((end_time - start_time))
        
        log "SUCCESS" "SMB backup completed (Duration: ${duration}s)"
        return 0
    else
        log "ERROR" "SMB backup failed (exit code: $smb_exit)"
        log "DEBUG" "SMB result: $smb_result"
        return 1
    fi
}

# Send email notification
send_email() {
    if [ "$EMAIL_ENABLED" != "1" ]; then
        log "INFO" "Email notifications are disabled"
        return 0
    fi
    
    if [ -z "$EMAIL_TO" ]; then
        log "ERROR" "Email enabled but no recipient configured"
        return 1
    fi
    
    log "INFO" "Sending email notification..."
    
    local subject
    if [ "$BACKUP_STATUS" = "SUCCESS" ]; then
        subject="MoonBackup: Success - $(date '+%Y-%m-%d %H:%M:%S')"
    else
        subject="MoonBackup: FAILED - $(date '+%Y-%m-%d %H:%M:%S')"
    fi
    
    # Create email body
    local body
    body="MoonBackup Notification\n\n"
    body+="Date: $(date '+%Y-%m-%d %H:%M:%S')\n"
    body+="Status: $BACKUP_STATUS\n"
    body+="Duration: ${BACKUP_DURATION:-N/A} seconds\n"
    body+="Backup Size: ${BACKUP_SIZE:-N/A}\n"
    body+="Backup File: ${BACKUP_FILE:-N/A}\n\n"
    
    # Add destination info
    body+="Backup Destinations:\n"
    [ "$DEST_LOCAL" = "1" ] && body+="  - Local: $LOCAL_BACKUP_DIR\n"
    [ "$DEST_SCP" = "1" ] && body+="  - SCP: ${SCP_USER}@${SCP_HOST}:${SCP_PATH}\n"
    [ "$DEST_NEXTCLOUD" = "1" ] && body+="  - Nextcloud: ${NEXTCLOUD_URL}${NEXTCLOUD_PATH}\n"
    [ "$DEST_SMB" = "1" ] && body+="  - SMB: //${SMB_SERVER}/${SMB_SHARE}/${SMB_PATH}\n"
    
    body+="\nBackup Configuration:\n"
    body+="  Type: $BACKUP_TYPE\n"
    body+="  Home: $BACKUP_HOME\n"
    body+="  Timelapse: $BACKUP_TIMELAPSE\n"
    body+="  G-Code: $BACKUP_GCODES\n"
    body+="  Printer Data: $BACKUP_PRINTER_DATA\n"
    
    # Create temporary file with attachment (config copy)
    local temp_dir
    temp_dir=$(mktemp -d)
    local config_copy="$temp_dir/MoonBackup.cfg"
    
    if [ -f "$CONFIG_FILE" ]; then
        cp "$CONFIG_FILE" "$config_copy"
    fi
    
    # Try different email methods
    local email_sent=0
    
    # Method 1: Using sendmail
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
    
    # Method 2: Using mail command
    if [ "$email_sent" -eq 0 ] && command_exists mail; then
        echo -e "$body" | mail -s "$subject" -a "$config_copy" "$EMAIL_TO" 2>> "$LOG_FILE" && email_sent=1
    fi
    
    # Method 3: Using swaks (if installed)
    if [ "$email_sent" -eq 0 ] && command_exists swaks; then
        swaks --to "$EMAIL_TO" --from "$EMAIL_FROM" --server "$EMAIL_SMTP" \
            --port "$EMAIL_PORT" --header "Subject: $subject" \
            --body "$body" --attach "$config_copy" \
            ${EMAIL_USE_TLS:+--tls} ${EMAIL_USE_STARTTLS:+--starttls} \
            ${EMAIL_USER:+--auth LOGIN --auth-user "$EMAIL_USER" --auth-password "$EMAIL_PASSWORD"} \
            2>> "$LOG_FILE" && email_sent=1
    fi
    
    # Cleanup
    rm -rf "$temp_dir"
    
    if [ "$email_sent" -eq 1 ]; then
        log "SUCCESS" "Email notification sent"
        return 0
    else
        log "ERROR" "Failed to send email notification"
        return 1
    fi
}

# Show status
show_status() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            echo "MoonBackup is currently running (PID: $pid)"
            echo "Start time: $(ps -p "$pid" -o lstart=)"
            echo ""
            echo "Tail of log file:"
            tail -n 20 "$LOG_FILE"
            return 0
        else
            echo "MoonBackup PID file exists but process is not running"
            rm -f "$PID_FILE"
            return 1
        fi
    else
        echo "MoonBackup is not running"
        return 1
    fi
}

# ============================================
# MAIN SCRIPT
# ============================================

# Initialize variables
BACKUP_STATUS=""
BACKUP_SIZE=""
BACKUP_DURATION=""
BACKUP_FILE=""

# Check for status flag
if [ "${1:-}" = "--status" ]; then
    show_status
    exit $?
fi

# Check PID
check_pid

# Parse configuration
parse_config

# Log start
log "INFO" "MoonBackup started"
log "INFO" "Configuration loaded from: $CONFIG_FILE"

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}       MoonBackup Starting              ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Create backups based on configuration
local_success=1
scp_success=1
nextcloud_success=1
smb_success=1

# Local backup
if [ "$DEST_LOCAL" = "1" ]; then
    echo -e "${CYAN}Creating local backup...${NC}"
    backup_local
    local_success=$?
fi

# SCP backup
scp_success=0
if [ "$DEST_SCP" = "1" ]; then
    echo -e "${CYAN}Creating SCP backup...${NC}"
    backup_scp
    scp_success=$?
fi

# Nextcloud backup
nextcloud_success=0
if [ "$DEST_NEXTCLOUD" = "1" ]; then
    echo -e "${CYAN}Creating Nextcloud backup...${NC}"
    backup_nextcloud
    nextcloud_success=$?
fi

# SMB backup
smb_success=0
if [ "$DEST_SMB" = "1" ]; then
    echo -e "${CYAN}Creating SMB backup...${NC}"
    backup_smb
    smb_success=$?
fi

# Nextcloud backup
nextcloud_success=0
if [ "$DEST_NEXTCLOUD" = "1" ]; then
    echo -e "${CYAN}Creating Nextcloud backup...${NC}"
    backup_nextcloud
    nextcloud_success=$?
fi

# Determine overall status
if [ "$DEST_LOCAL" = "1" ] && [ "$local_success" -ne 0 ]; then
    BACKUP_STATUS="FAILED"
elif [ "$DEST_SCP" = "1" ] && [ "$scp_success" -ne 0 ]; then
    BACKUP_STATUS="FAILED"
elif [ "$DEST_NEXTCLOUD" = "1" ] && [ "$nextcloud_success" -ne 0 ]; then
    BACKUP_STATUS="FAILED"
elif [ "$DEST_SMB" = "1" ] && [ "$smb_success" -ne 0 ]; then
    BACKUP_STATUS="FAILED"
else
    BACKUP_STATUS="SUCCESS"
fi

# Send email notification
if [ "$EMAIL_ENABLED" = "1" ]; then
    send_email
fi

# Final summary
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}       MoonBackup Summary               ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

if [ "$BACKUP_STATUS" = "SUCCESS" ]; then
    echo -e "${GREEN}✓ Backup completed successfully!${NC}"
else
    echo -e "${RED}✗ Backup completed with errors${NC}"
fi

echo ""
echo "Results:"
[ "$DEST_LOCAL" = "1" ] && {
    if [ "$local_success" -eq 0 ]; then
        echo -e "  ${GREEN}✓ Local backup: SUCCESS${NC}"
    else
        echo -e "  ${RED}✗ Local backup: FAILED${NC}"
    fi
}
[ "$DEST_SCP" = "1" ] && {
    if [ "$scp_success" -eq 0 ]; then
        echo -e "  ${GREEN}✓ SCP backup: SUCCESS${NC}"
    else
        echo -e "  ${RED}✗ SCP backup: FAILED${NC}"
    fi
}
[ "$DEST_NEXTCLOUD" = "1" ] && {
    if [ "$nextcloud_success" -eq 0 ]; then
        echo -e "  ${GREEN}✓ Nextcloud backup: SUCCESS${NC}"
    else
        echo -e "  ${RED}✗ Nextcloud backup: FAILED${NC}"
    fi
}
[ "$DEST_SMB" = "1" ] && {
    if [ "$smb_success" -eq 0 ]; then
        echo -e "  ${GREEN}✓ SMB backup: SUCCESS${NC}"
    else
        echo -e "  ${RED}✗ SMB backup: FAILED${NC}"
    fi
}

if [ -n "$BACKUP_FILE" ]; then
    local size
    size=$(du -h "$BACKUP_FILE" | cut -f1)
    echo ""
    echo "Backup file: $BACKUP_FILE"
    echo "Backup size: $size"
fi

echo ""

log "INFO" "MoonBackup finished with status: $BACKUP_STATUS"

exit 0
