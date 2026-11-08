#!/usr/bin/env python3
"""
Verification test suite for dynamic module discovery and backward compatibility.
Tests that:
1. Every recipe in recipes/*.ini resolves to at least all expected modules from the old if-else logic.
2. Per-line flag = true matching mod_<name>.[cm] works.
3. Declarative link_flags = ... and compile_flags = ... in recipe work.
4. Dynamic discovery works for arbitrary flags matching mod_<name>.[cm].
"""

import os
import glob
import subprocess
import tempfile
import sys

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENGINE_DIR = os.path.join(BASE_DIR, "engine")
MODULES_DIR = os.path.join(ENGINE_DIR, "modules")
RECIPES_DIR = os.path.join(BASE_DIR, "recipes")

sys.path.insert(0, ENGINE_DIR)
import patch_app

def resolve_recipe_via_python(recipe_file):
    bundle_id = os.path.basename(recipe_file)
    if bundle_id.endswith(".ini"):
        bundle_id = bundle_id[:-4]
    resolved = patch_app.resolve_recipe(RECIPES_DIR, bundle_id) or recipe_file
    cp = patch_app.load_recipe(resolved)
    mods = {os.path.basename(m) for m in patch_app.collect_modules(cp, MODULES_DIR)}
    cflags = patch_app.build_compile_flags(cp)
    lflags = patch_app.build_link_flags(cp)
    return mods, cflags, lflags

def get_old_expected_modules(ini_path):
    with open(ini_path, "r", encoding="utf-8") as f:
        lines = f.readlines()

    # Redirection check
    for line in lines:
        line = line.strip()
        if line.startswith("target_ini") or line.startswith("path"):
            parts = line.split("=", 1)
            if len(parts) == 2:
                redir = os.path.join(RECIPES_DIR, parts[1].strip())
                if os.path.exists(redir):
                    return get_old_expected_modules(redir)

    kv = {}
    for line in lines:
        line = line.split(";")[0].split("#")[0].strip()
        if "=" in line:
            k, v = line.split("=", 1)
            kv[k.strip()] = v.strip().strip('"')

    def has_flag(k):
        return kv.get(k, "").lower() in ["true", "1", "yes"]

    mods = {"core_keychain.c", "mod_window.m", "mod_window_close.m", "mod_input_context.m"}

    if kv.get("hardware_model"):
        mods.add("device_spoof.c")
    if has_flag("statfs_spoof"):
        mods.add("statfs_spoof.m")
    if has_flag("odr_bypass"):
        mods.add("odr_bypass.m")
    eng = kv.get("engine", "")
    ascii_p = kv.get("ascii_path_redirect", "")
    if "unreal" in eng or has_flag("fake_mpmovieplayer") or ascii_p:
        mods.add("fake_mpmovieplayer.m")
    if has_flag("device_rotation_menu"):
        mods.add("device_rotation_menu.m")
    if has_flag("audio_session_fix"):
        mods.add("audio_session_fix.m")
    if has_flag("background_tasks_redirect"):
        mods.add("background_tasks_redirect.m")
    if has_flag("dyld_fishhook_suppress"):
        mods.add("dyld_fishhook_suppress.c")
    if has_flag("memory_fault_recovery"):
        mods.add("memory_fault_recovery.c")
    if has_flag("assert_suppress"):
        mods.add("assert_suppress.c")
    if has_flag("ubiquitous_store"):
        mods.add("ubiquitous_store.m")
    if has_flag("everyplay_stub") or has_flag("everyplay_mock"):
        mods.add("everyplay_stub.m")
    if has_flag("game_center_auto_auth"):
        mods.add("game_center_auto_auth.m")
    if has_flag("touch_remapping"):
        mods.add("touch_remapping.m")

    return mods

