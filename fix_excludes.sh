#!/bin/bash
# Fix for tar excludes issue

echo "Fixing moonbackup.sh..."

# Fix the create_exclude_list function output
FILE="~/MoonBackup/moonbackup.sh"

# Method 1: Use sed to replace the printf line
if grep -q 'printf "%s\\n"' "$FILE" 2>/dev/null; then
    sed -i 's/printf "%s\\n"/printf "%s "/' "$FILE"
    echo "✓ Fixed printf in moonbackup.sh"
elif grep -q 'printf "%s "' "$FILE" 2>/dev/null; then
    echo "✓ Already fixed in moonbackup.sh"
else
    echo "? Could not find printf line in moonbackup.sh"
fi

# Also fix in backup_github function if it exists
if grep -q 'excludes=$(create_exclude_list)' "$FILE" 2>/dev/null; then
    echo "✓ create_exclude_list calls found"
else
    echo "? Could not find create_exclude_list calls"
fi

echo ""
echo "Checking line 188..."
sed -n '185,190p' "$FILE"
