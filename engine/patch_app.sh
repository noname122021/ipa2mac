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
if [ -n "$RECIPE_OVERRIDE" ] && [ -f "$RECIPE_OVERRIDE" ]; then
    RECIPE_FILE="$RECIPE_OVERRIDE"
    echo "[*] Using recipe override: $RECIPE_FILE"
elif [ -n "$BUNDLE_ID" ] && [ -f "$RECIPES_DIR/$BUNDLE_ID.ini" ]; then
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
    grep -E "^[[:space:]]*$key[[:space:]]*=" "$RESOLVED_RECIPE" 2>/dev/null | head -n 1 | cut -d'=' -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//'
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
# Module resolution and dynamic discovery helpers
add_module() {
    local target="$1"
    local file=""
    if [ -f "$target" ]; then
        file="$target"
    elif [ -f "$MODULES_DIR/$target" ]; then
        file="$MODULES_DIR/$target"
    else
        return 0
    fi
    for m in "${SELECTED_MODULES[@]}"; do
        [ "$m" = "$file" ] && return 0
    done
    SELECTED_MODULES+=("$file")
    return 0
}

resolve_module_file() {
    local name="$1"
    [ -z "$name" ] && return 0
    local cands=("$name" "$name.m" "$name.c" "mod_${name}.m" "mod_${name}.c" "${name#mod_}.m" "${name#mod_}.c")
    for cand in "${cands[@]}"; do
        if [ -f "$MODULES_DIR/$cand" ]; then
            echo "$MODULES_DIR/$cand"
            return 0
        fi
    done
    return 0
}

resolve_alias() {
    case "$1" in
        audio_session_fix) echo "mod_audio_legacy.m" ;;
        statfs_spoof) echo "mod_statfs.c mod_nsurl_space.m" ;;
        fake_mpmovieplayer) echo "mod_fake_mpmovieplayer.m mod_ascii_path_redirect.m mod_idle_timer.m mod_av_delegate.m" ;;
        device_rotation_menu) echo "mod_d6_rotation.m" ;;
        dyld_fishhook_suppress) echo "mod_dyld_fishhook.c" ;;
        memory_fault_recovery|block_abort_raise|suppress_sigaction) echo "mod_fault_handler.c mod_vm_protect.c mod_signal_suppress.c" ;;
        ubiquitous_store) echo "mod_ubiquitous.m" ;;
        everyplay_stub|everyplay_mock) echo "mod_everyplay.m" ;;
        game_center_auto_auth) echo "mod_gamecenter.m" ;;
        touch_remapping) echo "mod_touch_remap.m" ;;
        background_tasks_redirect) echo "mod_bg_classes.m mod_bg_scheduler.m mod_nsurl_upload_fix.m" ;;
        device_spoof) echo "mod_device_spoof.c" ;;
        window_close_exit|window_close_guard) echo "mod_window_close.m" ;;
        *) return 1 ;;
    esac
}

resolve_and_add() {
    local item="$1"
    local resolved=$(resolve_module_file "$item")
    if [ -n "$resolved" ]; then
        add_module "$resolved"
    fi
    return 0
}

handle_shim_flag() {
    local key="$1"
    local val="$2"
    [[ "$val" == "true" || "$val" == "1" || "$val" == "yes" ]] || return 0
    local alias_mods=$(resolve_alias "$key" 2>/dev/null || true)
    if [ -n "$alias_mods" ]; then
        for m in $alias_mods; do
            resolve_and_add "$m"
        done
        return 0
    fi
    resolve_and_add "$key"
    return 0
}

process_shims_section() {
    [ -n "$RESOLVED_RECIPE" ] && [ -f "$RESOLVED_RECIPE" ] || return 0
    local in_shims=0
    while IFS="=" read -r raw_key raw_val || [ -n "$raw_key" ]; do
        local key=$(echo "$raw_key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        local val=$(echo "$raw_val" | cut -d';' -f1 | cut -d'#' -f1 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//')
        if [[ "$key" =~ ^\[(.*)\]$ ]]; then
            local sec="${BASH_REMATCH[1]}"
            [ "$sec" = "shims" ] && in_shims=1 || in_shims=0
            continue
        fi
        if [ $in_shims -eq 1 ] && [ -n "$key" ]; then
            handle_shim_flag "$key" "$val"
        fi
    done < "$RESOLVED_RECIPE"
    return 0
}

SELECTED_MODULES=("$MODULES_DIR/core_keychain.c" "$MODULES_DIR/mod_window.m" "$MODULES_DIR/mod_window_close.m" "$MODULES_DIR/mod_input_context.m")
COMPILE_FLAGS=()
LINK_FLAGS=("-framework" "Foundation" "-framework" "Security" "-framework" "AppKit" "-framework" "CoreGraphics" "-framework" "AudioToolbox" "-framework" "AVFoundation")

# Process dynamic shims from recipe [shims] section
process_shims_section

RECIPE_COMPILE_FLAGS=$(recipe_get_val "compile_flags")
[ -n "$RECIPE_COMPILE_FLAGS" ] && COMPILE_FLAGS+=($RECIPE_COMPILE_FLAGS)

RECIPE_LINK_FLAGS=$(recipe_get_val "link_flags")
[ -n "$RECIPE_LINK_FLAGS" ] && LINK_FLAGS+=($RECIPE_LINK_FLAGS)

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
    add_module "mod_device_spoof.c"
    COMPILE_FLAGS+=("-DDEVICE_MODEL=\"$HW_MODEL\"")
fi

# Unreal Engine 3 / ASCII path target
ENGINE=$(recipe_get_val "engine")
ASCII_PATH=$(recipe_get_val "ascii_path_redirect")
if [[ "$ENGINE" == *"unreal"* ]] || [ -n "$ASCII_PATH" ]; then
    handle_shim_flag "fake_mpmovieplayer" "true"
    [ -n "$ASCII_PATH" ] && COMPILE_FLAGS+=("-DASCII_PATH_TARGET=\"$ASCII_PATH\"")
fi

# Background tasks reexport (JAVser, etc.)
if [ "$BG_REDIRECT" = "true" ] || strings "$MAIN_BIN" 2>/dev/null | grep -q "BGContinuedProcessingTask"; then
    handle_shim_flag "background_tasks_redirect" "true"
    LINK_FLAGS+=("-Wl,-reexport_framework,BackgroundTasks")
fi

if [ "$DUMP_MODULES" = "1" ]; then
    for m in "${SELECTED_MODULES[@]}"; do
        basename "$m"
    done
    exit 0
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
