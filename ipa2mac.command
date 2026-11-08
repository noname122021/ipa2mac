#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"

# Batch mode: if argument provided, run once and exit
if [ -n "$1" ]; then
    exec "$DIR/engine/patch_app.sh" "$1" "$2"
fi

clear 2>/dev/null || true
echo "================================================="
echo "           ipa2mac — iOS to Mac Converter         "
echo "================================================="

while true; do
    echo ""
    echo "Drag and drop your non-encrypted 64-bit .ipa file here:"
    echo "(or paste the file path and press Enter)"
    if ! read -r -p "> " INPUT_PATH; then
        echo ""
        break
    fi
    [ -z "$INPUT_PATH" ] && continue

    TARGET=$(python3 -c "import sys, shlex; args = shlex.split(sys.argv[1]) if sys.argv[1].strip() else []; print(args[0] if args else '')" "$INPUT_PATH" 2>/dev/null || echo "$INPUT_PATH")

    if [ ! -e "$TARGET" ]; then
        echo "[-] Error: File not found: $TARGET"
        continue
    fi

    "$DIR/engine/patch_app.sh" "$TARGET" || echo "[-] Conversion failed for $TARGET"
    echo ""
    echo "[+] Done! Ready for next file."
done
