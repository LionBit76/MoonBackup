#!/bin/bash
# MoonBackup Installer
# Creates directory structure, checks dependencies, and registers macros

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="$HOME"
CONFIG_DIR="$HOME_DIR/printer_data/config"
MOONBACKUP_CONFIG="$CONFIG_DIR/MoonBackup.cfg"
BACKUP_DIR="$HOME_DIR/Backup"
MOONRAKER_CONFIG="$CONFIG_DIR/moonraker.conf"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}       MoonBackup Installer            ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    echo -e "${RED}ERROR: Do not run this script as root! Run as your regular user (pi, mainsail, etc.).${NC}"
    exit 1
fi

# Check for G-Code Shell Command
if ! command -v gcode_shell_command &> /dev/null; then
    echo -e "${RED}ERROR: G-Code Shell Command is not installed!${NC}"
    echo ""
    echo "MoonBackup requires G-Code Shell Command to be installed."
    echo "Please install it first via KIAUH:"
    echo "  1. Connect to your printer via SSH"
    echo "  2. Run: ~/kiauh/kiauh.sh"
    echo "  3. Select: [6] Moonraker"
    echo "  4. Select: [4] Install gcode_shell_command"
    echo ""
    echo "After installation, restart Moonraker:"
    echo "  sudo systemctl restart moonraker"
    echo ""
    exit 1
fi

echo -e "${GREEN}✓ G-Code Shell Command is installed${NC}"

# Create Backup directory
if [ ! -d "$BACKUP_DIR" ]; then
    mkdir -p "$BACKUP_DIR"
    echo -e "${GREEN}✓ Created Backup directory: $BACKUP_DIR${NC}"
else
    echo -e "${YELLOW}✓ Backup directory already exists: $BACKUP_DIR${NC}"
fi

# Copy configuration file
if [ ! -f "$MOONBACKUP_CONFIG" ]; then
    cp "$SCRIPT_DIR/config/MoonBackup.cfg" "$MOONBACKUP_CONFIG"
    chmod 644 "$MOONBACKUP_CONFIG"
    echo -e "${GREEN}✓ Copied MoonBackup.cfg to $MOONBACKUP_CONFIG${NC}"
else
    echo -e "${YELLOW}✓ MoonBackup.cfg already exists at $MOONBACKUP_CONFIG (not overwritten)${NC}"
fi

# Copy scripts
if [ ! -f "$CONFIG_DIR/moonbackup.sh" ]; then
    cp "$SCRIPT_DIR/moonbackup.sh" "$CONFIG_DIR/"
    chmod +x "$CONFIG_DIR/moonbackup.sh"
    echo -e "${GREEN}✓ Copied moonbackup.sh to $CONFIG_DIR/${NC}"
else
    echo -e "${YELLOW}✓ moonbackup.sh already exists at $CONFIG_DIR/ (not overwritten)${NC}"
fi

if [ ! -f "$CONFIG_DIR/restore.sh" ]; then
    cp "$SCRIPT_DIR/restore.sh" "$CONFIG_DIR/"
    chmod +x "$CONFIG_DIR/restore.sh"
    echo -e "${GREEN}✓ Copied restore.sh to $CONFIG_DIR/${NC}"
else
    echo -e "${YELLOW}✓ restore.sh already exists at $CONFIG_DIR/ (not overwritten)${NC}"
fi

# Register macros in moonraker.conf
echo ""
echo "Checking moonraker.conf for MoonBackup macros..."

# Check if macros already exist
if grep -q "gcode_macro BACKUP" "$MOONRAKER_CONFIG" 2>/dev/null; then
    echo -e "${YELLOW}✓ MoonBackup macros already registered in moonraker.conf${NC}"
else
    echo ""
    echo "Adding MoonBackup macros to moonraker.conf..."
    
    # Backup moonraker.conf
    cp "$MOONRAKER_CONFIG" "$MOONRAKER_CONFIG.bak.$(date +%Y%m%d-%H%M%S)"
    
    # Add macros at the end of the file
    cat >> "$MOONRAKER_CONFIG" << EOF

# MoonBackup Macros
[gcode_macro BACKUP]
gcode:
  RUN_SHELL_COMMAND CMD=bash ${CONFIG_DIR}/moonbackup.sh
  RESPOND MSG="MoonBackup started. Check terminal for progress."

[gcode_macro RESTORE]
gcode:
  RUN_SHELL_COMMAND CMD=bash ${CONFIG_DIR}/restore.sh
  RESPOND MSG="MoonRestore started. Check terminal for progress."

[gcode_macro BACKUP_STATUS]
gcode:
  RUN_SHELL_COMMAND CMD=bash ${CONFIG_DIR}/moonbackup.sh --status
  RESPOND MSG="Backup status check initiated."
EOF
    
    echo -e "${GREEN}✓ MoonBackup macros added to moonraker.conf${NC}"
    echo -e "${YELLOW}  Original moonraker.conf backed up as $MOONRAKER_CONFIG.bak.<timestamp>${NC}"
fi

# Create config directory for MoonBackup if it doesn't exist
mkdir -p "$SCRIPT_DIR/config"

# Copy default config if not exists
if [ ! -f "$SCRIPT_DIR/config/MoonBackup.cfg" ]; then
    cp "$MOONBACKUP_CONFIG" "$SCRIPT_DIR/config/MoonBackup.cfg"
    echo -e "${GREEN}✓ Copied MoonBackup.cfg to $SCRIPT_DIR/config/${NC}"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}       Installation Complete!             ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "MoonBackup is now installed!"
echo ""
echo "To use MoonBackup:"
echo "  1. Edit the configuration: $MOONBACKUP_CONFIG"
echo "  2. In Moonraker WebUI, you can now use these macros:"
echo "     - BACKUP: Start a backup"
echo "     - RESTORE: Restore from the last backup"
echo "     - BACKUP_STATUS: Check backup status"
echo ""
echo "Or run manually:"
echo "  - Backup:  bash $CONFIG_DIR/moonbackup.sh"
echo "  - Restore: bash $CONFIG_DIR/restore.sh"
echo ""
echo "Configuration file location: $MOONBACKUP_CONFIG"
echo "Backup directory: $BACKUP_DIR"
echo ""
