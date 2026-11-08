#!/usr/bin/env python3
import configparser
import glob
import logging
import os
import plistlib
import re
import shlex
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile

def setup_logging(log_path):
    root = logging.getLogger()
    root.setLevel(logging.DEBUG)
    root.handlers.clear()
    fh = logging.FileHandler(log_path, mode="a", encoding="utf-8")
    fh.setLevel(logging.DEBUG)
    fh.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(message)s", "%Y-%m-%d %H:%M:%S"))
    root.addHandler(fh)
    ch = logging.StreamHandler(sys.stdout)
    ch.setLevel(logging.INFO)
    ch.setFormatter(logging.Formatter("%(message)s"))
    root.addHandler(ch)

def insert_dylib(bin_path, dylib_path):
    with open(bin_path, "rb") as f:
        data = bytearray(f.read())
    magic = struct.unpack_from("<I", data, 0)[0]
    endian = "<" if magic == 0xFEEDFACF else (">" if magic == 0xCFFAEDFE else None)
    if not endian:
        raise ValueError("Not a 64-bit Mach-O binary")
    ncmds, sizeofcmds = struct.unpack_from(f"{endian}II", data, 16)
    off = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from(f"{endian}II", data, off)
        name_off = struct.unpack_from(f"{endian}I", data, off + 8)[0] if cmd in (0xC, 0x80000018, 0xD, 0x18) else 0
        name = data[off + name_off : off + cmdsize].split(b"\x00", 1)[0].decode("utf-8", "ignore") if name_off else ""
        if name == dylib_path:
            logging.info("[*] %s already present", dylib_path)
            return
        off += cmdsize
    path_bytes = dylib_path.encode("utf-8") + b"\x00"
    cmdsize = (24 + len(path_bytes) + 7) & ~7
    pad = cmdsize - 24 - len(path_bytes)
    cmds_end = 32 + sizeofcmds
    if len(data) < cmds_end + cmdsize or data[cmds_end : cmds_end + cmdsize] != b"\x00" * cmdsize:
        raise ValueError(f"Not enough zero-padding to insert LC_LOAD_DYLIB ({cmdsize} bytes needed)")
    cmd = struct.pack(f"{endian}IIIIII", 0xC, cmdsize, 24, 2, 0x10000, 0x10000) + path_bytes + (b"\x00" * pad)
    data[cmds_end : cmds_end + cmdsize] = cmd
    struct.pack_into(f"{endian}II", data, 16, ncmds + 1, sizeofcmds + cmdsize)
    with open(bin_path, "wb") as f:
        f.write(data)
    logging.info("[+] Injected %s", dylib_path)

def apply_binary_patch(bin_path, patch_spec):
    if not patch_spec or ":" not in patch_spec:
        return
    off_str, exp_hex, rep_hex = patch_spec.split(":", 2)
    offset = int(off_str, 0)
    rep_bytes = bytes.fromhex(rep_hex)
    with open(bin_path, "r+b") as f:
        f.seek(offset)
        if exp_hex != "*" and f.read(len(rep_bytes)) != bytes.fromhex(exp_hex):
            logging.warning("Binary patch mismatch at %s", off_str)
            return
        f.seek(offset)
        f.write(rep_bytes)
    logging.info("    [+] Applied binary patch at %s", off_str)

def extract_ipa(ipa_path, dest_dir):
    with zipfile.ZipFile(ipa_path, "r") as zf:
        for info in zf.infolist():
            extracted = zf.extract(info, dest_dir)
            mode = info.external_attr >> 16
            if mode:
                os.chmod(extracted, mode)
    apps = glob.glob(os.path.join(dest_dir, "Payload", "*.app"))
    if not apps:
        raise FileNotFoundError("No .app bundle found in IPA Payload")
    return apps[0]

