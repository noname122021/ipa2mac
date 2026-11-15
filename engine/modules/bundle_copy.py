"""Copy a file inside the .app (e.g. an asset the game looks up under another name).

[shims]       bundle_copy = true
[bundle_copy] files = <src>:<dst> ...   (paths relative to the .app, whitespace separated)
"""
import os
import shutil


def apply(app_bundle, params):
    for pair in params["files"].split():
        src, dst = (os.path.join(app_bundle, p) for p in pair.split(":", 1))
        if not os.path.exists(dst):
            shutil.copyfile(src, dst)
