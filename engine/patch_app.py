#!/usr/bin/env python3
import configparser
import glob
import logging
import os
import runpy
import plistlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile

from insert_dylib import insert_dylib

def setup_logging(log_path):
    fmt = "%(asctime)s [%(levelname)s] %(message)s"
    logging.basicConfig(level=logging.DEBUG, filename=log_path, filemode="a", format=fmt, datefmt="%Y-%m-%d %H:%M:%S")
    ch = logging.StreamHandler(sys.stdout)
    ch.setLevel(logging.INFO)
    ch.setFormatter(logging.Formatter("%(message)s"))
    logging.getLogger().addHandler(ch)

def extract_ipa(ipa_path, dest_dir):
    with zipfile.ZipFile(ipa_path, "r") as zf:
        for info in zf.infolist():
            extracted = zf.extract(info, dest_dir)
            if info.external_attr >> 16:
                os.chmod(extracted, info.external_attr >> 16)
    apps = glob.glob(os.path.join(dest_dir, "Payload", "*.app"))
    if not apps:
        raise FileNotFoundError("No .app bundle found in IPA Payload")
    return apps[0]

def resolve_recipe(recipes_dir, bundle_id, version=None):
    v_path = os.path.join(recipes_dir, f"{bundle_id}@{version}.ini") if version else ""
    default_path = os.path.join(recipes_dir, f"{bundle_id}.ini")
    path = (v_path if os.path.isfile(v_path) else default_path)
    if not os.path.isfile(path):
        return None
    with open(path, "r", encoding="utf-8") as f:   # alias recipe: [include] path = other.ini
        m = re.search(r"^path\s*=\s*([^\r\n;#]+)", f.read(), re.MULTILINE)
    if m:
        target = os.path.join(recipes_dir, m.group(1).strip().strip('"'))
        return target if os.path.isfile(target) else path
    return path

def load_recipe(recipe_path):
    """Flat {key: value} of all sections. A section named after a module enabled in another section
    ([shims] mod_x = true -> [mod_x]) holds that module's parameters; its keys become "mod_x.key"."""
    cp = configparser.ConfigParser(inline_comment_prefixes=(";", "#"))
    if recipe_path and os.path.isfile(recipe_path):
        cp.read(recipe_path, encoding="utf-8")
    flat = {k.lower(): v.strip().strip('"') for s in cp.sections() for k, v in cp.items(s)}
    out = {}
    for s in cp.sections():
        mod = s.lower() if s.lower() in flat else None
        for k, v in cp.items(s):
            out[f"{mod}.{k.lower()}" if mod else k.lower()] = v.strip().strip('"')
    return out

def is_on(v):
    return str(v).lower() in ("true", "1", "yes")

def collect_modules(cfg, modules_dir):
    """Every `name = true` with engine/modules/name.{m,c,py} is a module."""
    mods = []
    for k, v in cfg.items():
        if "." in k or not is_on(v):
            continue
        for ext in (".m", ".c", ".py"):
            p = os.path.join(modules_dir, k + ext)
            if os.path.isfile(p) and p not in mods:
                mods.append(p)
    return mods

def module_params(cfg, path):
    name = os.path.splitext(os.path.basename(path))[0]
    return {k.split(".", 1)[1]: v for k, v in cfg.items() if k.startswith(name + ".")}

def build_compile_flags(cfg):
    flags = []
    # Module parameters: [mod_x] key = value -> -DMOD_X_KEY=value (bool -> 1/0, integer as is, else string)
    for k, v in cfg.items():
        if "." not in k:
            continue
        name = k.replace(".", "_").upper()
        v = " ".join(v.split())   # multi-line ini values -> one line
        val = {"true": "1", "yes": "1", "false": "0", "no": "0"}.get(v.lower(), v)
        flags.append(f"-D{name}={val}" if re.fullmatch(r"-?\d+", val) else f'-D{name}="{val}"')
    return flags

