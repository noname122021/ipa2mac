import os
import subprocess
import logging

def apply(app_bundle, params):
    """Strip unwanted third-party injected dylibs from Mach-O load commands and bundle."""
    raw = params.get("remove", "")
    targets = [x.strip() for x in raw.replace(",", " ").split() if x.strip()]
    if not targets:
        return

    main_bin = os.path.join(app_bundle, os.path.splitext(os.path.basename(app_bundle))[0])
    if not os.path.isfile(main_bin):
        return

    res = subprocess.run(["otool", "-L", main_bin], capture_output=True, text=True)
    for line in res.stdout.splitlines():
        dep = line.strip().split()[0] if line.strip() else ""
        dep_base = os.path.basename(dep)
        if dep_base in targets or any(dep.endswith(t) for t in targets):
            logging.info("[*] Stripping injected dylib: %s", dep)
            subprocess.run(["install_name_tool", "-change", dep, "/usr/lib/libSystem.B.dylib", main_bin], capture_output=True)

    for root, _, files in os.walk(app_bundle):
        for f in files:
            if f in targets:
                try:
                    os.remove(os.path.join(root, f))
                    logging.info("[*] Removed dylib file: %s", f)
                except OSError:
                    pass
