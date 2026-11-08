#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
MODULES_DIR="$DIR/modules"

TARGET="$1"
if [ -z "$TARGET" ]; then
    echo "Usage: $0 </path/to/App.app | /path/to/App.ipa> [output_directory]"
    exit 1
fi

TEMP_DIR=""
APP_BUNDLE=""

if [ -f "$TARGET" ] && [[ "$TARGET" == *.ipa ]]; then
    TEMP_DIR=$(mktemp -d /tmp/ipa_patch.XXXXXX)
    echo "[*] Extracting IPA to $TEMP_DIR..."
    unzip -q "$TARGET" -d "$TEMP_DIR"
    APP_BUNDLE=$(find "$TEMP_DIR/Payload" -maxdepth 1 -name "*.app" | head -n 1)
elif [ -d "$TARGET" ] && [[ "$TARGET" == *.app ]]; then
    APP_BUNDLE="$TARGET"
else
    echo "[-] Error: Target must be a .app directory or .ipa file"
    exit 1
fi

if [ -z "$APP_BUNDLE" ] || [ ! -d "$APP_BUNDLE" ]; then
    echo "[-] Failed to find .app bundle"
    exit 1
fi

echo "[*] Target app bundle: $APP_BUNDLE"
EXE_NAME=$(defaults read "$APP_BUNDLE/Info.plist" CFBundleExecutable 2>/dev/null || basename "$APP_BUNDLE" .app)
MAIN_BIN="$APP_BUNDLE/$EXE_NAME"

# Architecture validation: must contain 64-bit arm64
MAIN_ARCHS=$(lipo -archs "$MAIN_BIN" 2>/dev/null || true)
if [[ "$MAIN_ARCHS" != *"arm64"* ]]; then
    echo "[-] Error: Unsupported 32-bit architecture ($MAIN_ARCHS)."
    echo "    ipa2mac requires 64-bit arm64 (iOS 7.0+)."
    echo "    Legacy 32-bit applications (ARMv6/ARMv7, iOS 1-6) require a CPU instruction emulator like touchHLE or HULUS."
    [ -n "$TEMP_DIR" ] && rm -rf "$TEMP_DIR"
    exit 1
fi

# Resolve and bundle recipe
RECIPES_DIR="$DIR/../recipes"
[ ! -d "$RECIPES_DIR" ] && [ -d "$DIR/recipes" ] && RECIPES_DIR="$DIR/recipes"

BUNDLE_ID=$(defaults read "$APP_BUNDLE/Info.plist" CFBundleIdentifier 2>/dev/null || true)
RECIPE_FILE=""
if [ -n "$BUNDLE_ID" ] && [ -f "$RECIPES_DIR/$BUNDLE_ID.ini" ]; then
    RECIPE_FILE="$RECIPES_DIR/$BUNDLE_ID.ini"
    echo "[*] Using recipe: $RECIPE_FILE"
fi

RESOLVED_RECIPE=""
if [ -n "$RECIPE_FILE" ]; then
    TARGET_INI=$(grep -E '^(target_ini|path)[[:space:]]*=' "$RECIPE_FILE" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' \r\t')
    if [ -n "$TARGET_INI" ] && [ -f "$RECIPES_DIR/$TARGET_INI" ]; then
        RESOLVED_RECIPE="$RECIPES_DIR/$TARGET_INI"
    else
        RESOLVED_RECIPE="$RECIPE_FILE"
    fi
    cp "$RESOLVED_RECIPE" "$APP_BUNDLE/recipe.ini"
    echo "[+] Bundled recipe for $BUNDLE_ID into application"
fi

recipe_get_val() {
    local key="$1"
    [ -n "$RESOLVED_RECIPE" ] && [ -f "$RESOLVED_RECIPE" ] || return 0
    grep -E "^[[:space:]]*$key[[:space:]]*=" "$RESOLVED_RECIPE" 2>/dev/null | head -n 1 | awk -F'=' '{print $2}' | tr -d ' \r\t"'
}

recipe_has_flag() {
    local val=$(recipe_get_val "$1")
    [[ "$val" == "true" || "$val" == "1" || "$val" == "yes" ]]
}

BG_REDIRECT="false"
if recipe_has_flag "background_tasks_redirect"; then
    BG_REDIRECT="true"
fi

