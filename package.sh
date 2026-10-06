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
mkdir -p dist
DMG="dist/OverSub-$VERSION.dmg"
# Cửa sổ cài đặt: hình nền có hướng dẫn kéo vào Applications và cách mở lần đầu (thay cho file "Đọc trước" cũ).
Tools/make_dmg.sh "$VERSION" "$DMG" 2> >(grep -v "is deprecated" >&2)
# Ký file cài để app tự cập nhật nhận ra bản chính chủ (khoá bí mật chỉ nằm trên máy tác giả, ngoài kho mã).
SIGNER=$(mktemp -d)/sign_update
if swiftc -O -o "$SIGNER" Tools/sign_update.swift 2>/dev/null && "$SIGNER" "$DMG" > "$DMG.sig"; then
  echo "Đã ký: $PWD/$DMG.sig"
else
  rm -f "$DMG.sig"; echo "Chưa ký được (thiếu khoá ký?): bản này không tự cập nhật được, chỉ cài tay."
fi
rm -rf "$(dirname "$SIGNER")"
echo "Xong: $PWD/$DMG"
