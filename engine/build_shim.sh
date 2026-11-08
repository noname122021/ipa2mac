#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$DIR/libshim.dylib"

echo "[*] Building $OUT from micro-modules for Mac Catalyst arm64..."
clang -dynamiclib -arch arm64 -install_name @executable_path/libshim.dylib \
    -framework Foundation -framework Security -framework AppKit \
    -Wl,-reexport_framework,BackgroundTasks \
    "$DIR/modules/core_keychain.c" \
    "$DIR/modules/mod_device_spoof.c" \
    "$DIR/modules/mod_statfs.c" \
    "$DIR/modules/mod_nsurl_space.m" \
    "$DIR/modules/mod_window.m" \
    "$DIR/modules/mod_window_close.m" \
    "$DIR/modules/mod_input_context.m" \
    "$DIR/modules/mod_odr_bypass.m" \
    "$DIR/modules/mod_fake_mpmovieplayer.m" \
    "$DIR/modules/mod_ascii_path_redirect.m" \
    "$DIR/modules/mod_idle_timer.m" \
    "$DIR/modules/mod_av_delegate.m" \
    "$DIR/modules/mod_d6_rotation.m" \
    "$DIR/modules/mod_touch_remap.m" \
    "$DIR/modules/mod_audio_legacy.m" \
    "$DIR/modules/mod_bg_classes.m" \
    "$DIR/modules/mod_bg_scheduler.m" \
    "$DIR/modules/mod_nsurl_upload_fix.m" \
    "$DIR/modules/mod_dyld_fishhook.c" \
    "$DIR/modules/mod_fault_handler.c" \
    "$DIR/modules/mod_vm_protect.c" \
    "$DIR/modules/mod_signal_suppress.c" \
    "$DIR/modules/mod_assert_suppress.c" \
    "$DIR/modules/mod_ubiquitous.m" \
    "$DIR/modules/mod_gamecenter.m" \
    -o "$OUT"

echo "[*] Setting Catalyst 14.0 build version..."
vtool -set-build-version maccatalyst 14.0 14.0 -replace -output "$OUT" "$OUT"

echo "[*] Ad-hoc codesigning $OUT..."
codesign -f -s - "$OUT"

echo "[+] Built successfully: $OUT"
vtool -show "$OUT" | grep -E "platform|minos|sdk"
