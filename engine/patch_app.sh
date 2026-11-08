#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
MODULES_DIR="$DIR/modules"
TARGET="$1"
[ -z "$TARGET" ] && { echo "Usage: $0 </path/to/App.app | /path/to/App.ipa> [output_directory]"; exit 1; }

TEMP_DIR=""
APP_BUNDLE=""
if [ -f "$TARGET" ] && [[ "$TARGET" == *.ipa ]]; then
    TEMP_DIR=$(mktemp -d /tmp/ipa_patch.XXXXXX)
    unzip -q "$TARGET" -d "$TEMP_DIR"
    APP_BUNDLE=$(find "$TEMP_DIR/Payload" -maxdepth 1 -name "*.app" | head -n 1)
elif [ -d "$TARGET" ] && [[ "$TARGET" == *.app ]]; then
    APP_BUNDLE="$TARGET"
fi
[ -d "$APP_BUNDLE" ] || { echo "[-] Target must be a valid .app bundle or .ipa"; rm -rf "$TEMP_DIR"; exit 1; }

echo "[*] Target app bundle: $APP_BUNDLE"
EXE_NAME=$(defaults read "$APP_BUNDLE/Info.plist" CFBundleExecutable 2>/dev/null || basename "$APP_BUNDLE" .app)
MAIN_BIN="$APP_BUNDLE/$EXE_NAME"
MAIN_ARCHS=$(lipo -archs "$MAIN_BIN" 2>/dev/null || true)
[[ "$MAIN_ARCHS" != *"arm64"* ]] && { echo "[-] Error: ipa2mac requires 64-bit arm64 ($MAIN_ARCHS)"; rm -rf "$TEMP_DIR"; exit 1; }

# Resolve recipe
RECIPES_DIR="$DIR/../recipes"; [ ! -d "$RECIPES_DIR" ] && RECIPES_DIR="$DIR/recipes"
BUNDLE_ID=$(defaults read "$APP_BUNDLE/Info.plist" CFBundleIdentifier 2>/dev/null || true)
RECIPE_FILE="${RECIPE_OVERRIDE:-$RECIPES_DIR/$BUNDLE_ID.ini}"
RESOLVED_RECIPE=""
if [ -f "$RECIPE_FILE" ]; then
    TARGET_INI=$(grep -E '^(target_ini|path)[[:space:]]*=' "$RECIPE_FILE" | head -n 1 | cut -d'=' -f2- | tr -d ' \r\t"')
    [ -n "$TARGET_INI" ] && [ -f "$RECIPES_DIR/$TARGET_INI" ] && RESOLVED_RECIPE="$RECIPES_DIR/$TARGET_INI" || RESOLVED_RECIPE="$RECIPE_FILE"
    cp "$RESOLVED_RECIPE" "$APP_BUNDLE/recipe.ini"
fi

