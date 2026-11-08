# Case Study: GoodReader Pro (PDF Engine & Sandbox Path Redirection)

Authoritative case study and technical post-mortem for running GoodReader Pro on Apple Silicon macOS via `ipa2mac`.

---

## 1. Application Profile

- **Application Name**: GoodReader Pro
- **Bundle Identifier**: `com.goodiware.grpro` (legacy alias `com.goodiware.goodreader4`)
- **Tested Version**: 5.6.1119 (Build 5.6.1119)
- **Minimum iOS Version**: iOS 9.0
- **Engine / Architecture**: GoodiWare Proprietary Objective-C / C++ Engine
- **Graphics Backend**: UIKit / PDFKit / CoreGraphics
- **Audio Stack**: CoreAudio (Audio playback engine)
- **Window Profile**: Free / Multi-column Desktop Document View (`800x1000`, `scale_mode = native`)

---

## 2. Context & Chronology

GoodReader Pro is an advanced document reader, PDF annotator, and file manager for iOS.

During initial testing, accepting the license agreement caused an immediate crash.

---

## 3. Root Cause Analysis

### 3.1. Filesystem Sandbox Collision on License Accept (`EACCES` / `SIGABRT`)
On first launch, GoodReader shows a license dialog. Accepting writes a cryptographic token and initializes an SQLite database at:
```objc
[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"]
```
Under Mac Catalyst with ad-hoc signing, `NSHomeDirectory()` points to `/Users/<username>`. Writing hidden sandbox database files directly to user root failed with `sqlite3_open_v2: unable to open database file`, triggering a defensive `abort()`.

### 3.2. Two-Pane UI Flattened to Mobile Phone Layout
By default, Catalyst initialized with phone metrics (`UIUserInterfaceIdiomPhone`), hiding the file directory tree on the left and overlapping PDF annotation toolbars.

---

## 4. Applied Mitigations

### 4.1. CoreFoundation Sandbox Path Redirection (`CFFIXED_USER_HOME`)
Ensured dedicated `~/Documents` container directory creation and redirected `CFFIXED_USER_HOME`:

```objc
#import <Foundation/Foundation.h>

__attribute__((constructor))
static void init_goodreader_storage(void) {
    @autoreleasepool {
        NSString *docPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
        [[NSFileManager defaultManager] createDirectoryAtPath:docPath 
                                  withIntermediateDirectories:YES 
                                                   attributes:nil 
                                                        error:nil];
        setenv("CFFIXED_USER_HOME", [docPath UTF8String], 1);
        NSLog(@"[GoodReader-Shim] Redirected CFFIXED_USER_HOME to %@", docPath);
    }
}
```

### 4.2. Forcing Tablet Interface (`user_interface_idiom = pad`)
Swizzled `-[UIDevice userInterfaceIdiom]` to return `UIUserInterfaceIdiomPad` (`1`). This restores GoodReader's two-column desktop interface with file trees, preview panels, and bookmark navigation.

### 4.3. In-Memory Keychain for Encrypted Documents (`core_keychain.c`)
Password-protected PDFs utilize keychain access to cache AES master keys. The in-memory keychain stub resolves authorization queries cleanly.

---

## 5. Status & Verification

- **Status**: **Verified / Fully Working Production Quality**
- **Features**: Heavy multi-page PDF rendering, instant zoom, stylus/mouse annotations, local file navigation, and multi-tab reading.
- **Recipe File**: `recipes/com.goodiware.grpro.ini`

```ini
[metadata]
name = GoodReader Pro
bundle_id = com.goodiware.grpro
tested_version = 5.6.1119
engine = native_objc_cpp
rendering = uikit_pdfkit
sound_system = coreaudio

[window]
width = 800
height = 1000
aspect_ratio = free
resizable = true
orientation = free
scale_mode = native

[shims]
user_interface_idiom = pad
path_redirect = documents
cffixed_user_home = true
keychain = in_memory
activation_policy = regular
window_styling = true
window_close_exit = true
```