def resolve_recipe_via_bash(recipe_file):
    script = f'''
MODULES_DIR="{MODULES_DIR}"
RECIPES_DIR="{RECIPES_DIR}"
RECIPE_FILE="{recipe_file}"
RESOLVED_RECIPE=""
if [ -n "$RECIPE_FILE" ]; then
    TARGET_INI=$(grep -E '^(target_ini|path)[[:space:]]*=' "$RECIPE_FILE" | head -n 1 | cut -d'=' -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//')
    if [ -n "$TARGET_INI" ] && [ -f "$RECIPES_DIR/$TARGET_INI" ]; then
        RESOLVED_RECIPE="$RECIPES_DIR/$TARGET_INI"
    else
        RESOLVED_RECIPE="$RECIPE_FILE"
    fi
fi

recipe_get_val() {{
    local key="$1"
    [ -n "$RESOLVED_RECIPE" ] && [ -f "$RESOLVED_RECIPE" ] || return 0
    grep -E "^[[:space:]]*$key[[:space:]]*=" "$RESOLVED_RECIPE" 2>/dev/null | head -n 1 | cut -d'=' -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//'
}}

recipe_has_flag() {{
    local val=$(recipe_get_val "$1")
    [[ "$val" == "true" || "$val" == "1" || "$val" == "yes" ]]
}}

add_module() {{
    local target="$1"
    local file=""
    if [ -f "$target" ]; then
        file="$target"
    elif [ -f "$MODULES_DIR/$target" ]; then
        file="$MODULES_DIR/$target"
    else
        return 0
    fi
    for m in "${{SELECTED_MODULES[@]}}"; do
        [ "$m" = "$file" ] && return 0
    done
    SELECTED_MODULES+=("$file")
}}

resolve_module_file() {{
    local name="$1"
    [ -z "$name" ] && return 0
    local base="${{name#mod_}}"
    local cands=("$name" "$name.m" "$name.c" "$base.m" "$base.c" "mod_${{base}}.m" "mod_${{base}}.c")
    for cand in "${{cands[@]}}"; do
        if [ -f "$MODULES_DIR/$cand" ]; then
            echo "$MODULES_DIR/$cand"
            return 0
        fi
    done
}}

resolve_and_add() {{
    local item="$1"
    local resolved=$(resolve_module_file "$item")
    [ -n "$resolved" ] && add_module "$resolved"
}}

handle_shim_flag() {{
    local key="$1"
    local val="$2"
    [[ "$val" == "true" || "$val" == "1" || "$val" == "yes" ]] || return 0
    resolve_and_add "$key"
}}

process_shims_section() {{
    [ -n "$RESOLVED_RECIPE" ] && [ -f "$RESOLVED_RECIPE" ] || return 0
    local in_shims=0
    while IFS="=" read -r raw_key raw_val || [ -n "$raw_key" ]; do
        local key=$(echo "$raw_key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        local val=$(echo "$raw_val" | cut -d';' -f1 | cut -d'#' -f1 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//')
        if [[ "$key" =~ ^\\[(.*)\\]$ ]]; then
            local sec="${{BASH_REMATCH[1]}}"
            [ "$sec" = "shims" ] && in_shims=1 || in_shims=0
            continue
        fi
        [ $in_shims -eq 1 ] && [ -n "$key" ] && handle_shim_flag "$key" "$val"
    done < "$RESOLVED_RECIPE"
}}

SELECTED_MODULES=("$MODULES_DIR/core_keychain.c" "$MODULES_DIR/mod_window.m" "$MODULES_DIR/mod_window_close.m" "$MODULES_DIR/mod_input_context.m")
COMPILE_FLAGS=()
LINK_FLAGS=("-framework" "Foundation" "-framework" "Security" "-framework" "AppKit" "-framework" "CoreGraphics" "-framework" "AudioToolbox" "-framework" "AVFoundation")

process_shims_section

RECIPE_MODULES=$(recipe_get_val "modules")
if [ -n "$RECIPE_MODULES" ]; then
    for m in $(echo "$RECIPE_MODULES" | tr ',' ' '); do
        resolve_and_add "$m"
    done
fi

RECIPE_COMPILE_FLAGS=$(recipe_get_val "compile_flags")
[ -n "$RECIPE_COMPILE_FLAGS" ] && COMPILE_FLAGS+=($RECIPE_COMPILE_FLAGS)

RECIPE_LINK_FLAGS=$(recipe_get_val "link_flags")
[ -n "$RECIPE_LINK_FLAGS" ] && LINK_FLAGS+=($RECIPE_LINK_FLAGS)

HW_MODEL=$(recipe_get_val "hardware_model")
if [ -n "$HW_MODEL" ]; then
    resolve_and_add "device_spoof"
    COMPILE_FLAGS+=("-DDEVICE_MODEL=\\"$HW_MODEL\\"")
fi

ENGINE=$(recipe_get_val "engine")
ASCII_PATH=$(recipe_get_val "ascii_path_redirect")
if [[ "$ENGINE" == *"unreal"* ]] || [ -n "$ASCII_PATH" ]; then
    handle_shim_flag "fake_mpmovieplayer" "true"
    [ -n "$ASCII_PATH" ] && COMPILE_FLAGS+=("-DASCII_PATH_TARGET=\\"$ASCII_PATH\\"")
fi

if recipe_has_flag "background_tasks_redirect"; then
    handle_shim_flag "background_tasks_redirect" "true"
    LINK_FLAGS+=("-Wl,-reexport_framework,BackgroundTasks")
fi

echo "---MODULES---"
for m in "${{SELECTED_MODULES[@]}}"; do
    basename "$m"
done
echo "---COMPILE_FLAGS---"
printf '%s\\n' "${{COMPILE_FLAGS[@]}}"
echo "---LINK_FLAGS---"
printf '%s\\n' "${{LINK_FLAGS[@]}}"
'''
    res = subprocess.run(["bash", "-c", script], capture_output=True, text=True, check=True)
    stdout = res.stdout

    parts = stdout.split("---MODULES---\n")[1].split("---COMPILE_FLAGS---\n")
    mods = set(parts[0].strip().splitlines())
    parts2 = parts[1].split("---LINK_FLAGS---\n")
    cflags = [x for x in parts2[0].strip().splitlines() if x]
    lflags = [x for x in parts2[1].strip().splitlines() if x]
    return mods, cflags, lflags

