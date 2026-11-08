#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$1"

if [ -z "$TARGET" ]; then
    clear 2>/dev/null || true
    echo "================================================="
    echo "           ipa2mac — iOS to Mac Converter         "
    echo "================================================="
    echo ""
    echo "Drag and drop your non-encrypted 64-bit .ipa file here:"
    echo "(or paste the file path and press Enter)"
    echo ""
    read -r -p "> " INPUT_PATH
    if [ -z "$INPUT_PATH" ]; then
        echo "[-] No file provided. Exiting."
        exit 1
    fi
    eval "set -- $INPUT_PATH"
    TARGET="$1"
fi

"$DIR/engine/patch_app.sh" "$TARGET"

echo ""
echo "[+] Done! Press any key to exit..."
read -n 1 -s -r 2>/dev/null || true
