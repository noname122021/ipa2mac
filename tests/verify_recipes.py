#!/usr/bin/env python3
"""Recipe checks (no IPA needed):
1. [shims] holds only module names: every key has engine/modules/<key>.{m,c,py}.
2. Every other section except [metadata]/[notes]/[include] is the parameter section of an enabled module.
3. libshim compiles for every recipe with its modules and flags.
"""
import configparser
import glob
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "engine"))
import patch_app  # noqa: E402

MODULES = os.path.join(ROOT, "engine", "modules")
INFO = {"metadata", "notes", "include"}


def check(path):
    errors = []
    cp = configparser.ConfigParser(inline_comment_prefixes=(";", "#"))
    cp.read(path, encoding="utf-8")
    if cp.has_section("include"):
        return errors
    shims = dict(cp.items("shims")) if cp.has_section("shims") else {}
    for k in shims:
        if not any(os.path.isfile(os.path.join(MODULES, k + e)) for e in (".m", ".c", ".py")):
            errors.append(f"[shims] {k}: no module engine/modules/{k}.*")
    for s in cp.sections():
        if s not in INFO and s != "shims" and not patch_app.is_on(shims.get(s)):
            errors.append(f"[{s}]: not an enabled module")

    cfg = patch_app.load_recipe(path)
    native = [m for m in patch_app.collect_modules(cfg, MODULES) if not m.endswith(".py")]
    with tempfile.TemporaryDirectory() as tmp:
        cmd = ["clang", "-dynamiclib", "-arch", "arm64", *patch_app.build_link_flags(cfg),
               *patch_app.build_compile_flags(cfg), *native, "-o", os.path.join(tmp, "libshim.dylib")]
        res = subprocess.run(cmd, capture_output=True, text=True)
        if res.returncode:
            errors.append("compile failed:\n" + res.stderr.strip()[-800:])
    return errors


def main():
    failed = 0
    for r in sorted(glob.glob(os.path.join(ROOT, "recipes", "*.ini"))):
        errs = check(r)
        print(("FAIL " if errs else "ok   ") + os.path.basename(r))
        for e in errs:
            print("     " + e)
        failed += bool(errs)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
