#!/bin/zsh
# Dựng OverSub.app bằng SwiftPM (Command Line Tools là đủ; có Xcode thì icon có hiệu ứng kính).
set -e
cd "$(dirname "$0")"
# OVERSUB_DEV=1 ./build.sh: kèm công cụ tự kiểm tra (chụp giao diện, cảnh thử). Bản chia sẻ thì không kèm.
FLAGS=()
[[ -n "$OVERSUB_DEV" ]] && FLAGS=(-Xswiftc -DDEVTOOLS)
swift build -c release $FLAGS
# OVERSUB_BETA=1 ./build.sh: dựng "OverSub Beta.app" với mã định danh riêng, cài song song với bản chính
# (cài đặt, dữ liệu, nhật ký, quyền Ghi màn hình đều tách riêng; không tự cập nhật). Info.plist trong kho không đổi.
BUNDLE_ID=vn.imhillxtz.phude
APP=OverSub.app
if [[ -n "$OVERSUB_BETA" ]]; then BUNDLE_ID=$BUNDLE_ID.beta; APP="OverSub Beta.app"; fi
rm -rf "$APP" PhuDeDich.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release $FLAGS --show-bin-path)/OverSub" "$APP/Contents/MacOS/OverSub"
cp Info.plist "$APP/Contents/Info.plist"
if [[ -n "$OVERSUB_BETA" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" -c "Set :CFBundleName OverSub Beta" \
    -c "Set :CFBundleDisplayName OverSub Beta" "$APP/Contents/Info.plist"
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Ove: các tấm khung hình dựng sẵn (Tools/Ove tạo ra) và bảng mô tả của chúng.
cp -R Resources/Ove "$APP/Contents/Resources/Ove"
# Thông báo bản quyền của FSR 1, Anime4K (giấy phép MIT yêu cầu kèm theo bản phát hành).
cp Docs/THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
# Icon kính (Liquid Glass) tự đổi sáng/tối: biên dịch Resources/AppIcon.icon bằng actool của Xcode.
# Máy chỉ có Command Line Tools thì dùng AppIcon.icns phẳng ở trên.
XCODE_DEV=/Applications/Xcode.app/Contents/Developer
if [[ -d "$XCODE_DEV" ]]; then
  DEVELOPER_DIR="$XCODE_DEV" xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" \
    --platform macosx --minimum-deployment-target 26.0 --app-icon AppIcon \
    --output-partial-info-plist "$APP/icon-partial.plist" >/dev/null
  rm -f "$APP/icon-partial.plist"
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
  echo "Không thấy Xcode: dùng icon phẳng (không có hiệu ứng kính)."
fi
# Yêu cầu định danh cố định theo bundle id để macOS không coi mỗi lần build là một app mới (mất quyền Ghi màn hình).
codesign --force --deep --sign - -r="designated => identifier \"$BUNDLE_ID\"" "$APP"
echo "Xong: $PWD/$APP"
