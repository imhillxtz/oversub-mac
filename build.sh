#!/bin/zsh
# Dựng OverSub.app mà không cần Xcode (chỉ cần Command Line Tools).
set -e
cd "$(dirname "$0")"
# OVERSUB_DEV=1 ./build.sh: kèm công cụ tự kiểm tra (chụp giao diện, cảnh thử). Bản chia sẻ thì không kèm.
FLAGS=()
[[ -n "$OVERSUB_DEV" ]] && FLAGS=(-Xswiftc -DDEVTOOLS)
swift build -c release $FLAGS
APP=OverSub.app
rm -rf "$APP" PhuDeDich.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release $FLAGS --show-bin-path)/OverSub" "$APP/Contents/MacOS/OverSub"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Yêu cầu định danh cố định theo bundle id để macOS không coi mỗi lần build là một app mới (mất quyền Ghi màn hình).
codesign --force --deep --sign - -r='designated => identifier "vn.imhillxtz.phude"' "$APP"
echo "Xong: $PWD/$APP"
