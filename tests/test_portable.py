#!/usr/bin/env python3
"""Verification for portable neighbor folder redirection (odr_external & portable_home)."""
import os
import subprocess
import tempfile
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODULES = os.path.join(ROOT, "engine", "modules")


def test_portable_home():
    with tempfile.TemporaryDirectory() as tmp:
        app_dir = os.path.join(tmp, "TestGame.app")
        os.makedirs(app_dir)
        with open(os.path.join(app_dir, "Info.plist"), "w") as f:
            f.write("""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>TestGame</string>
    <key>CFBundleIdentifier</key><string>com.test.portable</string>
</dict></plist>""")

        # Scenario 1: Flat unpack (_Data/Caches exists)
        data_dir = os.path.join(tmp, "TestGame_Data")
        os.makedirs(os.path.join(data_dir, "Caches"))
        with open(os.path.join(data_dir, "Caches", "asset.dat"), "w") as f:
            f.write("OK_CACHE")

        shim_dylib = os.path.join(app_dir, "libshim.dylib")
        subprocess.run(["clang", "-dynamiclib", "-framework", "Foundation",
                        os.path.join(MODULES, "portable_home.m"), "-o", shim_dylib], check=True)

        test_bin = os.path.join(app_dir, "TestGame")
        test_src = os.path.join(tmp, "main.m")
        with open(test_src, "w") as f:
            f.write("""#import <Foundation/Foundation.h>
int main() {
    // 1. Home directory interposed to TestGame_Data
    if (![NSHomeDirectory() hasSuffix:@"TestGame_Data"]) return 1;

    // 2. Documents directory in TestGame_Data/Documents
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (![docs.firstObject containsString:@"TestGame_Data/Documents"]) return 2;

    // 3. Caches directory resolved to TestGame_Data
    NSArray *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    if (![caches.firstObject containsString:@"TestGame_Data"]) return 3;

    // 4. Auto-symlink from Caches to Library/Caches delivers files
    NSString *asset = [caches.firstObject stringByAppendingPathComponent:@"asset.dat"];
    NSString *content = [NSString stringWithContentsOfFile:asset encoding:NSUTF8StringEncoding error:nil];
    if (![content isEqualToString:@"OK_CACHE"]) return 4;

    // 5. System directories (SystemDomainMask) are NOT hijacked
    NSArray *sys = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSSystemDomainMask, YES);
    if ([sys.firstObject containsString:@"TestGame_Data"]) return 5;

    return 0;
}""")
        subprocess.run(["clang", "-framework", "Foundation", test_src, "-o", test_bin], check=True)
        res = subprocess.run([test_bin], env={**os.environ, "DYLD_INSERT_LIBRARIES": shim_dylib},
                             capture_output=True, text=True)
        assert res.returncode == 0, f"portable_home test failed with code {res.returncode}: {res.stderr}"
        print("[+] PASSED: portable_home redirects data container, preserves system domains & auto-links Caches")

        # Scenario 2: Nested unpack (_Data/ArchiveFolder/Caches exists)
        os.remove(os.path.join(data_dir, "Caches", "asset.dat"))
        os.rmdir(os.path.join(data_dir, "Caches"))
        if os.path.exists(os.path.join(data_dir, "Library")):
            import shutil; shutil.rmtree(os.path.join(data_dir, "Library"))
        nested = os.path.join(data_dir, "UnpackedArchive", "Caches")
        os.makedirs(nested)
        with open(os.path.join(nested, "asset.dat"), "w") as f:
            f.write("OK_CACHE")

        res2 = subprocess.run([test_bin], env={**os.environ, "DYLD_INSERT_LIBRARIES": shim_dylib},
                              capture_output=True, text=True)
        assert res2.returncode == 0, f"nested portable_home test failed with code {res2.returncode}: {res2.stderr}"
        print("[+] PASSED: portable_home auto-discovers nested unzipped cache folders")


def test_odr_external():
    with tempfile.TemporaryDirectory() as tmp:
        app_dir = os.path.join(tmp, "RedDeadRedemption.app")
        os.makedirs(os.path.join(app_dir, "game"))
        with open(os.path.join(app_dir, "Info.plist"), "w") as f:
            f.write("""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>RedDeadRedemption</string>
    <key>CFBundleIdentifier</key><string>com.rockstargames.rdr</string>
</dict></plist>""")

        data_dir = os.path.join(tmp, "RedDeadRedemption_Data")
        os.makedirs(data_dir)
        with open(os.path.join(data_dir, "test.rpf"), "w") as f:
            f.write("OK_RPF")

        shim_dylib = os.path.join(app_dir, "libshim.dylib")
        cflags = ["-DODR_EXTERNAL_DIR=\"Library/Application Support/Got/data\"", "-DODR_EXTERNAL_SUBDIR=\"game\""]
        subprocess.run(["clang", "-dynamiclib", "-framework", "Foundation", *cflags,
                        os.path.join(MODULES, "odr_external.m"), "-o", shim_dylib], check=True)

        test_bin = os.path.join(app_dir, "RedDeadRedemption")
        test_src = os.path.join(tmp, "main.m")
        with open(test_src, "w") as f:
            f.write("""#import <Foundation/Foundation.h>
#import <fcntl.h>
#import <unistd.h>
int main() {
    NSString *p = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"game/test.rpf"];
    int fd = open(p.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) return 1;
    char b[8] = {0};
    read(fd, b, 6);
    close(fd);
    return strcmp(b, "OK_RPF") == 0 ? 0 : 2;
}""")
        subprocess.run(["clang", "-framework", "Foundation", test_src, "-o", test_bin], check=True)
        res = subprocess.run([test_bin], env={**os.environ, "DYLD_INSERT_LIBRARIES": shim_dylib},
                             capture_output=True, text=True)
        assert res.returncode == 0, f"odr_external test failed: {res.stderr}"
        print("[+] PASSED: odr_external redirects asset pack to neighbor folder")


if __name__ == "__main__":
    test_portable_home()
    test_odr_external()
    print("[SUCCESS] All portable tests passed!")
