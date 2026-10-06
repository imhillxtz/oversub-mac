#!/bin/zsh
# Đóng OverSub.app thành .dmg có cửa sổ cài đặt đẹp: hình nền (Tools/dmg_background.swift), icon OverSub bên trái,
# thư mục Applications bên phải, icon ổ đĩa là icon app. Dùng: Tools/make_dmg.sh <phiên bản> <ra.dmg>
# Bước sắp xếp cửa sổ điều khiển Finder bằng AppleScript: lần đầu macOS hỏi quyền "điều khiển Finder"; không có quyền
# thì vẫn ra .dmg dùng được, chỉ là cửa sổ không có hình nền.
set -e
cd "$(dirname "$0")/.."
VERSION="$1"; OUT="$2"
VOL="OverSub $VERSION"
# Đang có ổ trùng tên thì macOS gắn bản mới thành "… 1" và hình nền trỏ sai ổ: dừng lại để tháo ổ cũ trước.
if [[ -d "/Volumes/$VOL" ]]; then
  echo "Đang mở ổ \"$VOL\": tháo (Eject) ổ đó rồi chạy lại."
  exit 1
fi
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
cp -R OverSub.app "$STAGE/OverSub.app"
ln -s /Applications "$STAGE/Applications"
# Hình nền @1x + @2x gộp một file TIFF cho màn hình Retina; script in ra toạ độ tâm hai icon.
read LX RX IY <<< "$(swift Tools/dmg_background.swift "$WORK/bg.png" "$WORK/bg@2x.png")"
tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$STAGE/.background/background.tiff" >/dev/null 2>&1

RW="$WORK/rw.dmg"
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW" >/dev/null
MNT=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk -F'\t' '/\/Volumes\//{print $NF}')
DISK=$(basename "$MNT")
# Ẩn thư mục hình nền kể cả khi người dùng bật hiện tệp ẩn.
xcrun SetFile -a V "$MNT/.background" 2>/dev/null || true

# Cửa sổ 660×400 (thêm thanh tiêu đề), icon 128, đặt hai icon đúng chỗ trên hình nền.
if osascript >/dev/null <<EOF
tell application "Finder"
  tell disk "$DISK"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 548}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set position of item "OverSub.app" of container window to {$LX, $IY}
    set position of item "Applications" of container window to {$RX, $IY}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF
then
  echo "Đã sắp xếp cửa sổ cài đặt."
else
  echo "Không điều khiển được Finder (chưa cho phép?): .dmg vẫn dùng được nhưng không có hình nền."
fi

# Icon ổ đĩa đặt SAU bước Finder: Finder sắp xếp cửa sổ xong thì xoá .VolumeIcon.icns và tắt cờ icon riêng của ổ
# (hdiutil cũng bỏ qua tệp này nếu để sẵn trong thư mục nguồn).
cp Resources/AppIcon.icns "$MNT/.VolumeIcon.icns"
xcrun SetFile -a V "$MNT/.VolumeIcon.icns" 2>/dev/null || true
xcrun SetFile -a C "$MNT" 2>/dev/null || true
rm -rf "$MNT/.fseventsd"
chmod -Rf go-w "$MNT" 2>/dev/null || true
sync
hdiutil detach "$MNT" -quiet || { sleep 2; hdiutil detach "$MNT" -force -quiet; }
rm -f "$OUT"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
echo "Đã tạo: $OUT"