patch_binary() {
    local bin="$1"
    echo "[*] Processing binary: $bin"

    # Thin to arm64 if fat
    local archs=$(lipo -archs "$bin" 2>/dev/null || true)
    if [[ "$archs" == *"arm64"* ]] && [[ "$archs" == *" "* ]]; then
        echo "    [-] Thinning $bin to arm64..."
        lipo -thin arm64 "$bin" -output "${bin}.thin" && mv "${bin}.thin" "$bin"
    fi

    # vtool to Mac Catalyst 14.0
    echo "    [-] Setting build version maccatalyst 14.0..."
    vtool -set-build-version maccatalyst 14.0 14.0 -replace -output "$bin" "$bin" 2>/dev/null || true

    # Redirect BackgroundTasks.framework if enabled or if missing symbols detected
    if [ "$BG_REDIRECT" = "true" ] || strings "$bin" 2>/dev/null | grep -q "BGContinuedProcessingTask"; then
        if otool -L "$bin" 2>/dev/null | grep -q "BackgroundTasks.framework"; then
            echo "    [-] Redirecting BackgroundTasks.framework to libshim.dylib..."
            local bg_path=$(otool -L "$bin" | grep "BackgroundTasks.framework" | awk '{print $1}')
            if [ -n "$bg_path" ]; then
                install_name_tool -change "$bg_path" "@executable_path/libshim.dylib" "$bin" 2>/dev/null || true
            fi
        fi
    fi
}

patch_binary "$MAIN_BIN"

# UE3 FConfigCacheIni::LoadCoalescedFile patch at 0x8c33c (12 bytes: null check, direct size load, nop blr)
if [[ "$BUNDLE_ID" == "com.chairentertainment.IB2"* ]]; then
    python3 -c "
with open('$MAIN_BIN', 'r+b') as f:
    f.seek(0x8c33c)
    curr = f.read(12)
    # Check for original unpatched (a80240f9 083140f9 00013fd6) or half-patched (a80240f9 a0aa40b9 00013fd6)
    if curr == bytes.fromhex('a80240f9083140f900013fd6') or curr == bytes.fromhex('a80240f9a0aa40b900013fd6'):
        f.seek(0x8c33c)
        f.write(bytes.fromhex('550200b4a0aa40b91f2003d5'))
        print('    [+] Applied UE3 LoadCoalescedFile 12-byte patch (cbz + ldr + nop) at 0x8c33c')
"
fi

# Recursively patch frameworks and dylibs
find "$APP_BUNDLE" -type f ! -name "libshim.dylib" | while read -r file; do
    if file "$file" | grep -q "Mach-O"; then
        chmod +x "$file" 2>/dev/null || true
        if [ "$file" != "$MAIN_BIN" ]; then
            patch_binary "$file"
        fi
    fi
done

# =============================================================================
# JIT Micro-Shim Compilation: select isolated, atomic micro-modules
# =============================================================================
SELECTED_MODULES=("$MODULES_DIR/core_keychain.c" "$MODULES_DIR/mod_window.m" "$MODULES_DIR/mod_window_close.m" "$MODULES_DIR/mod_input_context.m")
COMPILE_FLAGS=()
LINK_FLAGS=("-framework" "Foundation" "-framework" "Security" "-framework" "AppKit")

# Window configuration
WIDTH=$(recipe_get_val "width")
[ -n "$WIDTH" ] && COMPILE_FLAGS+=("-DTARGET_WIDTH=$WIDTH")

HEIGHT=$(recipe_get_val "height")
[ -n "$HEIGHT" ] && COMPILE_FLAGS+=("-DTARGET_HEIGHT=$HEIGHT")

ASPECT=$(recipe_get_val "aspect_ratio")
if [ -n "$ASPECT" ] && [ "$ASPECT" != "free" ]; then
    AW=$(echo "$ASPECT" | awk -F'[:]' '{print $1}')
    AH=$(echo "$ASPECT" | awk -F'[:]' '{print $2}')
    if [ -n "$AW" ] && [ -n "$AH" ]; then
        COMPILE_FLAGS+=("-DASPECT_W=$AW" "-DASPECT_H=$AH")
    fi
fi

RESIZABLE=$(recipe_get_val "resizable")
if [ "$RESIZABLE" = "false" ] || [ "$RESIZABLE" = "0" ]; then
    COMPILE_FLAGS+=("-DRESIZABLE=0")
