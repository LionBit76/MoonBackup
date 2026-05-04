#!/bin/bash
# MoonBackup Installer v0.9.2
# Created: 2024-05-04
# Last updated: $(date +%Y-%m-%d\ %H:%M:%S)
# Creates directory structure, checks dependencies, and registers macros

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="$HOME"
CONFIG_DIR="$HOME_DIR/printer_data/config"
MOONBACKUP_CONFIG="$CONFIG_DIR/MoonBackup.cfg"
BACKUP_DIR="$HOME_DIR/Backup"
PRINTER_CONFIG="$CONFIG_DIR/printer.cfg"
MOONRAKER_CONFIG="$CONFIG_DIR/moonraker.conf"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}      MoonBackup Installer v0.9.2       ${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    echo -e "${RED}ERROR: Do not run this script as root! Run as your regular user (pi, mainsail, etc.).${NC}"
    exit 1
fi

# Check for G-Code Shell Command
SHELL_COMMAND_FOUND=0

# Check for shell_command.cfg (exists when G-Code Shell Command is installed)
if [ -f "$HOME/printer_data/config/shell_command.cfg" ]; then
    SHELL_COMMAND_FOUND=1
else
    # Check possible locations for shell_command.py
    for SHELL_COMMAND_FILE in \
        "$HOME/moonraker/moonraker/components/shell_command.py" \
        "$HOME/Moonraker/moonraker/components/shell_command.py"; do
        if [ -f "$SHELL_COMMAND_FILE" ]; then
            SHELL_COMMAND_FOUND=1
            break
        fi
    done
fi

if [ "$SHELL_COMMAND_FOUND" -eq 0 ]; then
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



# Register macros in printer.cfg
echo ""
echo "Checking printer.cfg for MoonBackup macros..."

# Check if macros already exist
if grep -q "gcode_macro BACKUP" "$PRINTER_CONFIG" 2>/dev/null; then
    echo -e "${YELLOW}✓ MoonBackup macros already registered in printer.cfg${NC}"
else
    echo ""
    echo "Adding MoonBackup macros to printer.cfg..."
    
    # Backup printer.cfg with leading dot to hide it
    cp "$PRINTER_CONFIG" "$CONFIG_DIR/.printer.cfg.bak.$(date +%Y%m%d-%H%M%S)"
    
    # Add macros at the end of the file
    MOONBACKUP_PATH="$HOME/MoonBackup"
    cat >> "$PRINTER_CONFIG" << EOF

# MoonBackup Macros
[gcode_macro BACKUP]
gcode:
  RUN_SHELL_COMMAND CMD="bash ${MOONBACKUP_PATH}/moonbackup.sh"
  RESPOND MSG="MoonBackup started. Check terminal for progress."

[gcode_macro RESTORE]
gcode:
  RUN_SHELL_COMMAND CMD="bash ${MOONBACKUP_PATH}/restore.sh"
  RESPOND MSG="MoonRestore started. Check terminal for progress."

[gcode_macro BACKUP_STATUS]
gcode:
  RUN_SHELL_COMMAND CMD="bash ${MOONBACKUP_PATH}/moonbackup.sh --status"
  RESPOND MSG="Backup status check initiated."
EOF
    
    echo -e "${GREEN}✓ MoonBackup macros added to printer.cfg${NC}"
    echo -e "${YELLOW}  Original printer.cfg backed up as $CONFIG_DIR/.printer.cfg.bak.<timestamp>${NC}"
fi

# Check if update_manager entry already exists in moonraker.conf
if grep -q "update_manager MoonBackup" "$MOONRAKER_CONFIG" 2>/dev/null; then
    echo -e "${YELLOW}✓ MoonBackup update_manager already registered in moonraker.conf${NC}"
else
    echo ""
    echo "Adding MoonBackup update_manager to moonraker.conf..."
    
    # Backup moonraker.conf with leading dot to hide it
    cp "$MOONRAKER_CONFIG" "$CONFIG_DIR/.moonraker.conf.bak.$(date +%Y%m%d-%H%M%S)"
    
    # Add update_manager at the end of the file
    cat >> "$MOONRAKER_CONFIG" << EOF

# MoonBackup Update Manager
[update_manager MoonBackup]
type: git_repo
channel: stable
origin: https://github.com/LionBit76/MoonBackup.git
path: ~/MoonBackup
managed_services: 
primary_branch: main
EOF
    
    echo -e "${GREEN}✓ MoonBackup update_manager added to moonraker.conf${NC}"
    echo -e "${YELLOW}  Original moonraker.conf backed up as $CONFIG_DIR/.moonraker.conf.bak.<timestamp>${NC}"
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
echo "  - Backup:  bash $SCRIPT_DIR/moonbackup.sh"
echo "  - Restore: bash $SCRIPT_DIR/restore.sh"
echo ""
echo "Configuration file location: $MOONBACKUP_CONFIG"
echo "Backup directory: $BACKUP_DIR"
echo "Scripts location: $SCRIPT_DIR"
echo ""

# Restart Moonraker to apply changes
echo "Restarting Moonraker..."
if command_exists systemctl; then
    sudo systemctl restart moonraker
    echo -e "${GREEN}✓ Moonraker restarted${NC}"
else
    if command_exists service; then
        sudo service moonraker restart
        echo -e "${GREEN}✓ Moonraker restarted${NC}"
    else
        echo -e "${YELLOW}Could not restart Moonraker. Please restart it manually:${NC}"
        echo "  sudo systemctl restart moonraker"
    fi
fi
