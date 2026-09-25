# Doomsaday

Manage Docker on remote servers through the agent REST API. Android, iOS and
macOS, one adaptive layout from a 390 px phone to a desktop window.

## Two editions, one app

The app ships as two flavors of the same code, `free` and `pro`:

| | `free` | `pro` |
|---|---|---|
| Name | Doomsaday | Doomsaday Pro |
| Android application id | `dev.doomsaday.doomsaday` | `dev.doomsaday.doomsaday.pro` |
| iOS/macOS bundle id | `dev.doomsaday.doomsaday` | `dev.doomsaday.doomsaday.pro` |
| Paired servers | 2 | unlimited |
| All servers, log wall, cross-server Cmd+K | locked, with the PRO panel | yes |

Free keeps the original identifier, so an existing install keeps its data, and
the two install side by side.

`lib/edition/edition.dart` is the only file that knows a flavor exists. It
resolves the edition at compile time from Flutter's `appFlavor`, with
`--dart-define=EDITION=pro` as the override for a run or a test with no flavor,
and everything else asks it for a capability rather than for the flavor.

## Run

    flutter run --flavor free           # Android, iOS, macOS
    flutter run --flavor pro

    # No flavor to hand — a plain `flutter run -d macos` and the like:
    flutter run -d macos --dart-define=EDITION=pro

Every run and build now needs a flavor: Gradle has no flavorless variant left,
and the Xcode projects define the `free` and `pro` schemes, which the Flutter
tool refuses to choose between on its own.

## Build

    flutter build apk   --debug --flavor free
    flutter build apk   --debug --flavor pro
    flutter build macos --debug --flavor free
    flutter build macos --debug --flavor pro
    flutter build ios   --debug --no-codesign --flavor free
    flutter build ios   --debug --no-codesign --flavor pro

`--release` takes the same options. The artifacts land in
`build/app/outputs/flutter-apk/app-<flavor>-debug.apk` and
`build/macos/Build/Products/Debug-<flavor>/`.

## Test

    flutter test

The suite runs as the Pro edition, which is the one that has every screen. That
is set in `test/app_harness.dart`, and a test that wants the other edition passes
`edition: Edition.free` to `pumpApp`.

## Where the flavors live

* **Android** — `android/app/build.gradle.kts`: one `edition` dimension with the
  `free` and `pro` product flavors, the label through `resValue("string",
  "app_name", …)`, and `applicationIdSuffix = ".pro"`. Per-flavor icons are
  resources under `android/app/src/<flavor>/res`.
* **iOS and macOS** — `tool/xcode_flavors.rb` owns both Xcode projects. It is
  idempotent; rerun it after anything regenerates them:

      ruby tool/xcode_flavors.rb

  It writes the `Debug-<flavor>`, `Profile-<flavor>` and `Release-<flavor>`
  configurations, an xcconfig per configuration next to the one it copies (so
  CocoaPods' per-configuration file is the one included), the bundle identifier,
  display name and app icon per configuration, and the shared `free` and `pro`
  schemes. The Podfiles map all nine configurations to `:debug` or `:release`,
  so run `pod install` in `ios/` and `macos/` after it.
* **Everything else about an edition** — `lib/edition/`.

## Icons

    python3 tool/generate_icon.py     # the artwork, both editions
    dart run flutter_launcher_icons   # cuts Android and iOS from it
    ruby tool/xcode_flavors.rb        # puts the icon names back, see below

`tool/generate_icon.py` draws the same mark in both colourways — Free is mint
`#5BE3B0` on `#0E1417`, Pro is ivory `#FAF3E8` on deep red `#9E1B1B` — and
writes `assets/icon/<edition>/app_icon.png`, the adaptive foreground beside it,
and the macOS `AppIcon-<edition>.appiconset`s directly, because
flutter_launcher_icons' macOS generator ignores flavors and would write both
editions over one icon set.

`dart run flutter_launcher_icons` reads `flutter_launcher_icons-free.yaml` and
`flutter_launcher_icons-pro.yaml` on its own. It also rewrites the iOS project's
`ASSETCATALOG_*` settings with a blunt regex, which can catch neighbouring
settings, so rerun `ruby tool/xcode_flavors.rb` afterwards and check the diff of
`ios/Runner.xcodeproj/project.pbxproj`.