def resolve_recipe(recipes_dir, bundle_id):
    override = os.environ.get("RECIPE_OVERRIDE")
    recipe_file = override if override else os.path.join(recipes_dir, f"{bundle_id}.ini")
    if not os.path.isfile(recipe_file):
        return None
    with open(recipe_file, "r", encoding="utf-8") as f:
        content = f.read()
    m = re.search(r"^(target_ini|path)\s*=\s*([^\r\n;#]+)", content, re.MULTILINE)
    if not m:
        return recipe_file
    target = os.path.join(recipes_dir, m.group(2).strip().strip('"'))
    return target if os.path.isfile(target) else recipe_file

def load_recipe(recipe_path):
    cp = configparser.ConfigParser(inline_comment_prefixes=(";", "#"))
    if recipe_path and os.path.isfile(recipe_path):
        cp.read(recipe_path, encoding="utf-8")
    return cp

def recipe_val(cp, key, default=""):
    for sec in cp.sections():
        if cp.has_option(sec, key):
            return cp.get(sec, key).strip().strip('"')
    return default

def recipe_flag(cp, key):
    return recipe_val(cp, key).lower() in ("true", "1", "yes")

def find_module(name, modules_dir):
    base = name[4:] if name.startswith("mod_") else name
    cands = [name, f"{name}.m", f"{name}.c", f"{base}.m", f"{base}.c", f"mod_{base}.m", f"mod_{base}.c"]
    for c in cands:
        if os.path.isfile(c):
            return os.path.abspath(c)
        cand = os.path.join(modules_dir, c)
        if os.path.isfile(cand):
            return cand
    return None

def collect_modules(cp, modules_dir):
    defaults = ["core_keychain.c", "mod_window.m", "mod_window_close.m", "mod_input_context.m"]
    mods = [os.path.join(modules_dir, m) for m in defaults if os.path.isfile(os.path.join(modules_dir, m))]
    def add(target):
        p = find_module(target, modules_dir)
        if p and p not in mods:
            mods.append(p)
    if cp.has_section("shims"):
        for opt, val in cp.items("shims"):
            if val.strip().strip('"').lower() in ("true", "1", "yes"):
                add(opt)
    for m in [x.strip() for x in recipe_val(cp, "modules").replace(",", " ").split() if x.strip()]:
        add(m)
    if recipe_val(cp, "hardware_model"):
        add("device_spoof")
    if "unreal" in recipe_val(cp, "engine") or recipe_val(cp, "ascii_path_redirect"):
        add("fake_mpmovieplayer")
    if recipe_flag(cp, "background_tasks_redirect"):
        add("background_tasks_redirect")
    return mods

def build_compile_flags(cp):
    flags = shlex.split(recipe_val(cp, "compile_flags"))
    w, h = recipe_val(cp, "width"), recipe_val(cp, "height")
    if w:
        flags.append(f"-DTARGET_WIDTH={w}")
    if h:
        flags.append(f"-DTARGET_HEIGHT={h}")
    aspect = recipe_val(cp, "aspect_ratio")
    if aspect and aspect != "free" and ":" in aspect:
        aw, ah = aspect.split(":", 1)
        flags.extend([f"-DASPECT_W={aw}", f"-DASPECT_H={ah}"])
    if recipe_val(cp, "resizable") == "false":
        flags.append("-DRESIZABLE=0")
    if recipe_val(cp, "scale_mode") == "aspect_fit" or recipe_flag(cp, "uiscreen_bounds_fixed"):
        flags.append("-DHOOK_UISCREEN=1")
    if recipe_val(cp, "user_interface_idiom") in ("pad", "1"):
        flags.append("-DIDIOM_PAD=1")
    if recipe_val(cp, "hardware_model"):
        flags.append(f'-DDEVICE_MODEL="{recipe_val(cp, "hardware_model")}"')
    if recipe_val(cp, "ascii_path_redirect"):
        flags.append(f'-DASCII_PATH_TARGET="{recipe_val(cp, "ascii_path_redirect")}"')
    return flags

