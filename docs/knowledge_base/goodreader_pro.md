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

## 2. Контекст запуска и хронология

GoodReader Pro — один из самых мощных и долгоживущих мобильных просмотрщиков документов, PDF-редакторов и менеджеров файлов на платформе iOS.

Тестирование началось на шагах 107–120 диалога (коммиты `bcdd7e5`, `b7790b7`, `dd467df`). Пользователь зафиксировал мгновенный крэш: *«goodreader открыл, я нажал что принимаю лицензию и он закрылся, через секунду, может упал»*.

---

## 3. Что вызывало баг (Root Cause)

### 3.1. Песочница файловой системы и крах лицензии (`EACCES` / `SIGABRT`)
При первом запуске GoodReader отображает диалог лицензионного соглашения. При нажатии кнопки «Accept» приложение сохраняет криптографический хэш подтверждения и инициализирует базу данных локальных файлов SQLite по пути:
```objc
[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"]
```
В среде Mac Catalyst для ad-hoc подписанных приложений без App Sandbox контейнера вызов `NSHomeDirectory()` возвращает реальную домашнюю папку пользователя `/Users/superuser`, куда приложение не имеет права создавать скрытые системные каталоги песочницы. SQLite возвращал ошибку `sqlite3_open_v2: unable to open database file`, после чего приложение вызывало защитный `abort()`.

### 3.2. Сплющивание двухпанельного интерфейса в мобильный (iPhone Idiom)
По умолчанию macOS запускала приложение с телефонными метриками (`UIUserInterfaceIdiomPhone`), из-за чего пропадало дерево каталогов слева, а панель аннотаций PDF перекрывала текст.

---

## 4. Что мы применили (Applied Solution)

### 4.1. Перенаправление домашней папки через `CFFIXED_USER_HOME` (`utility_shim.m`)
Внедрение конструктора, который гарантирует создание выделенного каталога `~/Documents` и переопределяет низкоуровневую переменную окружения CoreFoundation:

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
        // Перенаправляем домашний путь для всех подсистем CoreFoundation / Cocoa
        setenv("CFFIXED_USER_HOME", [docPath UTF8String], 1);
        NSLog(@"[GoodReader-Shim] Redirected CFFIXED_USER_HOME to %@", docPath);
    }
}
```

### 4.2. Принудительное включение планшетного интерфейса (`user_interface_idiom = pad`)
В `mod_window.m` свитчится селектор `-[UIDevice userInterfaceIdiom]`, возвращая значение `UIUserInterfaceIdiomPad` (`1`). Это автоматически разворачивает полноценный двухколоночный десктопный режим GoodReader с деревом файлов, панелью предпросмотра и закладками.

### 4.3. In-Memory Keychain для паролей к документам (`core_keychain.c`)
Защищенные паролями PDF-файлы используют связку ключей для кэширования мастер-ключей AES. Стаб связки ключей возвращает статус успеха без сбоев авторизации.

---

## 5. Текущий статус и верификация

- **Статус**: **Verified / Fully Working Production Quality**
- **Функционал**: Открытие многостраничных тяжелых PDF-документов, мгновенный зум, рисование пометок стилусом/мышью, просмотр локальных файлов, вкладки чтения.
- **Рецептурный файл**: `recipes/com.goodiware.grpro.ini`

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
