#!/bin/bash
# Builds a release .app for each macOS flavor and wraps it in a .dmg.
#
#   tool/build_dmg.sh            both flavors, locally signed
#   tool/build_dmg.sh pro        one flavor
#   SIGNED=1 tool/build_dmg.sh   use Release.entitlements (needs DEVELOPMENT_TEAM
#                                set in macos/Runner/Configs/AppInfo.xcconfig)
#
# Without SIGNED=1 the build uses Runner/ReleaseLocal.entitlements, which has
# no keychain access group: the app runs, but it cannot store a device key, so
# pairing a real agent stops with "secure storage unavailable". Demo mode works.
#
# ARCHS: Flutter 3.38 verifies a universal build with `lipo -verify_arch arm64
# x86_64`, which Xcode 27's lipo rejects, so a universal release build fails.
# Until that is fixed upstream the build targets one architecture, Apple
# Silicon by default. For Intel Macs: MAC_ARCH=x86_64 tool/build_dmg.sh
set -euo pipefail
export FLUTTER_XCODE_ARCHS="${MAC_ARCH:-arm64}"
export FLUTTER_XCODE_ONLY_ACTIVE_ARCH="NO"

cd "$(dirname "$0")/.."
version=$(grep -E '^version:' pubspec.yaml | sed -E 's/version: *([^+]+).*/\1/')
out="../dist"
mkdir -p "$out"

flavors=("$@")
[ ${#flavors[@]} -eq 0 ] && flavors=(free pro)

for flavor in "${flavors[@]}"; do
  case "$flavor" in
    free) app_name="Doomsaday" ;;
    pro) app_name="Doomsaday Pro" ;;
    *) echo "unknown flavor: $flavor" >&2; exit 2 ;;
  esac

  if [ "${SIGNED:-0}" = "1" ]; then
    flutter build macos --release --flavor "$flavor"
  else
    FLUTTER_XCODE_CODE_SIGN_ENTITLEMENTS="Runner/ReleaseLocal.entitlements" \
      flutter build macos --release --flavor "$flavor"
  fi

  app="build/macos/Build/Products/Release-$flavor/$app_name.app"
  [ -d "$app" ] || { echo "missing $app" >&2; exit 1; }

  stage=$(mktemp -d)
  cp -R "$app" "$stage/"
  ln -s /Applications "$stage/Applications"

  dmg="$out/${app_name// /-}-$version-$FLUTTER_XCODE_ARCHS.dmg"
  rm -f "$dmg"
  hdiutil create -volname "$app_name $version" -srcfolder "$stage" \
    -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$dmg" >/dev/null
  rm -rf "$stage"
  echo "built $dmg"
done