def build_link_flags(cp):
    fws = ["Foundation", "Security", "AppKit", "CoreGraphics", "AudioToolbox", "AVFoundation"]
    flags = [x for fw in fws for x in ("-framework", fw)] + shlex.split(recipe_val(cp, "link_flags"))
    if recipe_flag(cp, "background_tasks_redirect"):
        flags.append("-Wl,-reexport_framework,BackgroundTasks")
    return flags

def patch_mach_o(bin_path, redirect_bg=False):
    os.chmod(bin_path, 0o755)
    res = subprocess.run(["lipo", "-archs", bin_path], capture_output=True, text=True)
    archs = res.stdout.strip()
    if "arm64" in archs and " " in archs:
        thin = f"{bin_path}.thin"
        subprocess.run(["lipo", "-thin", "arm64", bin_path, "-output", thin], check=True)
        os.replace(thin, bin_path)
    subprocess.run(["vtool", "-set-build-version", "maccatalyst", "14.0", "14.0", "-replace", "-output", bin_path, bin_path], capture_output=True)
    if redirect_bg:
        otool = subprocess.run(["otool", "-L", bin_path], capture_output=True, text=True)
        for line in otool.stdout.splitlines():
            if "BackgroundTasks.framework" in line:
                bg = line.strip().split()[0]
                subprocess.run(["install_name_tool", "-change", bg, "@executable_path/libshim.dylib", bin_path], capture_output=True)

def patch_all_binaries(app_bundle, redirect_bg=False):
    fw_dir = os.path.join(app_bundle, "Frameworks")
    if os.path.isdir(fw_dir):
        for fw in glob.glob(os.path.join(fw_dir, "*.framework")):
            name = os.path.splitext(os.path.basename(fw))[0]
            if os.path.isfile(os.path.join(fw, name)):
                patch_mach_o(os.path.join(fw, name), redirect_bg)
        for dylib in glob.glob(os.path.join(fw_dir, "*.dylib")):
            patch_mach_o(dylib, redirect_bg)
    plugins_dir = os.path.join(app_bundle, "PlugIns")
    if os.path.isdir(plugins_dir):
        for appex in glob.glob(os.path.join(plugins_dir, "*.appex")):
            name = os.path.splitext(os.path.basename(appex))[0]
            if os.path.isfile(os.path.join(appex, name)):
                patch_mach_o(os.path.join(appex, name), redirect_bg)

def patch_plist(plist_path):
    if not os.path.isfile(plist_path):
        return
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
    items = []
    for root, dirs, files in os.walk(app_bundle, topdown=False):
        items.extend([os.path.join(root, d) for d in dirs if d.endswith(".framework") or d.endswith(".appex")])
        items.extend([os.path.join(root, f) for f in files if f.endswith(".dylib")])
    for it in items:
        subprocess.run(["codesign", "-f", "-s", "-", it], capture_output=True)
    subprocess.run(["codesign", "-f", "-s", "-", "--deep", app_bundle], check=True)

