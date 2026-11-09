#!/bin/zsh
# Собирает Hourfox.app и кладёт его в /Applications.
set -euo pipefail
cd "$(dirname "$0")"

# --universal: одно приложение для Apple Silicon и Intel, для выкладки. Обычная сборка быстрее.
swift build -c release

APP=build/Hourfox.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
if [[ "${1:-}" == "--universal" ]]; then
  swift build -c release --arch x86_64 --scratch-path .build-x86
  lipo -create .build/release/Hourfox .build-x86/x86_64-apple-macosx/release/Hourfox -output "$APP/Contents/MacOS/Hourfox"
else
  cp .build/release/Hourfox "$APP/Contents/MacOS/Hourfox"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Номер версии один на всё: файл VERSION. По нему приложение узнаёт, что вышла новая.
VERSION=$(cat VERSION)
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

if [[ ! -f Resources/AppIcon.icns ]]; then
  ICONSET=build/AppIcon.iconset
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  swift Scripts/make_icon.swift build/icon_1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cp Resources/heroicons-LICENSE.txt "$APP/Contents/Resources/"
# Ключи Google в репозитории нет: без файла приложение собирается без Google Календаря.
if [[ -f Resources/GoogleOAuth.plist ]]; then
  cp Resources/GoogleOAuth.plist "$APP/Contents/Resources/GoogleOAuth.plist"
fi

codesign --force --deep --sign - "$APP"

# --universal заодно собирает для сайта два архива: отдельно Apple Silicon и Intel.
if [[ "${1:-}" == "--universal" ]]; then
  for pair in arm64:Apple x86_64:Intel; do
    arch=${pair%%:*}; name=${pair##*:}
    THIN=build/thin-$name/Hourfox.app
    rm -rf "build/thin-$name"; mkdir -p "build/thin-$name"
    ditto "$APP" "$THIN"
    lipo "$APP/Contents/MacOS/Hourfox" -thin "$arch" -output "$THIN/Contents/MacOS/Hourfox"
    codesign --force --deep --sign - "$THIN"
    rm -f "docs/Hourfox-$name.zip"
    ditto -c -k --norsrc --keepParent "$THIN" "docs/Hourfox-$name.zip"
  done
  # Файл, который приложение раз в день читает на сайте.
  printf '{\n  "version": "%s",\n  "apple": "https://hourfox.app/Hourfox-Apple.zip",\n  "intel": "https://hourfox.app/Hourfox-Intel.zip"\n}\n' "$VERSION" > docs/version.json
fi

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Hourfox 2>/dev/null || true
  while pgrep -x Hourfox >/dev/null; do sleep 0.2; done
  rm -rf /Applications/Hourfox.app
  ditto "$APP" /Applications/Hourfox.app
  open /Applications/Hourfox.app
  echo "Установлено: /Applications/Hourfox.app"
else
  echo "Готово: $(pwd)/$APP"
fi