def build_link_flags(cfg):
    fws = ("Foundation", "Security", "AppKit", "CoreGraphics", "AudioToolbox", "AVFoundation", "Metal", "GameController")
    flags = [x for fw in fws for x in ("-framework", fw)]
    if is_on(cfg.get("background_tasks_redirect")):
        flags.append("-Wl,-reexport_framework,BackgroundTasks")
    return flags

def patch_mach_o(bin_path, redirect_bg=False):
    os.chmod(bin_path, 0o755)
    res = subprocess.run(["lipo", "-archs", bin_path], capture_output=True, text=True)
    if "arm64" in res.stdout and " " in res.stdout.strip():
        subprocess.run(["lipo", "-thin", "arm64", bin_path, "-output", f"{bin_path}.thin"], check=True)
        os.replace(f"{bin_path}.thin", bin_path)
    subprocess.run(["vtool", "-set-build-version", "maccatalyst", "14.0", "14.0", "-replace", "-output", bin_path, bin_path], capture_output=True)
    otool = subprocess.run(["otool", "-L", bin_path], capture_output=True, text=True)
    for line in otool.stdout.splitlines():
        dep = line.strip().split()[0] if line.strip() else ""
        if redirect_bg and "BackgroundTasks.framework" in dep:
            subprocess.run(["install_name_tool", "-change", dep, "@executable_path/libshim.dylib", bin_path], capture_output=True)
        elif "libswiftUIKit.dylib" in dep:
            sys_uikit = "/System/iOSSupport/System/Library/Frameworks/UIKit.framework/UIKit"
            subprocess.run(["install_name_tool", "-change", dep, sys_uikit, bin_path], capture_output=True)

def patch_all_binaries(app_bundle, redirect_bg=False):
    for root, dirs, files in os.walk(app_bundle):
        for d in [d for d in dirs if d.endswith((".framework", ".appex"))]:
            target = os.path.join(root, d, os.path.splitext(d)[0])
            if os.path.isfile(target):
                patch_mach_o(target, redirect_bg)
        for f in [f for f in files if f.endswith(".dylib")]:
            patch_mach_o(os.path.join(root, f), redirect_bg)

def patch_plist(plist_path):
    with open(plist_path, "rb") as f:
        data = plistlib.load(f)
    data["CFBundleSupportedPlatforms"] = ["iPhoneOS", "MacOSX"]
    data["LSMinimumSystemVersion"] = "14.0"
    data["UIDeviceFamily"] = [1, 2, 6]
    data.pop("UIRequiredDeviceCapabilities", None)
    with open(plist_path, "wb") as f:
        plistlib.dump(data, f)