fi

SCALE_MODE=$(recipe_get_val "scale_mode")
if [ "$SCALE_MODE" = "aspect_fit" ] || recipe_has_flag "uiscreen_bounds_fixed"; then
    COMPILE_FLAGS+=("-DHOOK_UISCREEN=1")
fi

IDIOM=$(recipe_get_val "user_interface_idiom")
if [ "$IDIOM" = "pad" ] || [ "$IDIOM" = "1" ]; then
    COMPILE_FLAGS+=("-DIDIOM_PAD=1")
fi

if [[ "$BUNDLE_ID" == *"cuttherope"* ]] || [[ "$BUNDLE_ID" == *"zeptolab"* ]]; then
    COMPILE_FLAGS+=("-DIS_CTR=1" "-DHOOK_UISCREEN=1")
fi

# Device spoofing
HW_MODEL=$(recipe_get_val "hardware_model")
if [ -n "$HW_MODEL" ]; then
    SELECTED_MODULES+=("$MODULES_DIR/mod_device_spoof.c")
    COMPILE_FLAGS+=("-DDEVICE_MODEL=\"$HW_MODEL\"")
fi

# Disk space spoofing (CarX, etc.)
if recipe_has_flag "statfs_spoof"; then
    SELECTED_MODULES+=("$MODULES_DIR/mod_statfs.c" "$MODULES_DIR/mod_nsurl_space.m")
fi

# On-Demand Resources bypass (CarX, etc.)
if recipe_has_flag "odr_bypass"; then
    SELECTED_MODULES+=("$MODULES_DIR/mod_odr_bypass.m")
fi

# Unreal Engine 3 / MPMoviePlayer / ASCII path
ENGINE=$(recipe_get_val "engine")
ASCII_PATH=$(recipe_get_val "ascii_path_redirect")
if [[ "$ENGINE" == *"unreal"* ]] || recipe_has_flag "fake_mpmovieplayer" || [ -n "$ASCII_PATH" ]; then
    SELECTED_MODULES+=("$MODULES_DIR/mod_fake_mpmovieplayer.m" "$MODULES_DIR/mod_ascii_path_redirect.m" "$MODULES_DIR/mod_idle_timer.m" "$MODULES_DIR/mod_av_delegate.m")
    if [ -n "$ASCII_PATH" ]; then
        COMPILE_FLAGS+=("-DASCII_PATH_TARGET=\"$ASCII_PATH\"")
    fi
fi

# Device 6 rotation menu
if recipe_has_flag "device_rotation_menu"; then
    SELECTED_MODULES+=("$MODULES_DIR/mod_d6_rotation.m")
fi

# Legacy audio session hooks (BADLAND)
if recipe_has_flag "audio_session_fix"; then
    SELECTED_MODULES+=("$MODULES_DIR/mod_audio_legacy.m")
    LINK_FLAGS+=("-framework" "AudioToolbox")
fi

# Background tasks stubs & reexport (JAVser)
if [ "$BG_REDIRECT" = "true" ] || strings "$MAIN_BIN" 2>/dev/null | grep -q "BGContinuedProcessingTask"; then
    SELECTED_MODULES+=("$MODULES_DIR/mod_bg_classes.m" "$MODULES_DIR/mod_bg_scheduler.m" "$MODULES_DIR/mod_nsurl_upload_fix.m")
    LINK_FLAGS+=("-Wl,-reexport_framework,BackgroundTasks")
fi

# Dyld fishhook suppression (BADLAND, CarX)
if recipe_has_flag "dyld_fishhook_suppress"; then
    SELECTED_MODULES+=("$MODULES_DIR/mod_dyld_fishhook.c")
fi

# Memory fault recovery & signal suppression (IB2, BADLAND)
if recipe_has_flag "memory_fault_recovery" || recipe_has_flag "block_abort_raise" || recipe_has_flag "suppress_sigaction"; then
    SELECTED_MODULES+=("$MODULES_DIR/mod_fault_handler.c" "$MODULES_DIR/mod_vm_protect.c" "$MODULES_DIR/mod_signal_suppress.c")
fi

# Assert suppression
if recipe_has_flag "assert_suppress"; then
    SELECTED_MODULES+=("$MODULES_DIR/mod_assert_suppress.c")
fi

