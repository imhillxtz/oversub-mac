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
  # Biên dịch ra thư mục tạm rồi chép vào: actool có lúc không ghi được vào thư mục trong Documents ("Operation not permitted")
  # và hay vấp khi một actool khác đang chạy (13/10/2026). Thử ba lần; vẫn hỏng thì dùng icon phẳng, không dừng bản dựng.
  ICON_TMP=$(mktemp -d)
  for try in 1 2 3; do
    DEVELOPER_DIR="$XCODE_DEV" xcrun actool "$PWD/Resources/AppIcon.icon" --compile "$ICON_TMP" \
      --platform macosx --minimum-deployment-target 26.0 --app-icon AppIcon \
      --output-partial-info-plist "$ICON_TMP/icon-partial.plist" >/dev/null 2>&1 || true
    [[ -f "$ICON_TMP/Assets.car" ]] && break
    sleep 3
  done
  if [[ -f "$ICON_TMP/Assets.car" ]]; then cp "$ICON_TMP/Assets.car" "$APP/Contents/Resources/Assets.car"
  else echo "actool không dựng được icon kính: dùng icon phẳng."; fi
  rm -rf "$ICON_TMP"
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
  echo "Không thấy Xcode: dùng icon phẳng (không có hiệu ứng kính)."
fi
# Yêu cầu định danh cố định theo bundle id để macOS không coi mỗi lần build là một app mới (mất quyền Ghi màn hình).
codesign --force --deep --sign - -r="designated => identifier \"$BUNDLE_ID\"" "$APP"
echo "Xong: $PWD/$APP"