recipe_get_val() { [ -f "$RESOLVED_RECIPE" ] && grep -E "^[[:space:]]*$1[[:space:]]*=" "$RESOLVED_RECIPE" 2>/dev/null | head -n 1 | cut -d'=' -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//'; }
recipe_has_flag() { [[ "$(recipe_get_val "$1")" =~ ^(true|1|yes)$ ]]; }

patch_binary() {
    local bin="$1" archs=$(lipo -archs "$bin" 2>/dev/null || true)
    [[ "$archs" == *"arm64"* ]] && [[ "$archs" == *" "* ]] && lipo -thin arm64 "$bin" -output "${bin}.thin" && mv "${bin}.thin" "$bin"
    vtool -set-build-version maccatalyst 14.0 14.0 -replace -output "$bin" "$bin" 2>/dev/null || true
    if recipe_has_flag "background_tasks_redirect"; then
        local bg=$(otool -L "$bin" 2>/dev/null | awk '/BackgroundTasks.framework/{print $1}')
        [ -n "$bg" ] && install_name_tool -change "$bg" "@executable_path/libshim.dylib" "$bin" 2>/dev/null || true
    fi
}
patch_binary "$MAIN_BIN"

# Generic binary patch applier: offset:expected_hex:replacement_hex
BP=$(recipe_get_val "binary_patch")
[ -n "$BP" ] && python3 -c "
off, exp, rep = '$BP'.split(':'); f = open('$MAIN_BIN', 'r+b'); f.seek(int(off, 0))
if exp == '*' or f.read(len(bytes.fromhex(rep))) == bytes.fromhex(exp):
    f.seek(int(off, 0)); f.write(bytes.fromhex(rep)); print('    [+] Applied binary patch at ' + off)
f.close()
"

for p in "$APP_BUNDLE/Frameworks" "$APP_BUNDLE/PlugIns"; do
    [ -d "$p" ] && find "$p" -type f | while read -r f; do
        file "$f" | grep -q "Mach-O" && chmod +x "$f" 2>/dev/null && patch_binary "$f"
    done
done

SELECTED_MODULES=("$MODULES_DIR/core_keychain.c" "$MODULES_DIR/mod_window.m" "$MODULES_DIR/mod_window_close.m" "$MODULES_DIR/mod_input_context.m")
COMPILE_FLAGS=()
LINK_FLAGS=("-framework" "Foundation" "-framework" "Security" "-framework" "AppKit" "-framework" "CoreGraphics" "-framework" "AudioToolbox" "-framework" "AVFoundation")

add_module() {
    local name="$1" base="${1#mod_}" file=""
    for cand in "$name" "$name.m" "$name.c" "$base.m" "$base.c" "mod_${base}.m" "mod_${base}.c"; do
        [ -f "$cand" ] && { file="$cand"; break; }
        [ -f "$MODULES_DIR/$cand" ] && { file="$MODULES_DIR/$cand"; break; }
    done
    [ -z "$file" ] && return 0
    for m in "${SELECTED_MODULES[@]}"; do [ "$m" = "$file" ] && return 0; done
    SELECTED_MODULES+=("$file")
}

process_shims_section() {
    [ -f "$RESOLVED_RECIPE" ] || return 0
    local in_shims=0
    while IFS="=" read -r k v || [ -n "$k" ]; do
        k=$(echo "$k" | tr -d ' \r\t')
        v=$(echo "$v" | cut -d';' -f1 | cut -d'#' -f1 | tr -d ' \r\t"')
        [[ "$k" =~ ^\[(.*)\]$ ]] && { [ "${BASH_REMATCH[1]}" = "shims" ] && in_shims=1 || in_shims=0; continue; }
        [ $in_shims -eq 1 ] && [[ "$v" =~ ^(true|1|yes)$ ]] && add_module "$k"
    done < "$RESOLVED_RECIPE"
    return 0
}
process_shims_section

[ -n "$(recipe_get_val "compile_flags")" ] && COMPILE_FLAGS+=($(recipe_get_val "compile_flags"))
[ -n "$(recipe_get_val "link_flags")" ] && LINK_FLAGS+=($(recipe_get_val "link_flags"))

# Window & screen configuration
[ -n "$(recipe_get_val "width")" ] && COMPILE_FLAGS+=("-DTARGET_WIDTH=$(recipe_get_val "width")")
[ -n "$(recipe_get_val "height")" ] && COMPILE_FLAGS+=("-DTARGET_HEIGHT=$(recipe_get_val "height")")
ASPECT=$(recipe_get_val "aspect_ratio")
[ -n "$ASPECT" ] && [ "$ASPECT" != "free" ] && COMPILE_FLAGS+=("-DASPECT_W=${ASPECT%:*}" "-DASPECT_H=${ASPECT#*:}")
[ "$(recipe_get_val "resizable")" = "false" ] && COMPILE_FLAGS+=("-DRESIZABLE=0")
{ [ "$(recipe_get_val "scale_mode")" = "aspect_fit" ] || recipe_has_flag "uiscreen_bounds_fixed"; } && COMPILE_FLAGS+=("-DHOOK_UISCREEN=1")
IDIOM=$(recipe_get_val "user_interface_idiom")
{ [ "$IDIOM" = "pad" ] || [ "$IDIOM" = "1" ]; } && COMPILE_FLAGS+=("-DIDIOM_PAD=1")
HW_MODEL=$(recipe_get_val "hardware_model")
[ -n "$HW_MODEL" ] && add_module "device_spoof" && COMPILE_FLAGS+=("-DDEVICE_MODEL=\"$HW_MODEL\"")
[ -n "$(recipe_get_val "ascii_path_redirect")" ] && COMPILE_FLAGS+=("-DASCII_PATH_TARGET=\"$(recipe_get_val "ascii_path_redirect")\"")
[ "$DUMP_MODULES" = "1" ] && { basename -a "${SELECTED_MODULES[@]}"; exit 0; }

# Compile JIT libshim.dylib
TARGET_SHIM="$APP_BUNDLE/libshim.dylib"
echo "[*] JIT Compiling libshim.dylib for $(basename "$APP_BUNDLE")..."
clang -dynamiclib -arch arm64 -install_name @executable_path/libshim.dylib \
    "${LINK_FLAGS[@]}" "${COMPILE_FLAGS[@]}" "${SELECTED_MODULES[@]}" -o "$TARGET_SHIM"
vtool -set-build-version maccatalyst 14.0 14.0 -replace -output "$TARGET_SHIM" "$TARGET_SHIM"
python3 "$DIR/insert_dylib.py" "$MAIN_BIN" "@executable_path/libshim.dylib"
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

# Generic bundle copy
BC=$(recipe_get_val "bundle_copy")
[ -n "$BC" ] && { SRC="${BC%%:*}"; DST="${BC##*:}"; [ -f "$APP_BUNDLE/$SRC" ] && [ ! -f "$APP_BUNDLE/$DST" ] && cp "$APP_BUNDLE/$SRC" "$APP_BUNDLE/$DST"; }

# Patch Info.plist
PLIST="$APP_BUNDLE/Info.plist"
[ -f "$PLIST" ] && {
    plutil -replace CFBundleSupportedPlatforms -json '["iPhoneOS", "MacOSX"]' "$PLIST"
    plutil -replace LSMinimumSystemVersion -string "14.0" "$PLIST"
    plutil -replace UIDeviceFamily -json '[1, 2, 6]' "$PLIST" 2>/dev/null || true
    plutil -remove UIRequiredDeviceCapabilities "$PLIST" 2>/dev/null || true
}

# Codesign binaries and bundle
echo "[*] Codesigning binaries and bundle..."
find "$APP_BUNDLE" -depth \( -name "*.framework" -o -name "*.appex" -o -name "*.dylib" \) -exec codesign -f -s - {} + 2>/dev/null || true
codesign -f -s - --deep "$APP_BUNDLE"

[ -n "$TEMP_DIR" ] && { OUT_DIR="${2:-$(dirname "$TARGET")}"; DEST="$OUT_DIR/$(basename "$APP_BUNDLE")"; rm -rf "$DEST" && mv "$APP_BUNDLE" "$DEST" && rm -rf "$TEMP_DIR" && APP_BUNDLE="$DEST"; }
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_BUNDLE" 2>/dev/null || true
echo "[+] Successfully patched $APP_BUNDLE"