# Ubiquitous key-value store (Alto's Adventure, Monument Valley)
if recipe_has_flag "ubiquitous_store"; then
    SELECTED_MODULES+=("$MODULES_DIR/mod_ubiquitous.m")
fi

# Everyplay mock (BADLAND)
if recipe_has_flag "everyplay_stub" || recipe_has_flag "everyplay_mock"; then
    SELECTED_MODULES+=("$MODULES_DIR/mod_everyplay.m")
fi

# GameCenter auto-auth (LIMBO)
if recipe_has_flag "game_center_auto_auth"; then
    SELECTED_MODULES+=("$MODULES_DIR/mod_gamecenter.m")
fi

# Compile JIT libshim.dylib
TARGET_SHIM="$APP_BUNDLE/libshim.dylib"
echo "[*] JIT Compiling libshim.dylib for $(basename "$APP_BUNDLE")..."
echo "    Selected modules: $(basename -a "${SELECTED_MODULES[@]}" | tr '\n' ' ')"
clang -dynamiclib -arch arm64 -install_name @executable_path/libshim.dylib \
    "${LINK_FLAGS[@]}" \
    "${COMPILE_FLAGS[@]}" \
    "${SELECTED_MODULES[@]}" \
    -o "$TARGET_SHIM"

vtool -set-build-version maccatalyst 14.0 14.0 -replace -output "$TARGET_SHIM" "$TARGET_SHIM"
codesign -f -s - "$TARGET_SHIM"

# Inject libshim.dylib into main executable
echo "[*] Injecting libshim.dylib into $MAIN_BIN..."
python3 "$DIR/insert_dylib.py" "$MAIN_BIN" "@executable_path/libshim.dylib"

# Strip quarantine
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

# Unity Addressables dependency fix (e.g. CarX Street)
AA_DIR="$APP_BUNDLE/Data/Raw/aa/BuildTarget"
if [ -d "$AA_DIR" ] && [ -f "$AA_DIR/shared_prefabs_assets_all.bundle" ] && [ ! -f "$AA_DIR/shared_assets_all.bundle" ]; then
    echo "    [-] Bundling shared_assets_all.bundle for Addressables..."
    cp "$AA_DIR/shared_prefabs_assets_all.bundle" "$AA_DIR/shared_assets_all.bundle"
fi

# Patch Info.plist for Mac Catalyst & LaunchServices compatibility
PLIST="$APP_BUNDLE/Info.plist"
if [ -f "$PLIST" ]; then
    echo "[*] Patching Info.plist for Mac Catalyst & LaunchServices..."
    plutil -replace CFBundleSupportedPlatforms -json '["iPhoneOS", "MacOSX"]' "$PLIST"
    plutil -replace LSMinimumSystemVersion -string "14.0" "$PLIST"
    plutil -replace UIDeviceFamily -json '[1, 2, 6]' "$PLIST" 2>/dev/null || true
    plutil -remove UIRequiredDeviceCapabilities "$PLIST" 2>/dev/null || true
fi

# Codesign binaries and libraries recursively, then main bundle
find "$APP_BUNDLE" -type f ! -name "libshim.dylib" | while read -r f; do
    if file "$f" | grep -q "Mach-O"; then
        codesign -f -s - "$f" 2>/dev/null || true
    fi
done
find "$APP_BUNDLE/Frameworks" -type d -name "*.framework" 2>/dev/null | while read -r fw; do
    codesign -f -s - "$fw" 2>/dev/null || true
done
find "$APP_BUNDLE/PlugIns" -type d -name "*.appex" 2>/dev/null | while read -r appex; do
    codesign -f -s - "$appex" 2>/dev/null || true
done

echo "[*] Codesigning app bundle ad-hoc..."
codesign -f -s - --deep "$APP_BUNDLE"

if [ -n "$TEMP_DIR" ]; then
    OUT_DIR="${2:-$(dirname "$TARGET")}"
    DEST="$OUT_DIR/$(basename "$APP_BUNDLE")"
    rm -rf "$DEST"
    mv "$APP_BUNDLE" "$DEST"
    rm -rf "$TEMP_DIR"
    APP_BUNDLE="$DEST"
fi

# Register with LaunchServices
echo "[*] Registering with LaunchServices..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_BUNDLE" 2>/dev/null || true

echo "[+] Successfully patched $APP_BUNDLE"