def main():
    recipes = sorted(glob.glob(os.path.join(RECIPES_DIR, "*.ini")))
    assert len(recipes) > 0, "No recipes found"
    print(f"[*] Verifying backward compatibility for {len(recipes)} recipes via patch_app.py...")

    failures = 0
    for r in recipes:
        expected = get_old_expected_modules(r)
        actual_mods, _, _ = resolve_recipe_via_python(r)
        missing = expected - actual_mods
        extra = actual_mods - expected
        name = os.path.basename(r)

        if missing:
            print(f"[-] FAILED (python): {name} is missing expected modules: {missing}")
            failures += 1
        else:
            extra_msg = f" (+ dynamic: {extra})" if extra else ""
            print(f"[+] PASSED (python): {name} (expected {len(expected)}, resolved {len(actual_mods)}){extra_msg}")

    print("\n[*] Verifying recipes via legacy bash engine for parity...")
    for r in recipes:
        expected = get_old_expected_modules(r)
        actual_mods, _, _ = resolve_recipe_via_bash(r)
        missing = expected - actual_mods
        if missing:
            print(f"[-] FAILED (bash): {os.path.basename(r)} is missing expected modules: {missing}")
            failures += 1

    print("\n[*] Testing custom flags via patch_app.py...")
    with tempfile.NamedTemporaryFile("w", suffix=".ini", delete=False) as tf:
        tf.write("""[metadata]
name = Test Flags
bundle_id = com.test.flags

[shims]
statfs_spoof = true
odr_bypass = true
compile_flags = -DCUSTOM_OPT=1 -DTEST_FLAG
link_flags = -lsqlite3
""")
        temp_ini = tf.name

    try:
        mods, cflags, lflags = resolve_recipe_via_python(temp_ini)
        assert "statfs_spoof.m" in mods, f"statfs_spoof.m missing: {mods}"
        assert "odr_bypass.m" in mods, f"odr_bypass.m missing: {mods}"
        assert "-DCUSTOM_OPT=1" in cflags, f"custom compile flags missing: {cflags}"
        assert "-DTEST_FLAG" in cflags, f"custom compile flags missing: {cflags}"
        assert "-lsqlite3" in lflags, f"custom link flags missing: {lflags}"
        print("[+] PASSED: Custom compile_flags and link_flags work as expected!")
    finally:
        os.unlink(temp_ini)

    print("\n[*] Testing dynamic discovery for arbitrary matching file via patch_app.py...")
    with tempfile.NamedTemporaryFile("w", suffix=".ini", delete=False) as tf:
        tf.write("""[shims]
assert_suppress = 1
""")
        temp_ini2 = tf.name

    try:
        mods, _, _ = resolve_recipe_via_python(temp_ini2)
        assert "assert_suppress.c" in mods, f"assert_suppress.c not dynamically discovered: {mods}"
        print("[+] PASSED: Dynamic module discovery matching flag in [shims] works as expected!")
    finally:
        os.unlink(temp_ini2)

    print("\n[*] Testing recipe versioning fallback via patch_app.py...")
    with tempfile.TemporaryDirectory() as tmp_recipes:
        base_ini = os.path.join(tmp_recipes, "com.test.app.ini")
        v2_ini = os.path.join(tmp_recipes, "com.test.app@2.0.ini")
        redir_ini = os.path.join(tmp_recipes, "com.test.app@3.0.ini")
        with open(base_ini, "w") as f:
            f.write("[metadata]\nname = Base\n")
        with open(v2_ini, "w") as f:
            f.write("[metadata]\nname = V2\n")
        with open(redir_ini, "w") as f:
            f.write("target_ini = com.test.app@2.0.ini\n")

        assert patch_app.resolve_recipe(tmp_recipes, "com.test.app", "2.0") == v2_ini
        assert patch_app.resolve_recipe(tmp_recipes, "com.test.app", "1.0") == base_ini
        assert patch_app.resolve_recipe(tmp_recipes, "com.test.app") == base_ini
        assert patch_app.resolve_recipe(tmp_recipes, "com.test.app", "3.0") == v2_ini
        assert patch_app.resolve_recipe(tmp_recipes, "com.test.none", "1.0") is None
        print("[+] PASSED: Recipe versioning fallback (exact -> unversioned -> None) works as expected!")

    if failures == 0:
        print("\n[SUCCESS] ALL VERIFICATION CHECKS PASSED (100% backward compatible)!")
        return 0
    else:
        print(f"\n[FAILURE] {failures} recipes failed verification!")
        return 1

if __name__ == "__main__":
    sys.exit(main())
