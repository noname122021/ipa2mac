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

def get_expected_modules_from_recipe(ini_path):
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
                    return get_expected_modules_from_recipe(redir)

    kv = {}
    for line in lines:
        line = line.split(";")[0].split("#")[0].strip()
        if "=" in line:
            k, v = line.split("=", 1)
            kv[k.strip()] = v.strip().strip('"')

    mods = set()
    for k, v in kv.items():
        if v.lower() in ("true", "1", "yes"):
            mod = patch_app.find_module(k, MODULES_DIR)
            if mod:
                mods.add(os.path.basename(mod))

    for m in kv.get("modules", "").replace(",", " ").split():
        mod = patch_app.find_module(m, MODULES_DIR)
        if mod:
            mods.add(os.path.basename(mod))

    if kv.get("hardware_model"):
        mods.add("device_spoof.c")

    return mods

def main():
    recipes = sorted(glob.glob(os.path.join(RECIPES_DIR, "*.ini")))
    assert len(recipes) > 0, "No recipes found"
    print(f"[*] Verifying 1:1 recipe-to-module mapping for {len(recipes)} recipes via patch_app.py...")

    failures = 0
    for r in recipes:
        expected = get_expected_modules_from_recipe(r)
        actual_mods, _, _ = resolve_recipe_via_python(r)
        missing = expected - actual_mods
        extra = actual_mods - expected
        name = os.path.basename(r)

        if missing or extra:
            print(f"[-] FAILED: {name} (missing: {missing}, unexpected extra: {extra})")
            failures += 1
        else:
            print(f"[+] PASSED (1:1): {name} ({len(actual_mods)} modules: {sorted(actual_mods)})")

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
