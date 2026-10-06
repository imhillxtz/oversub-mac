#!/bin/zsh
# Xuất lại Resources/AppIcon.icns (bản dự phòng) và Resources/icon_preview.png từ Resources/AppIcon.icon.
# Cần Xcode 26 trở lên (Icon Composer). Icon kính thật do build.sh biên dịch thẳng từ .icon bằng actool.
set -e
cd "$(dirname "$0")/.."
IC="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
TMP=$(mktemp -d)
"$IC" Resources/AppIcon.icon --export-image --output-file "$TMP/full.png" --platform macOS --rendition Default --width 1024 --height 1024 --scale 1 >/dev/null
swift Tools/pad_icon.swift "$TMP/full.png" "$TMP/padded.png"
mkdir "$TMP/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/padded.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$TMP/padded.png" --out "$TMP/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
sips -z 512 512 "$TMP/padded.png" --out Resources/icon_preview.png >/dev/null
rm -rf "$TMP"
echo "Xong: Resources/AppIcon.icns, Resources/icon_preview.png"
