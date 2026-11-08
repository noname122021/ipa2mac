#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$DIR/engine/patch_app.py" "$@"
