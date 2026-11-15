"""Patch bytes in the main executable.

[shims]        binary_patch = true
[binary_patch] patches = <offset>:<expected hex or *>:<replacement hex> ...   (whitespace/newline separated)
"""
import logging
import os
import plistlib


def apply(app_bundle, params):
    with open(os.path.join(app_bundle, "Info.plist"), "rb") as f:
        exe = os.path.join(app_bundle, plistlib.load(f)["CFBundleExecutable"])
    with open(exe, "r+b") as f:
        for spec in params["patches"].split():
            off, expected, new = spec.split(":")
            off, new = int(off, 0), bytes.fromhex(new)
            f.seek(off)
            cur = f.read(len(new))
            if cur == new:
                logging.info("    [=] %s already patched", hex(off))
            elif expected != "*" and cur != bytes.fromhex(expected):
                raise ValueError(f"binary_patch: {hex(off)} has {cur.hex()}, expected {expected}")
            else:
                f.seek(off)
                f.write(new)
                logging.info("    [+] patched %s", hex(off))
