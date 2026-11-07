#!/bin/zsh
# Собирает Tempo.app и кладёт его в /Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/Tempo.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Tempo "$APP/Contents/MacOS/Tempo"
cp Resources/Info.plist "$APP/Contents/Info.plist"

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

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Tempo 2>/dev/null || true
  while pgrep -x Tempo >/dev/null; do sleep 0.2; done
  rm -rf /Applications/Tempo.app
  ditto "$APP" /Applications/Tempo.app
  open /Applications/Tempo.app
  echo "Установлено: /Applications/Tempo.app"
else
  echo "Готово: $(pwd)/$APP"
fi
