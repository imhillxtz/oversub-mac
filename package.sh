#!/bin/zsh
# Đóng gói OverSub thành file .dmg để chia sẻ: mở ra, kéo OverSub vào Applications.
# Bản chia sẻ không kèm công cụ tự kiểm tra (không đặt OVERSUB_DEV).
set -e
cd "$(dirname "$0")"
unset OVERSUB_DEV
# Mỗi lần đóng gói tăng số phiên bản để biết đang cầm bản nào: mặc định tăng số cuối (1.1.0 → 1.1.1),
# hoặc chỉ định: ./package.sh 1.2.0
PB=/usr/libexec/PlistBuddy
OLD=$($PB -c "Print :CFBundleShortVersionString" Info.plist)
if [[ -n "$1" ]]; then VERSION="$1"; else VERSION="${OLD%.*}.$(( ${OLD##*.} + 1 ))"; fi
BUILD=$(( $($PB -c "Print :CFBundleVersion" Info.plist) + 1 ))
$PB -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" Info.plist
./build.sh
STAGE=$(mktemp -d)
cp -R OverSub.app "$STAGE/OverSub.app"
ln -s /Applications "$STAGE/Applications"
cp "Docs/Đọc trước - Read me first.txt" "$STAGE/"
mkdir -p dist
DMG="dist/OverSub-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "OverSub $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Xong: $PWD/$DMG"
