# ipa2mac Knowledge Base: iOS-to-macOS App Case Studies & Reversing Field Manual

Центральная база знаний, полевой реестр кейсов и руководство по реверс-инжинирингу проекта **ipa2mac**. 

Здесь задокументирован опыт адаптации не зашифрованных (`cryptid = 0`) 64-битных (`arm64`) iOS-приложений для нативного исполнения на компьютерах Apple Silicon (M1/M2/M3/M4) под управлением macOS через технологию Mac Catalyst (`LC_BUILD_VERSION platform 6`) и модульный микро-шим `libshim.dylib`.

---

## 1. Сводная таблица разобранных кейсов (Master Application Register)

| Приложение | Bundle ID | Версия | Движок / Стек | Графика / Звук | Класс корневой проблемы | Ключевые примененные фиксы | Статус | Документ |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **PCalc** | `com.pcalc.mobile` | 3.7.5 | CocoaTouch / C | CoreGraphics / System | Keychain -34018, AMFI, Window Close | In-memory Keychain, Catalyst retag, Window Close exit | **Verified** | [pcalc.md](file:///Users/superuser/Downloads/Новая%20папка%2010/ipa2mac/docs/knowledge_base/pcalc.md) |
| **JAVser** | `com.guro.javser` | 1.0.0 | Compose Multiplatform (Kotlin/Native) | Skiko Metal / AVFoundation | Missing Symbol `BGContinuedProcessingTaskRequest`, AVPlayer freeze | BGClasses stub, gated audio session, pass-through dyld | **Verified** | [javser.md](file:///Users/superuser/Downloads/Новая%20папка%2010/ipa2mac/docs/knowledge_base/javser.md) |
| **Infinity Blade II** | `com.chairentertainment.IB2` | 1.3.5 | Unreal Engine 3 (Mobile) | OpenGL ES 2.0 / OpenAL | Cyrillic path crash, MPMoviePlayer missing, 0x8c340 pointer crash | Binary patch 0x8c340, `/tmp/SwordGame.app` redirect, fake MPMoviePlayer | **Verified** | [infinity_blade_2.md](file:///Users/superuser/Downloads/Новая%20папка%2010/ipa2mac/docs/knowledge_base/infinity_blade_2.md) |
| **CarX Street** | `com.carxtech.sr` | 1.24.0 | Unity 6000 (IL2CPP) | Metal / FMOD CoreAudio | Free disk check <64GB, ODR hang, Addressables bundle missing | 64GB `statfs` spoof, `NSBundleResourceRequest` bypass, Addressables bundle copy | **Verified** | [carx_street.md](file:///Users/superuser/Downloads/Новая%20папка%2010/ipa2mac/docs/knowledge_base/carx_street.md) |
| **DEVICE 6** | `com.simogo.devicesix` | 1.4 | Simogo Native ObjC | UIKit GLES / System Audio | Gameplay requires physical iPad rotation | AppKit "Rotate Device" menu bar item, orientation swizzle | **Verified** | [device_6.md](file:///Users/superuser/Downloads/Новая%20папка%2010/ipa2mac/docs/knowledge_base/device_6.md) |
| **BADLAND** | `com.frogmindgames.dodge` | 3.4.3 | Frogmind C++ / Cocos2d-x | GLES Metal / FMOD CoreAudio | Dyld deadlocks in AudioSession & fishhook, 5 FPS throttle, PAGEZERO loop | Early audio hooks, fishhook suppress, audio unthrottle, PAGEZERO guard | **Verified** | [badland.md](file:///Users/superuser/Downloads/Новая%20папка%2010/ipa2mac/docs/knowledge_base/badland.md) |
| **LIMBO** | `com.playdeadgames.limbo.ios` | 1.1.28 | Playdead Custom C++ | Custom Metal / FMOD CoreAudio | Unknown `hw.machine`, Game Center modal "Loading..." freeze | `iPad8,1` sysctl spoof with dladdr check, GKLocalPlayer auto-auth | **Verified** | [limbo.md](file:///Users/superuser/Downloads/Новая%20папка%2010/ipa2mac/docs/knowledge_base/limbo.md) |
| **Cut the Rope** | `com.zeptolab.cuttherope` | 2.7.1 | ZeptoLab Native C++ | Legacy GLES 2.0 / OpenAL | WindowServer 515pt clamp, touch cursor coordinate mismatch | 2-level CALayerHost aspect-fit, `UITouch locationInView:` remap matrix | **Verified** | [cut_the_rope.md](file:///Users/superuser/Downloads/Новая%20папка%2010/ipa2mac/docs/knowledge_base/cut_the_rope.md) |
| **Alto's Adventure** | `com.snowman.alto` | 1.6.2 | Unity 5.1.4f1 | Metal / Unity CoreAudio | `NSUbiquitousKeyValueStore` assertion crash, mouse-up premature close | `MockUbiquitousStore` dictionary, mouse-up close guard | **Verified** | [altos_adventure.md](file:///Users/superuser/Downloads/Новая%20папка%2010/ipa2mac/docs/knowledge_base/altos_adventure.md) |
| **GoodReader Pro** | `com.goodiware.grpro` | 5.6.1119 | Native ObjC / C++ | UIKit PDFKit / CoreAudio | Sandbox path crash on license accept, phone UI distortion | `CFFIXED_USER_HOME` to `~/Documents`, `UIUserInterfaceIdiomPad` (1) | **Verified** | [goodreader_pro.md](file:///Users/superuser/Downloads/Новая%20папка%2010/ipa2mac/docs/knowledge_base/goodreader_pro.md) |
| **EcoFlow** | `com.ef.EcoFlow` | 6.11.0 | Native Swift / React Native | UIKit Metal / System Audio | Distorted phone cards, `UIScreen bounds` full screen 1440x900 | Forced `UIUserInterfaceIdiomPad` (1), clamped `UIScreen bounds` 3:4 | **Verified** | [ecoflow.md](file:///Users/superuser/Downloads/Новая%20папка%2010/ipa2mac/docs/knowledge_base/ecoflow.md) |
| **VLC for Mobile** | `org.videolan.vlc-ios` | 3.0.2 | Swift / LibVLC C Engine | UIKit Metal / CoreAudio | Nested frameworks (`MobileVLCKit`, `MediaLibraryKit`) platform mismatch | Recursive `vtool` patch, bottom-up codesign, network entitlements | **Verified** | [vlc.md](file:///Users/superuser/Downloads/Новая%20папка%2010/ipa2mac/docs/knowledge_base/vlc.md) |
| **Monument Valley** | `com.ustwo.monumentvalley` | 2.10.2 | Unity 2020 (IL2CPP) | Metal / Unity CoreAudio | `UnityFramework.framework` platform mismatch, IL2CPP KVS dictionary selector | Multi-binary `vtool`, `NSUbiquitousKeyValueStore dictionaryRepresentation` | **Verified** | [monument_valley.md](file:///Users/superuser/Downloads/Новая%20папка%2010/ipa2mac/docs/knowledge_base/monument_valley.md) |
| **GTA Vice City** | `com.rockstargames.gta3vc` | 1.5.1 | War Drum / RenderWare | Legacy GLES / OpenAL 3D | Legacy AudioQueue, save game permissions in sandbox | Catalyst retag, in-memory keychain, `CFFIXED_USER_HOME` save sync | **Verified** | [gta_vice_city.md](file:///Users/superuser/Downloads/Новая%20папка%2010/ipa2mac/docs/knowledge_base/gta_vice_city.md) |
| **Plants vs. Zombies HD**| `com.popcap.PvZiPad` | 1.9.12 | PopCap SexyAppFramework | Legacy GLES 2.0 / OpenAL | Arbitrary window resize ruins 4:3 1024x768 lawn grid collision | Fixed 4:3 1024x768 canvas, aspect-fit scaling, user save redirect | **Verified** | [plants_vs_zombies_hd.md](file:///Users/superuser/Downloads/Новая%20папка%2010/ipa2mac/docs/knowledge_base/plants_vs_zombies_hd.md) |

---

## 2. Таксономия платформенных сбоев и паттерны решений (Lessons Learned)

В процессе исследования сотен гигабайт дампов, системных логов и сотен шагов транскрипта была сформирована фундаментальная классификация проблем переноса iOS на macOS.

### Паттерн 1: Multi-Binary Bundles & Dynamic Frameworks
- **Симптом**: `dyld: Library not loaded: ... Reason: mach-o, but wrong platform (expected 6, got 2)`.
- **Причина**: Современные движки (Unity 2019+, VLC, Unreal) выносят исполняемый код во вложенные фреймворки в `Payload/App.app/Frameworks/`. Конвертация одного лишь корневого бинарника приводит к отказу загрузчика dyld при компоновке зависимостей.
- **Решение**: Рекурсивный обход всего дерева файлов бандла в `patch_app.sh`, выявление Mach-O через `file`, thinning до `arm64` через `lipo`, и применение `vtool -set-build-version maccatalyst 14.0 14.0 -replace` к каждому найденному объекту с последующей подписью «снизу вверх».

### Паттерн 2: Дедлоки инициализаторов dyld & Fishhook
- **Симптом**: Процесс запускается, потребляет 0% CPU, окно не создается, стек потока 0 застревает в `__psynch_mutexwait` внутри `_dyld_register_func_for_add_image`.
- **Причина**: Встроенные SDK (Everyplay, Facebook SDK) используют `fishhook` в конструкторах `__attribute__((constructor))`. Запрос образов блокирует мьютекс dyld, конфликтуя с ранней инициализацией `libdispatch`.
- **Решение**: Интерпозиция `_dyld_register_func_for_add_image` в `mod_dyld_fishhook.c` в виде no-op заглушки (активируется флагом `dyld_fishhook_suppress = true`).

### Паттерн 3: Аудиотракт — Legacy Deadlocks vs. Modern AVPlayer Clock Sync
- **Симптом A**: Старые игры (BADLAND) висят на Mach IPC к `mediaserverd` из конструкторов.
- **Симптом B**: Новые плееры (JAVser) при глобальном стабе `AVAudioSession` зависают на нулевой секунде видео, так как `CoreMedia` не может синхронизировать мастер-таймлайн без валидного ID сессии.
- **Решение**: Рецептурная изоляция. Хуки подмены `AVAudioSession` (`opaqueSessionID = 10001`, `sampleRate = 44100`) включаются строго через флаг `audio_session_fix = true` в `recipe.ini`. Нативные мультимедийные приложения работают с нетронутым системным `AVAudioSession`.

### Паттерн 4: Песочница, пути с пробелами и кодировка путей (Cyrillic Paths)
- **Симптом**: Падения при обращении к файлам, `Assertion failed: [File:UnFile.cpp]`, невозможность сохранить настройки.
- **Причина A**: Игры образца 2011 года (UE3 / Infinity Blade II) оперируют строками в фиксированных ASCII-буферах и ломаются на путях с кириллицей (`/Users/.../Новая папка 10/...`).
- **Причина B**: Отсутствие контейнера App Sandbox приводит к попыткам записи в системный корень пользователя.
- **Решение**: 
  1. Создание ASCII-симлинка `/tmp/SwordGame.app` и перехват `[NSBundle bundlePath/resourcePath]`.
  2. Переопределение переменной окружения `CFFIXED_USER_HOME` на каталог `~/Documents`.

### Паттерн 5: Недостающие системные символы iOS SDK
- **Симптом**: `dyld: Symbol not found: _OBJC_CLASS_$_BGContinuedProcessingTaskRequest`.
- **Причина**: Приложения под iOS 16/17 используют новые интерфейсы фреймворка `BackgroundTasks`, отсутствовавшие в macOS Catalyst 14.0.
- **Решение**: Объявление стабов классов в Objective-C (`mod_bg_classes.m`) и выборочное перенаправление фреймворка через `install_name_tool` без загрязнения глобального пространства имен.

### Паттерн 6: Необработанные ассерты iCloud KVS (`NSUbiquitousKeyValueStore`)
- **Симптом**: `BUG IN CLIENT OF KVS: NSUbiquitousKeyValueStore initialized without entitlement` или `-[NSUbiquitousKeyValueStore dictionaryRepresentation]: unrecognized selector`.
- **Причина**: Жесткое требование платной подписи разработчика Apple для облачных сохранений.
- **Решение**: Полнофункциональный in-memory мок `mod_ubiquitous.m` на базе `CFMutableDictionaryRef`, реализующий селекторы `defaultStore`, `objectForKey:`, `setObject:forKey:`, `dictionaryRepresentation`, `synchronize`.

### Паттерн 7: Спуфинг оборудования и фильтрация вызывающего (`dladdr`)
- **Симптом**: Игры определяют хост как `Mac14,2` и вылетают с ошибкой профиля, либо грузят текстуры ультра-низкого качества.
- **Решение**: Перехват `sysctlbyname("hw.machine")` и `uname()` с возвратом `"iPad8,1"` или `"iPad13,8"`. Использование проверки адреса возврата `__builtin_return_address(0)` через `dladdr`, чтобы вызовы ядра от самого `libdyld` получали реальные данные процессора хоста.

### Паттерн 8: Ограничения WindowServer (515 pt) и матричный пересчет координат
- **Симптом**: Телефонные окна (320x480) искажаются из-за минимальной ширины 515 пунктов в macOS, клики мыши не попадают по элементам управления.
- **Решение**: Контейнерное окно 2:3 (360x540), центрирование слоя `CALayerHost`/`CAEAGLLayer` и интерпозиция `-[UITouch locationInView:]` с применением обратной матрицы масштабирования.

### Паттерн 9: Защита нулевой страницы ядра (`PAGEZERO`) в обработчиках памяти
- **Симптом**: 100% загрузка процессора и мертвое зависание при любом разыменовании `NULL`.
- **Причина**: Попытка вызвать `mprotect(0, 0x4000, ...)` на защищенной странице ядра Darwin.
- **Решение**: Проверка адреса сбоя: если `addr < 0x4000`, немедленный сброс обработчика сигнала в `SIG_DFL` и передача исключения в стандартный crash reporter.

---

## 3. Архитектура модульного движка (`engine/modules/`)

В релизе `dd467df` была проведена полная декомпозиция монолитного `shim.m` (1100 строк) на узкоспециализированные независимые модули, компилируемые JIT под требования каждого конкретного приложения:

```text
ipa2mac/engine/modules/
├── core_keychain.c           # Потокобезопасная in-memory связка ключей (SecItem*)
├── mod_device_spoof.c        # Спуфинг модели iPad Pro (sysctl, uname) с dladdr-фильтром
├── mod_statfs.c              # Фальсификация 64 ГБ свободного места на диске
├── mod_window.m              # AppKit оконные стили, aspect-fit, regular activation policy
├── mod_window_close.m        # Чистое завершение процесса [NSApp terminate:] на крестик
├── mod_odr_bypass.m          # Байпас загрузки On-Demand Resources (CarX Street)
├── mod_ue3.m                 # Комплексный модуль адаптации движка Unreal Engine 3
├── mod_ascii_path_redirect.m # Симлинк /tmp/SwordGame.app для путей с кириллицей
├── mod_fake_mpmovieplayer.m  # Эмуляция устаревшего MPMoviePlayerController
├── mod_av_delegate.m         # Нейтрализация сбойного [AVAudioSession setDelegate:]
├── mod_d6_rotation.m         # Меню поворота экрана в MenuBar для DEVICE 6
├── mod_audio_legacy.m        # Ранний перехват старых аудиосессий (BADLAND)
├── mod_bg_classes.m          # Стабы отсутствующих классов BackgroundTasks (JAVser)
├── mod_bg_scheduler.m        # Стабы планировщика BGTaskScheduler
├── mod_dyld_fishhook.c       # Подавление дедлоков dynamic symbol rebinding
├── mod_fault_handler.c       # Обработка исключений памяти с защитой PAGEZERO
├── mod_signal_suppress.c     # Подавление падений на sigaction
├── mod_vm_protect.c          # Гарантия прав RWX на страницы mmap
├── mod_ubiquitous.m          # In-memory эмуляция iCloud NSUbiquitousKeyValueStore
├── mod_gamecenter.m          # Авто-завершение аутентификации GKLocalPlayer (LIMBO)
├── mod_touch_remap.m         # Пересчет координат тача для масштабированных слоев
└── mod_assert_suppress.c     # Перехват __assert_rtn с завершением потока вместо abort
```

---

## 4. Алгоритм подготовки любого нового приложения (Field Protocol)

1. **Распаковка IPA**:
   `unzip Target.ipa -d /tmp/target_work`
2. **Проверка архитектуры**:
   `lipo -archs /tmp/target_work/Payload/*.app/<Executable>` (обязательно наличие `arm64`).
3. **Проверка шифрования**:
   `otool -l <Executable> | grep -A 4 LC_ENCRYPTION_INFO_64` (параметр `cryptid` должен быть `0`).
4. **Формирование рецепта**:
   Создать `recipes/<bundle_id>.ini` с указанием параметров окна и флагов необходимых шимов.
5. **Запуск конвертера**:
   `./engine/patch_app.sh /tmp/target_work/Payload/*.app`
6. **Запуск приложения**:
   `./<Target>.app/<Executable>` или через двойной клик в Finder.