def codesign_bundle(app_bundle):
    logging.info("[*] Codesigning binaries and bundle...")
    # Nested code first: --deep alone keeps stale vendor signatures on embedded frameworks.
    for root, dirs, files in os.walk(app_bundle, topdown=False):
        for it in [os.path.join(root, d) for d in dirs if d.endswith((".framework", ".appex"))] + \
                  [os.path.join(root, f) for f in files if f.endswith(".dylib")]:
            subprocess.run(["codesign", "-f", "-s", "-", it], capture_output=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--deep", app_bundle], check=True)

def patch_app(target, output_dir=None):
    start_time = time.time()
    temp_dir = tempfile.mkdtemp(prefix="ipa_patch_") if target.endswith(".ipa") else None
    try:
        app_bundle = extract_ipa(target, temp_dir) if temp_dir else target
        logging.info("[*] Target app bundle: %s", app_bundle)
        plist_path = os.path.join(app_bundle, "Info.plist")
        with open(plist_path, "rb") as f:
            plist = plistlib.load(f)
        exe = plist.get("CFBundleExecutable") or os.path.splitext(os.path.basename(app_bundle))[0]
        main_bin = os.path.join(app_bundle, exe)
        os.chmod(main_bin, 0o755)
        archs = subprocess.run(["lipo", "-archs", main_bin], capture_output=True, text=True).stdout
        if "arm64" not in archs:
            raise ValueError(f"ipa2mac requires 64-bit arm64 ({archs.strip()})")

        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        app_ver = plist.get("CFBundleShortVersionString") or plist.get("CFBundleVersion")
        recipe_path = resolve_recipe(os.path.join(root, "recipes"), plist.get("CFBundleIdentifier", ""), app_ver)
        cfg = load_recipe(recipe_path)
        if recipe_path:
            shutil.copyfile(recipe_path, os.path.join(app_bundle, "recipe.ini"))

        redirect_bg = is_on(cfg.get("background_tasks_redirect"))
        patch_mach_o(main_bin, redirect_bg)
        patch_all_binaries(app_bundle, redirect_bg)

        mods = collect_modules(cfg, os.path.join(os.path.dirname(os.path.abspath(__file__)), "modules"))
        native = [m for m in mods if not m.endswith(".py")]
        cflags, lflags = build_compile_flags(cfg), build_link_flags(cfg)
        logging.info("[*] JIT Compiling libshim.dylib for %s...", os.path.basename(app_bundle))
        target_shim = os.path.join(app_bundle, "libshim.dylib")
        cmd = ["clang", "-dynamiclib", "-arch", "arm64", "-install_name", "@executable_path/libshim.dylib"] + lflags + cflags + native + ["-o", target_shim]
        subprocess.run(cmd, check=True)
        subprocess.run(["vtool", "-set-build-version", "maccatalyst", "14.0", "14.0", "-replace", "-output", target_shim, target_shim], check=True)
        insert_dylib(main_bin, "@executable_path/libshim.dylib")
        for py in (m for m in mods if m.endswith(".py")):   # bundle-level modules: apply(app_bundle)
            logging.info("[*] Python module %s", os.path.basename(py))
            runpy.run_path(py)["apply"](app_bundle, module_params(cfg, py))

        subprocess.run(["xattr", "-cr", app_bundle], capture_output=True)

        patch_plist(plist_path)
        codesign_bundle(app_bundle)

        if temp_dir:
            out_dir = output_dir or os.path.dirname(os.path.abspath(target))
            dest = os.path.join(out_dir, os.path.basename(app_bundle))
            if os.path.exists(dest):
                shutil.rmtree(dest) if os.path.isdir(dest) else os.remove(dest)
            shutil.move(app_bundle, dest)
            app_bundle = dest

        subprocess.run(["/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", "-f", app_bundle], capture_output=True)
        logging.info("[%5.1fs] [+] Successfully patched %s", time.time() - start_time, app_bundle)
        bid = plist.get("CFBundleIdentifier", "")
        logging.info("[*] Data container: ~/Library/Containers/%s/Data", bid)
        return app_bundle
    except Exception as e:
        logging.error("[%5.1fs] [-] Conversion failed: %s", time.time() - start_time, e)
        raise
    finally:
        if temp_dir and os.path.isdir(temp_dir):
            shutil.rmtree(temp_dir, ignore_errors=True)

def run_repl():
    print("=================================================\n           ipa2mac — iOS to Mac Converter         \n=================================================")
    while True:
        try:
            line = input("\nDrag and drop your non-encrypted 64-bit .ipa file here:\n(or paste the file path and press Enter)\n> ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\nExiting.")
            break
        target = (shlex.split(line.removeprefix("file://")) or [""])[0] if line else ""
        if not target:
            continue
        if not os.path.exists(target):
            print(f"[-] Error: File not found: {target}")
            continue
        try:
            patch_app(target)
            print("\n[+] Done! Ready for next file.")
        except Exception:
            logging.debug("REPL conversion error", exc_info=True)
            print("[-] Check ipa2mac.log for details.")

def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    setup_logging(os.path.join(root, "ipa2mac.log"))
    if len(sys.argv) == 1:
        run_repl()
        return 0
    try:
        patch_app(sys.argv[1].removeprefix("file://"), sys.argv[2] if len(sys.argv) > 2 else None)
        return 0
    except Exception:
        logging.debug("Batch conversion error", exc_info=True)
        print("[-] Check ipa2mac.log for full details.", file=sys.stderr)
        return 1

if __name__ == "__main__":
    sys.exit(main())
