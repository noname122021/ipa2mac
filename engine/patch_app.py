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
import time
import zipfile

def setup_logging(log_path):
    fmt = "%(asctime)s [%(levelname)s] %(message)s"
    logging.basicConfig(level=logging.DEBUG, filename=log_path, filemode="a", format=fmt, datefmt="%Y-%m-%d %H:%M:%S")
    ch = logging.StreamHandler(sys.stdout)
    ch.setLevel(logging.INFO)
    ch.setFormatter(logging.Formatter("%(message)s"))
    logging.getLogger().addHandler(ch)

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
    """Apply one or more 'offset:expected_hex:replacement_hex' patches (whitespace/newline separated)."""
    for spec in (patch_spec or "").split():
        if spec.count(":") != 2:
            logging.warning("Skipping malformed binary patch: %s", spec)
            continue
        off_str, exp_hex, rep_hex = spec.split(":")
        offset, rep_bytes = int(off_str, 0), bytes.fromhex(rep_hex)
        with open(bin_path, "r+b") as f:
            f.seek(offset)
            current = f.read(len(rep_bytes))
            if current == rep_bytes:
                logging.info("    [=] Binary patch already present at %s", off_str)
                continue
            if exp_hex != "*" and current != bytes.fromhex(exp_hex):
                logging.warning("Binary patch mismatch at %s (found %s)", off_str, current.hex())
                continue
            f.seek(offset)
            f.write(rep_bytes)
        logging.info("    [+] Applied binary patch at %s", off_str)

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
    override = os.environ.get("RECIPE_OVERRIDE")
    v_path = os.path.join(recipes_dir, f"{bundle_id}@{version}.ini") if version else ""
    default_path = os.path.join(recipes_dir, f"{bundle_id}.ini")
    path = override or (v_path if os.path.isfile(v_path) else default_path)
    if not os.path.isfile(path):
        return None
    with open(path, "r", encoding="utf-8") as f:
        m = re.search(r"^(?:target_ini|path)\s*=\s*([^\r\n;#]+)", f.read(), re.MULTILINE)
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

def to_dict(cfg):
    if hasattr(cfg, "sections"):
        return {k.lower(): v.strip().strip('"') for s in cfg.sections() for k, v in cfg.items(s)}
    return cfg or {}

def find_module(name, modules_dir):
    base = name.removeprefix("mod_")
    for cand in (name, f"{name}.m", f"{name}.c", f"{base}.m", f"{base}.c", f"mod_{base}.m", f"mod_{base}.c"):
        if os.path.isfile(cand):
            return os.path.abspath(cand)
        cand_path = os.path.join(modules_dir, cand)
        if os.path.isfile(cand_path):
            return cand_path
    return None

def collect_modules(cfg, modules_dir):
    cfg = to_dict(cfg)
    targets = [k for k, v in cfg.items() if "." not in k and v.lower() in ("true", "1", "yes")]
    targets += cfg.get("modules", "").replace(",", " ").split()
    if cfg.get("hardware_model"):
        targets.append("device_spoof")
    mods = []
    for t in targets:
        p = find_module(t, modules_dir)
        if p and p not in mods:
            mods.append(p)
    return mods

def build_compile_flags(cfg):
    cfg = to_dict(cfg)
    flags = shlex.split(cfg.get("compile_flags", ""))
    flags += [f"-DTARGET_WIDTH={cfg['width']}"] if "width" in cfg else []
    flags += [f"-DTARGET_HEIGHT={cfg['height']}"] if "height" in cfg else []
    aspect = cfg.get("aspect_ratio", "")
    if ":" in aspect and aspect != "free":
        aw, ah = aspect.split(":", 1)
        flags += [f"-DASPECT_W={aw}", f"-DASPECT_H={ah}"]
    if cfg.get("resizable") == "false":
        flags.append("-DRESIZABLE=0")
    if cfg.get("scale_mode") == "aspect_fit" or cfg.get("uiscreen_bounds_fixed") in ("true", "1", "yes"):
        flags.append("-DHOOK_UISCREEN=1")
    if cfg.get("user_interface_idiom") in ("pad", "1"):
        flags.append("-DIDIOM_PAD=1")
    if "hardware_model" in cfg:
        flags.append(f'-DDEVICE_MODEL="{cfg["hardware_model"]}"')
    if "ascii_path_redirect" in cfg:
        flags.append(f'-DASCII_PATH_TARGET="{cfg["ascii_path_redirect"]}"')
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
    cfg = to_dict(cfg)
    fws = ("Foundation", "Security", "AppKit", "CoreGraphics", "AudioToolbox", "AVFoundation", "Metal", "GameController")
    flags = [x for fw in fws for x in ("-framework", fw)] + shlex.split(cfg.get("link_flags", ""))
    if cfg.get("background_tasks_redirect", "").lower() in ("true", "1", "yes"):
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
            plist = plistlib.load(f) if os.path.isfile(plist_path) else {}
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

        redirect_bg = cfg.get("background_tasks_redirect", "").lower() in ("true", "1", "yes")
        patch_mach_o(main_bin, redirect_bg)
        apply_binary_patch(main_bin, cfg.get("binary_patch", ""))
        patch_all_binaries(app_bundle, redirect_bg)

        mods = collect_modules(cfg, os.path.join(os.path.dirname(os.path.abspath(__file__)), "modules"))
        if os.environ.get("DUMP_MODULES") == "1":
            print("\n".join(os.path.basename(m) for m in mods))
            sys.exit(0)

        cflags, lflags = build_compile_flags(cfg), build_link_flags(cfg)
        logging.info("[*] JIT Compiling libshim.dylib for %s...", os.path.basename(app_bundle))
        target_shim = os.path.join(app_bundle, "libshim.dylib")
        cmd = ["clang", "-dynamiclib", "-arch", "arm64", "-install_name", "@executable_path/libshim.dylib"] + lflags + cflags + mods + ["-o", target_shim]
        subprocess.run(cmd, check=True)
        subprocess.run(["vtool", "-set-build-version", "maccatalyst", "14.0", "14.0", "-replace", "-output", target_shim, target_shim], check=True)
        insert_dylib(main_bin, "@executable_path/libshim.dylib")

        subprocess.run(["xattr", "-cr", app_bundle], capture_output=True)
        bc = cfg.get("bundle_copy", "")
        if ":" in bc:
            s, d = bc.split(":", 1)
            src, dst = os.path.join(app_bundle, s), os.path.join(app_bundle, d)
            if os.path.isfile(src) and not os.path.exists(dst):
                shutil.copyfile(src, dst)

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