def patch_app(target, output_dir=None):
    temp_dir = tempfile.mkdtemp(prefix="ipa_patch_") if target.endswith(".ipa") else None
    try:
        app_bundle = extract_ipa(target, temp_dir) if temp_dir else target
        if not os.path.isdir(app_bundle):
            raise ValueError(f"Target is not a valid .app bundle: {app_bundle}")
        logging.info("[*] Target app bundle: %s", app_bundle)
        plist_path = os.path.join(app_bundle, "Info.plist")
        with open(plist_path, "rb") as f:
            plist = plistlib.load(f) if os.path.isfile(plist_path) else {}
        bundle_id = plist.get("CFBundleIdentifier", "")
        exe_name = plist.get("CFBundleExecutable") or os.path.splitext(os.path.basename(app_bundle))[0]
        main_bin = os.path.join(app_bundle, exe_name)
        os.chmod(main_bin, 0o755)
        res = subprocess.run(["lipo", "-archs", main_bin], capture_output=True, text=True)
        if "arm64" not in res.stdout:
            raise ValueError(f"ipa2mac requires 64-bit arm64 ({res.stdout.strip()})")

        recipes_dir = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "recipes")
        modules_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "modules")
        recipe_path = resolve_recipe(recipes_dir, bundle_id)
        cp = load_recipe(recipe_path)
        if recipe_path:
            shutil.copyfile(recipe_path, os.path.join(app_bundle, "recipe.ini"))

        redirect_bg = recipe_flag(cp, "background_tasks_redirect")
        patch_mach_o(main_bin, redirect_bg)
        apply_binary_patch(main_bin, recipe_val(cp, "binary_patch"))
        patch_all_binaries(app_bundle, redirect_bg)

        mods = collect_modules(cp, modules_dir)
        if os.environ.get("DUMP_MODULES") == "1":
            print("\n".join(os.path.basename(m) for m in mods))
            sys.exit(0)

        cflags, lflags = build_compile_flags(cp), build_link_flags(cp)
        logging.info("[*] JIT Compiling libshim.dylib for %s...", os.path.basename(app_bundle))
        target_shim = os.path.join(app_bundle, "libshim.dylib")
        cmd = ["clang", "-dynamiclib", "-arch", "arm64", "-install_name", "@executable_path/libshim.dylib"] + lflags + cflags + mods + ["-o", target_shim]
        subprocess.run(cmd, check=True)
        subprocess.run(["vtool", "-set-build-version", "maccatalyst", "14.0", "14.0", "-replace", "-output", target_shim, target_shim], check=True)
        insert_dylib(main_bin, "@executable_path/libshim.dylib")

        subprocess.run(["xattr", "-cr", app_bundle], capture_output=True)
        bc = recipe_val(cp, "bundle_copy")
        if bc and ":" in bc:
            s, d = bc.split(":", 1)
            if os.path.isfile(os.path.join(app_bundle, s)) and not os.path.exists(os.path.join(app_bundle, d)):
                shutil.copyfile(os.path.join(app_bundle, s), os.path.join(app_bundle, d))

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
        logging.info("[+] Successfully patched %s", app_bundle)
        return app_bundle
    finally:
        if temp_dir and os.path.isdir(temp_dir):
            shutil.rmtree(temp_dir, ignore_errors=True)

def clean_input_path(raw):
    p = raw.strip()
    if p.startswith("file://"):
        p = p[7:]
    args = shlex.split(p) if ("'" in p or '"' in p or "\\" in p) else [p]
    return args[0] if args else p

def run_repl():
    print("=================================================")
    print("           ipa2mac — iOS to Mac Converter         ")
    print("=================================================")
    while True:
        print("\nDrag and drop your non-encrypted 64-bit .ipa file here:")
        print("(or paste the file path and press Enter)")
        try:
            line = input("> ")
        except (EOFError, KeyboardInterrupt):
            print("\nExiting.")
            break
        target = clean_input_path(line)
        if not target:
            continue
        if not os.path.exists(target):
            print(f"[-] Error: File not found: {target}")
            continue
        try:
            patch_app(target)
            print("\n[+] Done! Ready for next file.")
        except Exception as e:
            logging.debug("REPL conversion error", exc_info=True)
            print(f"[-] Conversion failed for {target}: {e}\n[-] Check ipa2mac.log for details.")

def main():
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    setup_logging(os.path.join(repo_root, "ipa2mac.log"))
    if len(sys.argv) == 1:
        run_repl()
        return 0
    target = sys.argv[1].removeprefix("file://")
    out_dir = sys.argv[2] if len(sys.argv) > 2 else None
    try:
        patch_app(target, out_dir)
        return 0
    except Exception as e:
        logging.debug("Batch conversion error", exc_info=True)
        print(f"[-] Conversion failed: {e}", file=sys.stderr)
        print("[-] Check ipa2mac.log for full details.", file=sys.stderr)
        return 1

if __name__ == "__main__":
    sys.exit(main())
