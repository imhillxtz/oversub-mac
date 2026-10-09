# OverSub: ghi chú phát triển

Tài liệu này dành cho tác giả và người được tác giả cho phép làm việc trên mã nguồn. Nó ghi cách dựng, cách tự kiểm tra, cơ chế bên trong và những điều đã đo được trong lúc làm, kèm lý do của từng lựa chọn. Hướng dẫn sử dụng nằm ở [README](../README.md).

OverSub là app macOS (cần macOS 26 trở lên) dịch và đọc phụ đề game ngay trên màn hình. App chụp vùng phụ đề, đọc chữ bằng Vision trên máy, dịch bằng dịch vụ người dùng chọn, hiện bản dịch đè lên phụ đề gốc và đọc to bằng giọng Siri. Ngoài lời thoại, app dịch tại chỗ chữ giao diện game (Dịch màn hình) và dịch một vùng bất kỳ bằng phím tắt (Dịch nhanh).

App dịch sang 12 ngôn ngữ: tiếng Việt (mặc định), English, 简体中文, 日本語, 한국어, ไทย, Bahasa Indonesia, Español, Français, Deutsch, Português (BR), Русский. Tiếng Việt có bộ lời nhắc riêng về xưng hô và văn phong; các ngôn ngữ khác dùng chung bộ lời nhắc tiếng Anh.

## Dựng và đóng gói

```sh
./build.sh && open OverSub.app      # bản thường
OVERSUB_DEV=1 ./build.sh            # kèm công cụ tự kiểm tra (DebugSnapshot)
./package.sh                        # tăng phiên bản, dựng, đóng .dmg, ký → dist/
./package.sh 1.2.0                  # chỉ định phiên bản
```

SwiftPM với Command Line Tools là đủ để dựng. Nếu máy có Xcode ở `/Applications/Xcode.app`, `build.sh` dùng `actool` của Xcode để biên dịch icon kính; không có thì app dùng icon phẳng. Không đổi `xcode-select`, script tự trỏ `DEVELOPER_DIR`.

Bundle id vẫn là `vn.imhillxtz.phude`, tên từ thời app còn gọi là Phụ Đề Dịch. Giữ nguyên để người dùng cũ không mất quyền Ghi màn hình và cài đặt. App được ký tạm theo định danh cố định (`designated => identifier "vn.imhillxtz.phude"`), nên mỗi lần dựng lại macOS không coi là app mới và quyền Ghi màn hình còn nguyên.

Mỗi bản giao cho người dùng đều phải tăng số phiên bản (`package.sh` tự tăng số cuối và số build trong `Info.plist`).

### Bộ cài .dmg

`package.sh` gọi `Tools/make_dmg.sh`. Hình nền 660×400 điểm vẽ bằng `Tools/dmg_background.swift`: nền sáng có lưới mảnh, tiêu đề, mũi tên kéo thả, và hai dòng hướng dẫn mở lần đầu ("Vẫn mở") bằng hai thứ tiếng. Ảnh @1x và @2x được gộp thành một tệp TIFF. Icon ổ đĩa là icon app.

Cỡ cửa sổ và vị trí icon đặt bằng AppleScript điều khiển Finder trên ảnh đĩa đọc-ghi, sau đó mới nén. Lần đầu macOS hỏi quyền điều khiển Finder; không có quyền thì vẫn ra .dmg dùng được, chỉ thiếu hình nền. Ba điều đã gặp khi làm:

- Bước Finder xoá `.VolumeIcon.icns` và tắt cờ icon riêng của ổ, còn `hdiutil` bỏ qua tệp đó nếu để sẵn trong thư mục nguồn. Vì vậy icon ổ đĩa được chép vào sau bước Finder.
- Đang mở một ổ trùng tên ("OverSub <phiên bản>") thì macOS gắn ổ mới thành "OverSub <phiên bản> 1" và hình nền trỏ sai ổ. Script dừng và nhắc tháo ổ cũ.
- Ở chế độ tối, Finder vẫn dùng chữ tối cho tên icon trên nền sáng (đã chụp kiểm tra), nên không cần hình nền riêng cho chế độ tối.

Lúc đóng gói, Finder có thể nhảy lên trước các cửa sổ khác.

### Icon

Icon là tệp Icon Composer `Resources/AppIcon.icon`: linh vật chữ O, vòng và mắt bằng kính, má hồng loang mềm; nền cam, chế độ tối nền gần đen có quầng cam. `actool` biên dịch thành `Assets.car` (khai báo `CFBundleIconName`) và macOS tự đổi giữa sáng, tối, nhuộm màu, trong suốt. `Resources/AppIcon.icns` là bản phẳng dự phòng; sửa tệp `.icon` xong thì chạy `Tools/make_icon.sh` để xuất lại bản đó và ảnh README.

### Phát hành và tự cập nhật

`Updater.swift` hỏi `api.github.com/repos/imhillxtz/oversub-mac/releases/latest` lúc mở app (sau 8 giây, nếu lần trước đã quá 6 giờ) và mỗi 12 giờ. Bản mới hơn mà có tệp `.dmg` thì được báo ở dòng trạng thái của cửa sổ chính, ở mục Cập nhật trong Cài đặt → Chung và ở menu thanh menu.

Mỗi `.dmg` đi kèm `.dmg.sig`, là chữ ký Ed25519 (base64) của cả tệp. Khoá công khai nhúng trong `Updater.publicKey`. Khoá bí mật nằm ở `~/Library/Application Support/OverSub Release/update-signing.key` (quyền 0600), không bao giờ vào kho mã. `package.sh` tự ký bằng `Tools/sign_update.swift`. Bản phát hành thiếu `.sig` thì app không tự cài, chỉ chỉ đường tải tay. Mất khoá bí mật thì không ký được các bản sau: phải tạo khoá mới, nhúng khoá công khai mới và người dùng cài tay một lần, nên khoá cần được sao lưu.

Khi cài, một tiến trình `sh` riêng chờ app thoát, gắn `.dmg` chỉ đọc, chép `OverSub.app` mới thành `<app>.update-new`, đổi chỗ với app cũ (lỗi thì trả app cũ về), xoá tệp tạm và mở lại app nếu cần. Nhật ký ở `~/Library/Logs/OverSub/update.log`. Không ghi được vào thư mục chứa app thì app mở `.dmg` cho người dùng tự kéo.

Các bước phát hành: `./package.sh`, kiểm có `dist/OverSub-<ver>.dmg.sig`, commit, push, rồi `gh release create v<ver> dist/OverSub-<ver>.dmg dist/OverSub-<ver>.dmg.sig --notes-file …`. Ghi chú phát hành theo `Docs/RELEASE_TEMPLATE.md`. Câu chữ về giá chỉ nói "OverSub miễn phí cho mọi người", vì dự định từ bản 2.0 các tính năng mới sẽ tính phí.

Thử cập nhật mà không cần phát hành thật: `open --env OVERSUB_UPDATE_TEST=1 --env OVERSUB_UPDATE_FEED=file:///…/latest.json --env OVERSUB_UPDATE_TARGET=/…/bản-sao/OverSub.app OverSub.app`. Feed theo đúng dạng API GitHub, tài sản trỏ `file://`. Đã thử: tệp bị sửa một byte bị từ chối; tệp đúng cài xong trong khoảng 5 giây, chữ ký app mới hợp lệ, không sót tệp tạm.

## Luồng phụ đề

### Chụp và đọc chữ

`ScreenGrabber` chụp bằng ScreenCaptureKit và loại trừ cả ứng dụng OverSub thay vì liệt kê từng cửa sổ. Lớp bản dịch ẩn hiện liên tục; nếu chỉ loại trừ danh sách cửa sổ lúc chụp thì cửa sổ vừa tạo sẽ lọt vào ảnh, app đọc lại chính bản dịch của mình và chớp liên tục. Ảnh phụ đề giới hạn bề ngang khoảng 1.800 điểm ảnh cho OCR nhẹ hơn.

Mỗi nhịp, Vision đọc nhanh (khoảng 14 ms) để biết chữ có đổi không; chỉ khi khác mới đọc kỹ (khoảng 120 ms). Khung hình giống hệt nhịp trước thì bỏ qua cả bước đọc nhanh. Cỡ chữ phụ đề đè lên ước theo bề ngang dòng (`TextFit.fontSize`), lấy trung vị 9 câu gần nhất để chữ không nhảy to nhỏ.

Lần nhận chữ đầu tiên trên một máy, macOS phải dựng mô hình cho Neural Engine rồi lưu vào `~/Library/Caches/<bundle id>/com.apple.e5rt.e5bundlecache`. Đo ngày 08/10/2026: chương trình chưa từng nhận chữ mất 57 đến 62 giây cho lệnh đầu tiên, các lệnh sau khoảng 0,2 giây; thay tệp chương trình ở cùng đường dẫn (cập nhật app) thì vẫn dùng lại bộ nhớ đệm. `VisionGuard.prepare` (trong `Capture.swift`) chạy một lần nhận chữ trên ảnh dựng sẵn cho từng mức nhận chữ và ngôn ngữ ngay khi mở app, chờ tới 4 phút, rồi mới khởi động sẵn giọng Siri (hai bên cùng dùng Neural Engine). Mọi lệnh nhận chữ thật chờ bước này xong. Chuẩn bị quá 1 giây thì `PreparingNotice` hiện bảng "Đang chuẩn bị bộ nhận chữ" ở mép trên màn hình, kèm số giây đã chờ.

Vision cũng có lúc treo hẳn: lần đo thực ngày 08/10/2026, đúng lúc giọng Siri mở Neural Engine để nạp giọng, ba lệnh nhận chữ đang chạy chờ mãi ở semaphore bên trong Vision; giọng đọc cũng mất cùng lúc, và mọi lệnh sau trong tiến trình xếp hàng chờ theo. Dừng rồi Bắt đầu không gỡ được. `VisionGuard.run` chạy mọi lệnh Vision trên luồng GCD riêng, để luồng bị treo không chiếm nhóm luồng của Swift concurrency, và không chờ quá 4 giây: quá hạn thì bỏ khung đó. Lệnh vẫn chưa xong sau 12 giây (chỉ tính sau khi đã chuẩn bị xong) thì `Engine.relaunchAfterVisionStuck` dừng nhận phụ đề, hiện hộp thoại báo lỗi đếm ngược 5 giây (`RestartNotice`, có nút khởi động lại ngay, hiện trên Space đang dùng kể cả game toàn màn hình), ghi `resumeAfterRelaunch` và `visionAutoRestartAt`, rồi `relaunch` mở lại app bằng lệnh shell chờ tiến trình thoát rồi `open -g`; bản mở lại tự bấm Bắt đầu. Chỉ tự khởi động lại một lần trong 10 phút: lại treo trong khoảng đó thì hiện hộp thoại "vẫn không phản hồi" với nút Khởi động lại OverSub và Mở nhật ký. Bản 1.1.58 tới 1.1.63 chưa có bước chuẩn bị và giới hạn này: trên máy mới, khoảng một phút dựng mô hình bị coi là treo ở giây thứ 12, việc dựng bị cắt ngang và app khởi động lại mãi. Chụp màn hình cũng chỉ chờ tối đa 5 giây mỗi lần.

Quyền Ghi màn hình kiểm ở một chỗ (`ScreenPermission.granted`). Thiếu quyền khi mở app (đã qua hướng dẫn lần đầu), khi bấm Bắt đầu, chọn vùng, Dịch nhanh, hoặc khi macOS từ chối chụp, thì `PermissionGuide` hiện hướng dẫn ba bước với nút Mở Cài đặt hệ thống (mở thẳng trang Ghi màn hình) và Mở lại OverSub (macOS chỉ áp quyền mới sau khi app mở lại). Khi Cài đặt hệ thống được mở hoặc được chọn (bằng nút của hướng dẫn hay nút của hộp thoại macOS), hướng dẫn thu gọn thành thẻ nhỏ đặt cạnh cửa sổ Cài đặt (`PermissionGuide.dockOrigin`: phải, trái, dưới, không vừa thì góc dưới trái). Vị trí cửa sổ Cài đặt lấy từ `CGWindowListCopyWindowInfo`, vẫn đọc được khi chưa có quyền. Hướng dẫn ở tầng `.floating`, không ở tầng trên game, để không che hộp thoại "thoát và mở lại" của macOS.

Gửi báo lỗi (`ErrorReport`, ở Cài đặt → Chung, menu Trợ giúp và hộp thoại "vẫn không phản hồi") chép nhật ký và tệp `thong-tin-may.txt` (phiên bản app, macOS, đời máy, chip, RAM, quyền Ghi màn hình, có bộ nhớ đệm nhận chữ chưa, ngôn ngữ, cách bắt thoại, giọng đọc, dịch màn hình, 60 dòng nhật ký đáng chú ý gần nhất; không có key, thuật ngữ hay chỉ dẫn văn phong) vào một thư mục tạm, nén bằng `ditto` thành `~/Library/Logs/OverSub/OverSub-bao-loi-<thời điểm>.zip`, rồi hiện cửa sổ có tệp đó (kéo thẳng vào trang được) với hai cách gửi: mở `issues/new` trên GitHub với `title` và `body` điền sẵn (khoảng 1.300 ký tự), hoặc `mailto:` tới `ErrorReport.supportEmail` (hillx.design@gmail.com) cho người không có tài khoản GitHub. Bấm một trong hai thì cửa sổ thu thành thẻ nhỏ chỉ có tệp ở mép phải màn hình, là `NSPanel` trên mọi Space (cửa sổ thường ở lại Space cũ khi trình duyệt chạy toàn màn hình). App không tự gửi gì. Bản 1.1.65 mở thư có đính kèm qua `NSSharingService(.composeEmail)`; Mail khởi động chậm nên người dùng tưởng nút không phản hồi, đã bỏ.

Hộp thoại cập nhật (`UpdatePrompt`) mở từ menu Kiểm tra cập nhật…, "Có gì mới" ở chân cửa sổ, menu trên thanh menu, và Kiểm tra ngay ở Cài đặt khi có bản mới; lần tự kiểm tra định kỳ không mở nó. Ghi chú lấy từ `releases?per_page=30` (mọi bản mới hơn bản đang dùng, tối đa 8), tách phần đúng ngôn ngữ giao diện, bỏ mục Tải về và Ủng hộ (`ReleaseNotes.blocks`).

Hộp thoại dùng `DialogWindow` và `DialogButtonStyle` (Dialog.swift, Theme.swift). Đừng dùng `NSHostingController.sizingOptions = .preferredContentSize` hay `.help` trong các cửa sổ này: thử ngày 08/10/2026 cả hai làm AppKit tính lại bố cục mãi rồi dừng app. Hộp thoại đổi cỡ theo trạng thái thì gọi `DialogWindow.fit` với cỡ đo trên một `NSHostingView` mới tạo; đo trên chính view trong cửa sổ trả về 0x0 và làm cửa sổ co giãn liên tục (lỗi của 1.1.66). Khi thử hộp thoại đổi cỡ, ghi chiều cao cửa sổ theo thời gian (`OVERSUB_UPDATE_PROMPT_TEST` ghi mỗi 0,1 giây trong 5 giây), đừng chỉ chụp một ảnh lúc đã ổn định.

Nhãn tên người nói được tách khỏi câu thoại theo cỡ và màu chữ. Có lúc nhãn không tách được và dính vào đầu câu ("Experienced Farmer These vineyards..."); nếu dòng đầu trùng một tên vừa gặp (cho phép lệch một ký tự, như "Hill×") thì `Engine.splitKnownLabel` vẫn coi đó là nhãn. Không có bước này, app tưởng câu mới và đọc lại; đo thực có câu bị đọc 5 lần.

### Ba cách bắt thoại

Chữ chạy dành cho game gõ chữ từng ký tự. Cân bằng dịch sau hai lần đọc ra cùng chữ. Chờ đủ câu chờ chữ đứng yên hẳn. Cả ba chốt theo nội dung chữ, nên nền chuyển động không làm app kẹt. Thấy chữ mới thì app đọc lại sau 0,15 giây; câu dịch lỗi được dịch lại.

### Chữ chạy

Ở chế độ Chữ chạy, app dịch từng cụm chữ đã hiện xong (tới dấu phẩy, dấu chấm, hoặc đủ vài từ). Từ bản 1.1.37, việc dịch chạy riêng (`Engine.ProgLine`): vòng quét vẫn chụp đều trong lúc chờ AI. Trước đó vòng quét chờ dịch xong mới quét tiếp, có lần bị chặn 7 giây, và ở cắt cảnh những khung phụ đề hiện rồi tắt trong lúc đó bị lỡ hẳn.

Các cụm của cùng một câu dịch nối tiếp nhau, cụm sau lấy bản dịch cụm trước làm ngữ cảnh. Dịch song song thì AI lặp ý hoặc mất nghĩa ("Ngày trước, trước đây..."). Câu khác thì không phải chờ. Kết quả được ghép đúng thứ tự; câu bị thay giữa chừng vẫn được dịch và đọc nốt.

Game hay ngừng gõ một nhịp ở chỗ đổi màu chữ. Vì vậy app chờ chữ đứng yên một số nhịp rồi mới dịch phần cuối: 2 nhịp nếu đã có dấu kết thúc câu, 3 nhịp nếu dừng ở dấu phẩy hay hai chấm (câu bị cắt sang khung phụ đề sau), 6 nhịp nếu không có dấu nào (`progressiveSettled`).

### Khi nào giọng đọc lên tiếng

Giọng chỉ đọc khi đủ câu: chữ gốc hoặc bản dịch có dấu kết thúc, hoặc chữ đã đứng yên. App xét cả chữ gốc vì với cụm nối tiếp, AI hay bỏ dấu chấm cuối bản dịch; trước bản 1.1.35, câu như vậy nằm chờ tới khi câu sau hiện ra.

Nếu phần đầu câu đã dịch mà phần sau chưa tới, `queueLineDub` hẹn đọc trước phần đã có: sau 1,8 giây nếu phần đó dừng ở dấu phẩy, sau 2,5 giây nếu dừng giữa cụm từ mà cụm sau đang dịch dở. Phần sau đọc nối khi tới. Đo 901 câu trong nhật ký thật (07/10/2026): một nửa được đọc trong 0,1 giây sau khi cụm đầu dịch xong, 90% trong 3,6 giây, 69 câu chờ quá 4 giây. Nguyên nhân chính là giọng chờ đủ cả câu trong khi phụ đề đã hiện nửa đầu, có lúc cả Gemini lẫn Groq cùng chậm. Ngưỡng 1,8 giây chọn theo đo thực: cụm sau thường tới sau 1 đến 1,7 giây, chờ 0,8 giây thì câu bị tách đôi vô ích.

Khoảng một phần ba số câu chờ lâu là do câu trước chưa đọc xong, vì giọng đọc chậm hơn chữ hiện. Phần này có tăng tốc theo độ dài hàng đợi, chưa đổi thêm.

### Không đọc lặp

`recentDubs` và `alreadySpoken` là lớp chặn cuối: câu giống câu vừa đọc trong 45 giây thì bỏ, trừ khi người dùng bấm Đọc lại. App so cả bản dịch lẫn câu gốc, vì cùng một câu gốc AI có thể dịch hai cách. Câu ngắn chỉ tính là lặp khi cùng người nói. Trường hợp gặp thật: chuyển sang app khác rồi quay lại game, câu cũ vẫn nằm trên màn hình và bị đọc lại sau 16 giây.

Lớp chặn này không được nhầm câu game gõ lại từ đầu với câu cũ còn nằm đó. Ngày 07/10/2026, người dùng nói chuyện lại với một NPC: câu đầu được đọc (đã quá 45 giây) nhưng câu sau bị bỏ, nghe như đọc nửa chừng rồi im. Giờ câu nào dài thêm từ 12 ký tự trở lên so với lần đầu thấy (`ProgLine.typedIn`) thì luôn được đọc.

### Khi nào tạm ngưng

`isGameInFront` quyết định có quét hay không. Lúc chọn vùng, app nằm dưới vùng được nhận là game (`detectGame`).

Màn hình chơi game của OverSub nằm trên cùng ở vùng phụ đề thì luôn tính là game đang hiện, dù hồ sơ gắn với app nào; thu nhỏ hay bị app khác che thì tạm ngưng như game thường.

Trước bản 1.1.51, app chỉ quét khi game là app đang được chọn. Người dùng chơi console bằng tay cầm, VisionRelay chỉ để xem, và hay bấm sang app khác trong lúc thoại vẫn chạy; nhật ký có 224 lần tạm ngưng, 94 lần dưới 5 giây, nhiều đoạn thoại bị lỡ. Giờ app còn xét `gameVisibleInRegion`: duyệt các cửa sổ thường từ trên xuống, bỏ qua cửa sổ của OverSub; gặp cửa sổ game trước thì vẫn quét, gặp cửa sổ app khác che từ một phần tư vùng phụ đề trở lên thì tạm ngưng. Nhật ký ghi app đang chọn và app che, ví dụ "Đang chọn Finder, vùng phụ đề bị Finder che".

Khoá máy, bảo vệ màn hình, màn hình tắt hay đang ở phiên người dùng khác đều không phải lỗi. `screenAway()` xét `CGSSessionScreenIsLocked`, phiên có ở màn hình chính không, app đang trước có phải loginwindow hay ScreenSaverEngine không, và `CGDisplayIsAsleep`. Gặp một trong các trường hợp đó, app tạm ngưng êm và ghi "Tạm ngưng vì …". Lỗi chụp rơi đúng lúc vừa khoá máy cũng không hiện thông báo "macOS từ chối chụp màn hình". Cần xét riêng vì lúc khoá máy, cửa sổ game vẫn được liệt kê là đang hiện.

Trong lúc phiên chạy, app giữ màn hình sáng (`AppSettings.keepScreenAwake`, mặc định bật) bằng `ProcessInfo.beginActivity([.idleDisplaySleepDisabled, .idleSystemSleepDisabled])`, dừng thì trả lại. Chơi bằng tay cầm thì Mac không nhận thao tác nào và tự tắt màn hình hay khoá máy giữa chừng. `pmset -g assertions` cho thấy PreventUserIdleDisplaySleep và PreventUserIdleSystemSleep của OverSub lúc chạy, dừng thì hết.

## Dịch

### Dịch vụ

Dịch máy Apple và Apple Intelligence chạy trên máy, không giới hạn. Gemini, Groq, Cerebras, Mistral, OpenRouter và một "dịch vụ tự thêm" (API kiểu OpenAI như OpenAI, DeepSeek, xAI, Together, Fireworks) chạy qua mạng và cần key. Trừ Gemini, các dịch vụ qua mạng dùng chung `Providers.openAI`. Mỗi dịch vụ nhận nhiều key, và key chỉ được thêm khi kiểm tra chạy được.

Hạn mức Gemini tính theo dự án Google Cloud chứ không theo key. Hai key cùng dự án dùng chung hạn mức, và Google từng khoá các dự án lập ra để né hạn mức, nên dự phòng nên là key của dịch vụ khác.

Mới thử thật với Gemini và Groq. Với Cerebras, Mistral, OpenRouter và dịch vụ tự thêm, mới kiểm được địa chỉ API và cách báo lỗi key sai.

### Thứ tự và dự phòng

`TranslationHub.currentOrder` sắp dịch vụ theo chế độ chất lượng, tốc độ, cân bằng hoặc tuỳ chỉnh. Tốc độ là trung vị 20 lần dịch gần nhất, cộng phạt theo tỉ lệ lỗi (`typicalMs`), lưu qua các lần mở app. Thêm key thì app gửi ba câu thử để có số đo ngay; trang Dịch vụ dịch có nút Đo lại. Lô chữ dài của dịch màn hình không tính vào số đo. Thứ tự tuỳ chỉnh chỉ liệt kê dịch vụ đang bật và có key; dịch vụ mới bật nằm cuối.

Dịch vụ đầu chậm quá 1 giây hoặc lỗi sớm thì app gửi song song cho dịch vụ kế tiếp và lấy kết quả về trước (`Hedge`). Nhật ký 07/10/2026 có 179 lần Gemini quá 1 giây. Key hết hạn mức thì chuyển key khác; model không còn dùng được thì app chọn model khác từ danh sách của tài khoản (`repairModel`). Trang Dịch vụ dịch hiện trạng thái từng dịch vụ, từng key và nhật ký chuyển đổi.

Gemini và Groq trả chữ dần (SSE): phụ đề hiện dần, câu trọn đầu tiên được đọc ngay. Dịch vụ đầu đã ra chữ thì không gửi dịch vụ dự phòng. AI chưa trả lời sau 0,25 giây thì phụ đề hiện tạm bản Dịch máy Apple; giọng đọc luôn chờ bản AI.

### Trí nhớ dịch và lọc

`TranslationMemory` lưu câu đã dịch theo hồ sơ và ngôn ngữ dịch (tối đa 4.000 câu); gặp lại thì dùng ngay, không gọi API. App bỏ qua chữ đã là ngôn ngữ đích (`TextUtil.isAlreadyTarget`, dùng NaturalLanguage) và nhãn tên rác.

App chỉ dịch phụ đề. Có ba lớp: luật trong app (`SubtitleFilter`, áp cho mọi dịch vụ), lời nhắc có dấu `[BỎ QUA]` (hoặc `[SKIP]` với ngôn ngữ khác) cho Gemini và Groq, và danh sách "luôn bỏ qua" của người dùng.

### Xưng hô, văn phong, tên riêng

App gửi tên người nói và tối đa 10 câu trước, cùng thể loại game: 13 thể loại có sẵn, Tự động và Tuỳ chỉnh. Thể loại Tuỳ chỉnh (`CustomStyle`, lưu theo hồ sơ game) cho người dùng tự mô tả bối cảnh, nhân vật và quan hệ, xưng hô, giọng văn, mức trang trọng, chửi thề, kính ngữ và yêu cầu khác. Mỗi ô tối đa 400 ký tự, có nút điền sẵn từ thể loại có sẵn và phần xem trước đoạn gửi cho AI. Bối cảnh game cũng được đưa vào lời nhắc của dịch màn hình. Im lặng quá 45 giây thì app quên ngữ cảnh.

Chữ gợi ý dưới mục thể loại trong Cài đặt dùng chỉ dẫn tiếng Việt (có ví dụ xưng hô) chỉ khi giao diện là tiếng Việt; giao diện tiếng Anh xem bản tiếng Anh. Phần gửi cho AI không đổi theo giao diện.

Từ điển thuật ngữ thay tên riêng bằng mã tạm (Xqza...) trước khi gửi, nên tên được giữ đủ trên Gemini, Groq và Dịch máy Apple.

## Giọng đọc

### Voice-over và hàng đợi

Voice-over dùng một giọng Siri, phát thẳng nên gần như không trễ. Giọng được khởi động sẵn lúc mở app để câu đầu cũng đọc ngay; thường mất 1 đến 3 giây, có lần đo được 38 giây khi máy vừa mở.

Hàng đợi không cắt câu đang đọc. Câu trễ quá 6 giây mà đã có câu mới hơn thì bị bỏ (tắt được), trừ phần nối tiếp của câu vừa đọc (`lastGroup`), vì bỏ phần đó thì câu bị cụt. Tốc độ tự cân theo nhịp thoại, tính một lần cho cả câu: trước đây mỗi cụm tính riêng nên câu này chậm, câu sau vội. Cụm sau của cùng câu mà cụm trước còn chờ trong hàng đợi thì được nối vào để đọc liền một lần.

Không có cơ chế tăng tốc giữa câu. Giọng Siri tiếng Việt báo vị trí từ (`willSpeakWord`) không đáng tin, có lúc báo trọn câu đầu ngay khi mới đọc, và lệnh dừng ở cuối từ hay cuối câu đều cắt ngay. Dừng giữa chừng rồi đọc tiếp nhanh hơn làm mất một đoạn, nên cơ chế này đã bỏ từ bản 1.1.35. Đừng dựng tính năng nào dựa vào vị trí đang đọc.

macOS chỉ cho app khác dùng giọng Siri đang được chọn cho mỗi ngôn ngữ (giọng A và D tiếng Việt dựng ra giống hệt nhau), và giọng Siri neural bỏ qua `pitchBase` khi đọc thẳng. Bộ dẫn Đổi giọng Siri (`SiriVoiceGuide.swift`) mở cạnh Cài đặt hệ thống và đánh dấu từng bước khi người dùng làm xong.

Chọn loa hay tai nghe riêng làm mỗi câu chậm thêm khoảng 1 giây vì phải dựng âm thanh trước. Giảm tiếng game khi đang đọc dùng Core Audio process tap (`AudioDucker`, cần quyền ghi âm thanh hệ thống) và vẫn là thử nghiệm.

### Dub (beta)

Mỗi nhân vật, nhận từ nhãn tên trên hộp thoại, có một giọng theo giới tính và tuổi. Groq hoặc Gemini đoán giới tính và tuổi ở câu đầu (`TranslationHub.ask`, chỉ chạy khi bật Dub). Giọng Apple gồm Siri và Linh, đổi cao độ bằng AVAudioUnitTimePitch để phân biệt. Dàn diễn viên lưu theo hồ sơ game. Câu nào chưa dựng kịp giọng nhân vật trong 1 giây thì đọc ngay bằng giọng Voice-over.

Trang Nhân vật có ba bước kiểm tra: bật hiện tên nhân vật trong game, khung chọn gồm cả nhãn tên (app báo đọc được tên ở bao nhiêu câu gần nhất), và nghe thử giọng.

Gemini TTS (`GeminiTTS`, Interactions API, theo luồng, chỉ dẫn qua `speech_metadata.style`) đang tạm khoá vì đo được chậm 4 đến 8 giây mỗi câu.

## Màn hình chơi game

Nhận hình và tiếng từ capture card, mở thành một cửa sổ thường của OverSub để chơi console trên Mac thay cho app xem hình riêng.

- `CaptureCard.swift`: `CaptureCards` tìm thiết bị bằng `AVCaptureDevice.DiscoverySession` loại `.external` và `.builtInWideAngleCamera` (danh sách trong menu và Cài đặt có đủ mọi camera) và theo dõi `wasConnected`/`wasDisconnected`. Mở màn hình chơi khi chưa cắm card thì không tự bật camera nào, trừ thiết bị người dùng đã chọn. `looksLikeCaptureCard` lọc camera để dòng báo ở chân cửa sổ chính chỉ nói về capture card: không phải loại `.external` thì bỏ; tên có chữ của capture card hoặc nhà sản xuất MACROSILICON thì nhận, tên có chữ của webcam hay do Apple làm thì bỏ, tên lạ phải có định dạng từ 720p 50 khung/giây trở lên. Nguồn tiếng lấy từ `linkedDevices`, không có thì thiết bị tiếng trùng tên, không bao giờ tự chọn micrô gắn trong. `PlaySettings` là tuỳ chọn chung cho mọi hồ sơ (khoá `play.*`).
- `PlayCapture.swift`, `CMIOVideoStream.swift`: hình đọc thẳng hàng đợi khung của CoreMediaIO (`CMIOStreamCopyBufferQueue`), không qua `AVCaptureSession` (lý do ở đoạn đo bên dưới). Thiết bị ghép theo UID (trùng `AVCaptureDevice.uniqueID`), định dạng và tốc độ khung đặt qua thuộc tính của luồng; một lượt có nhiều khung thì chỉ vẽ khung mới nhất. Tiếng vẫn qua `AVCaptureSession` chỉ có đầu vào tiếng và `AVCaptureAudioPreviewOutput`. Định dạng nén (MJPEG) hay thiết bị CoreMediaIO không nhận thì quay về `AVCaptureSession` với `AVCaptureVideoDataOutput` như bản 1.1.68; nhật ký ghi "hình qua CoreMediaIO" hoặc "hình qua AVCaptureSession". Xin đúng định dạng gốc của card: card Hagibis (chip MACROSILICON) gửi 4:2:2 `yuvs`; để macOS đổi sang 4:2:0 thì tốn thêm một bước `VTPixelTransferSession` cho mỗi khung. MJPEG giải mã ra `420f`.
- `PlayRenderer.swift`: vẽ bằng Metal lên `CAMetalLayer` (shader biên dịch lúc chạy). Đổi YCbCr sang RGB theo dải sáng và ma trận đã chọn; 4:2:2 đọc qua `MTLPixelFormat.bgrg422`/`.gbgr422`. Làm nét kiểu unsharp trên độ sáng, phóng bằng `MTLFXSpatialScaler` (tối đa gấp đôi, cỡ khác thì phóng thường; đang kéo cỡ thì tạm không dùng), Khung hình Vừa khung (viền đen) hoặc Lấp đầy (cắt đều phần thừa, thay cho cắt viền đều bốn cạnh vốn không bỏ được viền đen trên màn 16:10), HDR10 giải PQ rồi nén về SDR hoặc xuất EDR (`rgba16Float`, không gian tuyến tính mở rộng). Độ trễ Mượt dùng `present(afterMinimumDuration:)` với ba khung đệm.
- Luồng: CoreMediaIO (hoặc AVCaptureSession) giao khung trên `videoQueue` của `PlayCapture`; luồng này chỉ đếm, đo nhịp rồi đặt khung mới nhất vào hộp chờ, `renderQueue` riêng lấy ra vẽ (`drawPending`). Trước 1.1.73 việc vẽ nằm ngay trên `videoQueue`: `nextDrawable` chặn tới gần một giây khi WindowServer vẽ trễ (GPU bị app khác chiếm, đổi Space, cửa sổ bị che), hàng đợi của card đầy và khung mất hẳn. Người dùng gặp lúc chơi ngày 09/10/2026 (iOS Simulator của một phiên khác chiếm khoảng 27% GPU): có lúc chỉ nhận 19 khung/giây, 70 đến 98 khung bị bỏ mỗi 10 giây, gần hai phút mới hồi. Đo cùng điều kiện bằng card thật: trước khi tách, chờ drawable lâu nhất 844 ms, khoảng hở giữa hai khung của card tới 688 ms, đổi bộ chỉnh hình làm hở 278 ms; sau khi tách, khoảng hở lâu nhất 16 đến 23 ms kể cả khi drawable chờ 1,06 giây, không mất khung nào. Khung chưa kịp vẽ mà có khung mới thì bị thay ("khung thay vì vẽ chậm" trong nhật ký); dòng nhật ký 10 giây ghi phần bộ vẽ trên `renderQueue` để hai luồng không tranh trạng thái của bộ vẽ.
- Nhịp khung: dòng 10 giây ghi khoảng cách giữa các khung theo mốc thời gian card ghi (trung vị, dài nhất, số lần hở và dồn), thời gian chờ drawable, mức bận GPU của cả máy (`IOAccelerator` › `PerformanceStatistics` › `Device Utilization %`, kèm trạng thái nhiệt khi nóng). Card Hagibis ghi định dạng 60 khung/giây nhưng có lúc gửi đều 15,6 ms một khung (64 khung/giây; sáng cùng ngày là 59,8): nhịp đo được lệch quá 3% so với nhịp đang dùng thì `frameInterval` theo nhịp đo (độ trễ Mượt, chèn khung, số trễ thêm). Trước đây chèn khung gấp đôi tính theo 60, khung dồn chờ hiện và chỉ hiện 80 đến 98 khung/giây.
- Chèn khung gấp đôi không vượt tần số màn hình (`displayHz` lấy từ `NSScreen.maximumFramesPerSecond`): mỗi khung tín hiệu cộng `(tần số màn hình − tốc độ tín hiệu) / tốc độ tín hiệu` vào một ngân sách, đủ 1 thì chèn khung giữa, không thì chỉ hiện khung thật (khung vẫn qua bộ chèn để giữ làm khung trước). 64 khung/giây trên màn 120 Hz chèn 7 trên 8 khung. Đo với card thật lúc GPU cả máy 55 đến 69%: hiện 109 đến 111 khung/giây.
- `RangeDetector` lấy mẫu 64×36 điểm độ sáng bốn lần mỗi giây. Đang hiểu dải giới hạn mà có trên 0,3% mẫu dưới 10 hoặc trên 250 ở ba lần lấy mẫu thì đổi sang dải đầy đủ; đang hiểu dải đầy đủ mà 20 giây liền không có mẫu nào ngoài 12–243 thì quay về dải giới hạn, dù khung ghi dải nào. Bỏ qua khung gần như một màu (card tự phát khung đen độ sáng 0 khi máy console tắt) và mọi mẫu trong 2 giây đầu sau lúc mở hay sau khung một màu. Đo trên card Hagibis với Switch 2 dải giới hạn: khung đầu tiên là khung cũ dở dang (phần lớn độ sáng 0), rồi màn đen độ sáng 16 khoảng 7,5 giây, rồi lúc hình hiện có một mảng tối lấm tấm độ sáng 0–15 ở góc trên trái trong khoảng 0,75 giây; bản 1.1.69 trở về trước cộng hai thứ đó thành ba lần và hiểu nhầm là dải đầy đủ ở gần như mọi lần mở. Nhật ký ghi độ sáng thấp nhất, cao nhất mỗi 10 giây cùng cách hiểu đang dùng, và một dòng mỗi lần đổi cách hiểu.
- `PlayScreen.swift`: cửa sổ (`setFrameAutosaveName`; không có thanh tiêu đề thấy được và hình phủ kín, `PlayView` là view đục nên macOS không cho kéo cửa sổ ở đâu cả, `mouseDown` gọi `performDrag` để nắm kéo hình là di chuyển được, 1.1.71 chưa có), thanh điều khiển là cửa sổ con riêng (không lọt vào ảnh chụp phụ đề), menu tuỳ chọn dựng bằng AppKit, lời báo trong cửa sổ khi chưa có hình, hướng dẫn cấp quyền Camera và Micrô. Đổi thiết bị, định dạng hay nguồn tiếng ở menu hoặc ở Cài đặt thì phiên tự mở lại.
- Đọc phụ đề trên cửa sổ này: `ScreenGrabber` vẫn loại cả ứng dụng OverSub khỏi ảnh chụp nhưng thêm cửa sổ màn hình chơi vào `exceptingWindows`. `gameUnder` gắn hồ sơ với mã giả `PlayScreen.gameID`; `gameVisibleInRegion` coi cửa sổ này là game, bỏ qua các cửa sổ khác của OverSub; chọn vùng không ẩn cửa sổ này. Giọng đọc giảm âm lượng của chính cửa sổ thay cho tap tiếng của tiến trình game.
- Info.plist: `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`, `NSCameraUseExternalDeviceType`, `NSCameraReactionEffectGesturesEnabledDefault = false` (tắt mặc định cử chỉ Reactions; macOS 14.4+; chỉ còn tác dụng khi hình phải đi qua `AVCaptureSession`).

Đo ngày 09/10/2026 (macOS 27.2, M1 Pro, cửa sổ 1280×720, card Hagibis 1080p60 `yuvs` kèm tiếng, Switch 2 đang lên hình), thời gian CPU cộng dồn trong 20 giây, hai đường đo xen kẽ trong cùng một đợt:

- Riêng phần vẽ (nguồn thử 60 khung/giây): 4 đến 7% một nhân khi mở, gần 0% khi đóng.
- Hình qua `AVCaptureSession` (1.1.68): OverSub 23 đến 24,5% một nhân. Trong tiến trình, macOS chạy đường hiệu ứng video trên từng khung (`FigObjectDetectionMetadataGenerator`, `VCPHandGestureVideoRequest`, `PTEffectReactionProvider`, `PTEffectRenderer`, thấy bằng `sample`) dù cử chỉ Reactions đã tắt và bảng Hiệu ứng video cho thấy mọi hiệu ứng đều tắt. Một app thử nhỏ chỉ nhận hình, không vẽ, tốn 18 đến 21% và luôn có các luồng trên, bất kể có sandbox hay không, SDK 15.1 hay 27, có gọi năm hàm riêng `_setReactionsAllowed:`, `_setCenterStageAllowed:`, `_setStudioLightingAllowed:`, `_setBackgroundBlurAllowed:`, `_setBackgroundReplacementAllowed:` của `AVCaptureDevice` (VisionRelay gọi các hàm này) hay không. Trước đó đã thử `NSCameraReactionEffectsEnabled = false` (chỉ dành cho iOS), bỏ đường tiếng, `NSCameraUseExternalDeviceType`: đều không tác dụng.
- Hình qua CoreMediaIO (từ 1.1.69): OverSub 13,5 đến 17,5% khi vẽ đủ 60 khung/giây, không còn luồng hiệu ứng; app thử chỉ nhận hình 6%. Bỏ tiếng chỉ bớt khoảng 1 điểm. Hình lên sau 0,1 giây (AVCaptureSession 0,3 đến 0,4 giây).
- VisionRelay cùng đợt: 15 đến 16,6% trong tiến trình của nó, không đẩy việc sang tiến trình hệ thống (cameracaptured, avconferenced, mediaanalysisd không tăng). Phần còn chênh nằm ở UVCAssistant (trình điều khiển UVC của macOS, tính riêng ngoài app): VisionRelay xin 4:2:0 `420v`, card Hagibis có sẵn `420v` 1080p60, app thử đo UVCAssistant 18% với `420v` và 24,5% với `yuvs`. OverSub vẫn xin `yuvs` để giữ màu 4:2:2.
- UVCAssistant dao động 25 đến 39% theo tín hiệu (có lúc card gửi 63 đến 64 khung/giây), WindowServer 40 đến 65% theo cỡ cửa sổ và việc khác trên máy, nên chỉ so các số đo trong cùng một đợt.
- Card thỉnh thoảng gửi khung đen độ sáng 0 vài giây đầu (đo được tới 7,5 giây), gặp ở cả hai đường; ảnh chụp đầu tiên của bài thử `device` vì thế có thể đen.

`AVCaptureDevice.reactionEffectsEnabled` trả true kể cả khi người dùng thấy Reactions tắt: cờ này chỉ nói app được phép dùng Reactions. Mục Hiệu ứng video của macOS (`AVCaptureDevice.showSystemUserInterface(.videoEffects)`, cũng là biểu tượng camera xanh trên thanh menu) chỉ có khi app nhận hình qua `AVCaptureSession`. Đo CPU bằng thời gian CPU cộng dồn (`ps -o time`) của mọi tiến trình trong cùng khoảng, không dùng `ps %cpu` (trung bình trượt cả phút, lẫn các bước trước). Dòng nhận/vẽ mỗi 10 giây trong nhật ký ghi kèm lý do không vẽ (`cửa sổ ẩn`, `texture`, `drawable`): cửa sổ bị Stage Manager hay cửa sổ khác che thì không vẽ, đừng đo CPU lúc đó.

### Bộ chỉnh hình

Capture card chỉ đưa hình đã vẽ xong (không có vectơ chuyển động, chiều sâu, độ lệch jitter của game), nên DLSS, FSR 2/3/4, MetalFX Temporal và MetalFX Frame Interpolation không áp được. Bộ chỉnh hình chỉ dùng thuật toán làm việc trên hình hoàn chỉnh.

- Đường vẽ: khi có xử lý, `render()` đổi màu vào texture `rgba16Float` ở độ phân giải gốc (đã cắt theo Lấp đầy) thay vì vẽ thẳng vào drawable; rồi `PlayInterpolator` (chèn khung) và `PlayEffects` (FXAA ở độ phân giải gốc, phóng tới cỡ khung, RCAS, đặt vào drawable). Không có xử lý thì vẫn vẽ thẳng như cũ. Đang kéo đổi cỡ thì chỉ phóng song tuyến. Hình EDR chỉ phóng song tuyến hoặc MetalFX chế độ HDR (các bộ lọc khác giả định giá trị 0...1). Bộ làm nét cũ trong shader đổi màu đã thay bằng RCAS.
- `PlayEffects.swift`: FSR 1 EASU và RCAS chuyển từ `ffx_fsr1.h` (bản 32 bit, MIT), FXAA viết lại theo FXAA 3.11 Quality, MetalFX Spatial, Anime4K. `PlayAnime4K.swift` sinh bằng `Tools/a4k2metal.py` từ hai tệp GLSL của Anime4K (MIT): `3DGraphics_AA_Upscale_x2_US` (3 lớp) và `Upscale_CNN_x2_S` (4 lớp). Mỗi lớp là tích chập 3×3 dạng `float4x4 * float4` (giữ nguyên quy ước cột của GLSL), rồi bước Depth-to-Space cộng phần dư vào hình phóng song tuyến. Thông báo giấy phép ở `Docs/THIRD_PARTY_NOTICES.md`, `build.sh` chép vào bản cài.
- `PlayInterpolator.swift`: độ sáng thu 1/4; tìm vectơ đối xứng cho khối 8×8 (±12 ở cỡ 1/4, tức ±96 điểm ảnh mỗi khung), ưu tiên vectơ 0; trung vị 3×3; vectơ chung của cả cảnh (vectơ nhiều khối nhất); mỗi điểm ở cỡ 1/4 chọn lại vectơ khớp nhất trong 11 ứng viên (vectơ chung, vectơ 0, 9 khối quanh); dựng khung giữa, chỗ không khớp lấy khung sau đã dời. Cách `double` hiện khung chèn rồi khung thật sau nửa nhịp (`present(afterMinimumDuration:)`, ba khung đệm). Cách `thirty` nhận khung lặp bằng 64×36 mẫu độ sáng trên CPU (khác trung bình dưới 0,5 và không mẫu nào khác quá 6), hiện trễ một nhịp, thay khung lặp bằng khung giữa; 2 giây không thấy khung lặp thì thôi chờ.
- `PlaySettings.Preset` gom `upscaler`, `sharpen` (RCAS: Nhẹ 1, Vừa 0,5, Mạnh 0 stop), `antiAlias`, `frameGen`; chỉnh từng mục thì tự nhận lại bộ trùng hoặc thành Tuỳ chỉnh. `superResolution` của 1.1.68 giữ lại thành thuộc tính tính toán (MetalFX). Chữ hiển thị ở `PlayPresets.swift`.
- Độ trễ thêm (input lag so với Gốc) ghi ở mọi lựa chọn, tính bằng `PlayCost`: phần chờ của chèn khung (gấp đôi nửa nhịp, 30 lên 60 một nhịp, theo tốc độ khung của tín hiệu) cộng phần GPU vẽ lâu hơn. Thời gian GPU dựng theo số điểm ảnh của hình gốc (S) và vùng vẽ (D), hệ số ms mỗi megapixel lấy từ `Tools/fxbench`: đổi màu 0,08·S, bước cuối 0,08·D, FXAA 0,39·S, EASU 0,22·D, MetalFX 0,23·D, Anime4K 3D 0,95·S và hoạt hình 1,4·S (kèm 0,08·D phóng lại), dựng khung giữa 0,58·S; gấp đôi xử lý hai lần mỗi khung tín hiệu; vùng vẽ không lớn hơn hình gốc thì bỏ bước phóng (đúng như `PlayEffects.encode`). Ước lượng nhân với hệ số của máy: `PlayRenderer` đo thời gian GPU 2 giây một lần cho đúng một cách xử lý (đổi cách hay đổi cỡ giữa chừng thì bỏ lần đo), chia cho ước lượng, chỉnh hệ số dần (70% cũ, 30% mới) và lưu ở `play.cost` cùng tín hiệu và cỡ khung hình, nên trang Cài đặt có số đúng máy cả khi chưa mở màn hình chơi. Hệ số khoảng 1,3 khi GPU bận (tín hiệu 60 khung/giây) và 2 đến 3 khi GPU rảnh (30 khung/giây), vì GPU của Mac hạ xung khi ít việc. Bộ chỉnh hình ghi tổng; từng mục của Tuỳ chỉnh ghi phần riêng mục đó cộng vào (so với tắt nó). Đo ngày 09/10/2026 (tín hiệu 1080p 30 khung/giây, cửa sổ 2560×1440 điểm ảnh): nhãn so với đo được Nét 3 và 3,0 ms, Mịn cạnh 5 và 3,9, Game 3D 6 và 5,9, Hình hoạt hình 8 và 7,9, Mượt 60 khung/giây 24 và 23,8.
- Tín hiệu dưới 45 khung/giây (chế độ 2560×1440 · 30 của card Hagibis) không có khung lặp để thay, nên cách "30 lên 60" chạy như gấp đôi (`PlayCost.effective`); 1.1.71 để nguyên, người dùng bật mà hình không mượt hơn.
- Các đánh đổi khác ghi ngay ở lựa chọn: định dạng dưới 50 khung/giây (kém mượt, trễ thêm trung bình nửa hiệu khoảng cách khung so với 60), 4:2:2 và 4:2:0 (màu viền chữ, CPU), loa Bluetooth (`AudioDevices.isBluetooth`, tiếng trễ thường hơn 0,1 giây), Display P3 lệch màu gốc, HDR (EDR) tắt bớt bộ chỉnh hình, làm nét mạnh lộ viền sáng, FXAA làm mềm chữ nhỏ.

Đo ngày 09/10/2026 trên M1 Pro bằng `Tools/fxbench`, chạy ngoài app: `swiftc -O -o /tmp/fxbench Sources/PhuDe/PlayEffects.swift Sources/PhuDe/PlayAnime4K.swift Sources/PhuDe/PlayInterpolator.swift Tools/fxbench/main.swift && /tmp/fxbench <thư mục ảnh>`.

- Phóng 1920×1080 lên 3840×2160, so với hình vẽ thẳng ở 4K, PSNR độ sáng: song tuyến 33,8 dB, MetalFX 35,2, FSR 1 EASU 35,9, EASU kèm RCAS 35,7, Anime4K 3D 35,3, Anime4K hoạt hình 36,8. GPU khi phóng lên 3024×1701 (MacBook Pro 14 toàn màn hình): 0,4 / 1,6 / 1,5 / 1,6 / 3,1 / 4,4 ms.
- FXAA: hơn hình răng cưa 0,7 dB, 0,8 ms.
- Chèn khung: 1,2 ms mỗi khung chèn. Cảnh lia ngang 48 điểm mỗi khung: 40,7 dB so với khung giữa đúng (trộn hai khung 19,7, lặp khung 18,4). Chữ HUD đứng yên: sai khác 0. Vật 160×160 chạy 80 điểm mỗi khung: tâm đúng trong khoảng 1 điểm, mép còn bậc 4 điểm.
- Trong app (cửa sổ 2560×1440 điểm ảnh, `OVERSUB_PLAY_TEST=motion`): gấp đôi hiện khoảng 115 đến 120 khung/giây trên màn ProMotion; 30 lên 60 nhận đúng khoảng 30 khung lặp mỗi giây; mọi bộ giữ màu thang xám, lệch tối đa 1/255.

Đã thử và bỏ: siêu phân giải và chèn khung độ trễ thấp của VideoToolbox (`VTLowLatencySuperResolutionScaler`, `VTLowLatencyFrameInterpolation`, macOS 26, chạy Neural Engine). Siêu phân giải chỉ nhận nguồn tối đa 1280 điểm mỗi cạnh (×1,5) hoặc 960 (×2), không nhận 1080p; chèn khung ở 1080p mất 95 ms mỗi khung trên M1 Pro (720p thì 5,7 ms). Cả hai làm cho gọi video độ phân giải thấp.

## Dịch màn hình và Dịch nhanh

Dịch màn hình (⌃⌥T) dịch tại chỗ chữ ngoài lời thoại như bảng nhiệm vụ, menu, mô tả vật phẩm. Nó không đọc to và không vào Cửa sổ phụ đề hay lịch sử. Tối đa 3 vùng, lưu theo hồ sơ game.

Mỗi vùng được chia thành cụm chữ (`ScreenText.blocks`): mục menu, nút, đoạn mô tả, với các dòng xuống hàng của cùng một đoạn được gộp. Chữ gốc bị xoá bằng cách dựng lại nền từ điểm ảnh xung quanh (`Inpaint`, khoảng 10 ms), cắt theo từng mảng với mép làm mềm. Chữ dịch cùng màu chữ gốc, cỡ ước theo bề ngang dòng gốc (`ScreenText.fontSize`), độ đậm theo độ dày nét; các mục cùng cột hay cùng hàng có cỡ gần nhau thì dùng chung một cỡ. Câu dịch dài hơn được nén ngang tới 0,88 trước khi phải giảm cỡ chữ.

App dịch mọi cụm còn thiếu trong một lần gọi AI (`TranslationHub.translateUI`, lời nhắc riêng cho chữ giao diện, đánh số từng dòng), Groq trước, thường dưới 0,6 giây, chia lô 12 dòng, lỗi thì thử lại sau 3 giây. AI trả "=" cho dòng không cần dịch (tên riêng, Menu, ký hiệu nút); bản dịch trùng chữ gốc thì không thay. Dòng có số được lưu thành mẫu ("Gold {0}"), số đổi thì điền lại mà không gọi AI. Chữ rất ngắn được nhớ trong phiên. Ba chế độ tốc độ (`ScreenSpeed`): Tức thì (Dịch máy Apple), Tức thì rồi chuốt bằng AI (mặc định), Chờ bản AI. Thiếu gói Dịch máy Apple thì dùng AI, và trang Dịch màn hình có nút tải gói.

App nhận biết chữ đổi bằng dấu hiệu chữ (`OCR.screenSignature`) và độ giống `TextUtil.dice`, không so điểm ảnh, nên hiệu ứng động không làm bản dịch chớp. Chữ sáng thì được đọc nhanh trên ảnh tách riêng chữ sáng, nên cảnh phía sau chuyển động khi nhân vật đi lại cũng không sao; không có chữ sáng thì đọc trên ảnh gốc và bỏ mẩu rác dưới 3 chữ cái. Đang hiện bản dịch thì app quét 0,2 giây một lần: hết chữ hay chữ khác hẳn thì gỡ ngay (tắt dần 0,08 giây), hơi khác thì chờ thêm một lần quét. Chữ không đổi mà vệt chọn di chuyển thì chỉ dựng lại nền và màu chữ. `ScreenText.cleanRange` bỏ ký tự rác do đọc nhầm biểu tượng ở hai đầu dòng. Phụ đề đang chạy thì dịch màn hình bỏ qua chữ nằm trong vùng phụ đề, để không có hai lớp bản dịch đè nhau.

Dịch nhanh (`QuickTranslate.swift`, ⌃⌥Q, không cần bấm Bắt đầu) mở lớp chọn toàn màn hình; kéo một khung, thả chuột là dịch tại chỗ bằng cùng quy trình với dịch màn hình. Vùng chỉ dùng một lần. Mặc định dừng hình lúc chọn và lúc đọc. Dưới vùng có ba nút biểu tượng: xem chữ gốc, chép bản dịch, đóng. Bản dịch đã nằm ngay trên màn hình nên hộp dạng chữ hiện chữ gốc (giữ xuống dòng theo từng cụm) kèm nút chép chữ gốc để tra cứu. ⌘C chép bản dịch, ⇧⌘C chép chữ gốc, Esc hoặc bấm ra ngoài để tắt.

## Giao diện

### Cửa sổ chính

Ba nút tròn bật tắt riêng: Phụ đề (⌃⌥H), giọng đọc (⌃⌥D) và Dịch màn hình (⌃⌥T). Mỗi nút có ba trạng thái: tắt, bật nhưng chưa chạy (cam dịu), đang chạy (phát sáng). Bắt đầu / Dừng (⌘R, ⌃⌥S) chạy cả phiên; bật tắt nút tròn lúc đang chạy thì có tác dụng ngay. Vùng phụ đề và vùng dịch màn hình chồng nhau thì phụ đề được ưu tiên.

Nút giọng đọc ở giữa là linh vật (`Mascot.swift`), cùng hình với icon. Linh vật có bốn trạng thái: ngủ khi tắt giọng đọc (mắt nhắm, mặt xám), chờ (mặt cam dịu, chớp mắt), nghe khi phiên chạy (mặt cam đậm, thỉnh thoảng liếc sang nút Phụ đề), và đọc (miệng mấp máy, phát sáng, sóng loang). Có câu thoại mới (`engine.transcript.last?.id` đổi) thì linh vật nảy nhẹ. Ống năng lượng nối nút Phụ đề với linh vật luôn có vệt sáng trôi; phiên chạy thì vệt chuyển cam và nhanh hơn.

Nền là sáu khối màu loang trôi chậm (`HomeBackdrop`), có lớp màu rực hiện dần khi phiên chạy. Chế độ sáng là chính: tông đào pastel, mép trên và giữa sáng hơn cho thanh công cụ và chữ dễ đọc. Nền chạy lên dưới thanh công cụ (`toolbarBackgroundVisibility(.hidden)`).

Câu đang đọc hiện như phụ đề trên game (nền tối) và sáng dần theo giọng. Hàng chip dưới cùng gồm dịch vụ dịch, ngôn ngữ dịch, nội dung hiện và thể loại; bên phải là âm lượng. Dòng trạng thái ở chân cửa sổ cũng là nơi báo bản mới và lời cảm ơn theo mốc, vì một thẻ riêng ở đầu cửa sổ sẽ đẩy hàng chip ra ngoài khi cửa sổ thấp.

Lịch sử thoại là một thẻ nổi bên phải (Esc để đóng), không chiếm chỗ của nội dung chính. Trước đây nó là cột bên, ép nội dung co lại và làm chữ bị cắt khi cửa sổ hẹp.

### Hiệu năng của hoạt ảnh

Đo ngày 07/10/2026 khi cửa sổ đang hiện: bất kỳ hoạt ảnh nào do SwiftUI vẽ lại từng khung hình (TimelineView, Canvas) cũng làm cả cửa sổ nhiều lớp kính vẽ lại, tốn khoảng 14 đến 16% một nhân CPU. Bản đầu của màn hình chính (nền MeshGradient, linh vật và ống năng lượng vẽ bằng Canvas) lên 22%.

Cách làm hiện tại: nền và vệt sáng trong ống chạy bằng Core Animation. Đổi mức thì đổi `speed` của lớp mà vẫn giữ vị trí vệt. Chớp mắt dùng hẹn giờ cộng hoạt ảnh ngắn. Chỉ miệng và sóng loang lúc đang đọc mới dùng TimelineView. Kết quả là khoảng 1 đến 2% khi cửa sổ đang hiện. Cửa sổ bị che, app bị ẩn hay thu nhỏ (`WindowPresence` theo dõi `occlusionState`, truyền xuống qua `\.homeAnimating`) thì các hoạt ảnh SwiftUI dừng và CPU về 0%. Hoạt ảnh mới ở màn hình chính nên ưu tiên Core Animation; nếu không được thì phải dừng theo `homeAnimating` và đo lại.

### Cửa sổ phụ đề

Cửa sổ phụ đề (⌘J) chỉ có câu thoại, sáng dần theo giọng. Nút chỉ hiện khi rê chuột và nổi đè lên chữ, nên không tốn chỗ. Mép trái có Bắt đầu / Dừng (kính xám khi dừng, cam khi chạy) và Bỏ qua câu này, đặt xa nút đóng để khỏi bấm nhầm. Bỏ qua câu này dùng biểu tượng chữ có dấu × (`text.badge.xmark`) ở mọi nơi; con mắt gạch chéo trước đây dễ bị hiểu là ẩn phụ đề.

Kéo thấp xuống hoặc bấm Một dòng thì cửa sổ còn một dải chữ mỏng: tên nhân vật đứng trước câu cùng cỡ chữ, câu dài thì cả dòng cùng co cho vừa. Cửa sổ mở lên là ghim sẵn: nổi trên cùng kể cả trên Dock (vẫn dưới thanh menu) và theo sang mọi Space, kể cả Space của game toàn màn hình. Trước bản 1.1.38, cửa sổ chưa ghim kéo sát đáy thì bị Dock che và không lấy lên được; giờ bỏ ghim mà đang ở vùng Dock thì cửa sổ tự đẩy lên, nằm ngoài mọi màn hình thì về chỗ mặc định. Nền chỉnh được độ mờ kính (0% là trong suốt hẳn, chữ có bóng) và độ tối. Cửa sổ đang mở lúc thoát app thì lần sau tự mở lại đúng chỗ cũ.

### Chọn vùng

`RegionEditor` là trình chọn dùng chung cho hai nút trên thanh công cụ. Nút vùng phụ đề (⌘K, ⌃⌥K) vẽ lại hoặc chỉnh vùng phụ đề, có nút Tự tìm phụ đề. Nút vùng dịch thêm, chỉnh hay xoá vùng dịch màn hình, tối đa 3. Tên hai nút đổi theo trạng thái (`RegionLabels`, dùng chung cho thanh công cụ, menu thanh trên, trang Vùng và hướng dẫn lần đầu): chưa có vùng thì "Thêm vùng phụ đề", "Thêm vùng dịch"; có rồi thì "Chỉnh vùng phụ đề", "Chỉnh vùng dịch · n/3". Trình chọn mở ra là hình trực tiếp; bấm Dừng hình (hoặc Space) để chọn trên ảnh đứng yên, lúc đó nút tô cam, viền màn hình cam và dòng hướng dẫn ghi "Hình đang dừng". Bấm Xong (Enter) để xem lại chữ đọc được ở từng vùng, rồi Lưu hoặc Lưu & bắt đầu. Lúc bấm Xong, app chụp một ảnh để đọc thử chữ và làm ảnh xem lại ở trang hồ sơ.

Trình chọn giành phím khi mở: Esc, Enter, Space không lọt sang app khác, và phím được trả về game khi đóng. Thanh hướng dẫn nằm dưới tai thỏ.

### Cài đặt

Các trang xếp thành bốn nhóm: Bắt đầu nhanh (Ngôn ngữ & game, Vùng), Tính năng (Phụ đề, Cửa sổ phụ đề, Giọng đọc, Nhân vật, Dịch màn hình), Bản dịch (Dịch vụ dịch, Văn phong & thuật ngữ) và Ứng dụng (Hồ sơ game, Phím tắt & tay cầm, Chung). Trang Nhân vật chỉ hiện khi chọn Dub. Từ dùng thống nhất: "vùng" (không dùng "khung"), "Cửa sổ phụ đề", "dịch vụ dịch".

Sáng / tối (`AppSettings.appearance`: system, light, dark; `AppAppearance.apply` đặt `NSApp.appearance`) nằm ở Cài đặt → Chung → Giao diện. Cửa sổ phụ đề và lớp dịch đè luôn tối.

Mọi chuỗi giao diện viết `L("Tiếng Việt", "English")` (`Localization.swift`). Ngôn ngữ giao diện chọn ở Cài đặt → Chung hoặc bước đầu của hướng dẫn, mặc định theo máy. Lời nhắc gửi AI và nhật ký không dịch. Chữ trong app, tài liệu và ghi chú phát hành tránh các dấu hiệu văn do AI viết theo danh sách [Wikipedia:Signs of AI writing](https://en.wikipedia.org/wiki/Wikipedia:Signs_of_AI_writing): không giọng quảng cáo, không in đậm dày đặc, không gạch ngang dài thay dấu câu, không emoji làm đầu dòng, dùng một từ cho một khái niệm ("dịch vụ dịch", không xen "engine").

### Biểu tượng thanh menu

`StatusMenu.swift` dựng bằng AppKit, menu dựng lại mỗi lần bấm. Khi app khác đang toàn màn hình, macOS nhận cú bấm nhưng không hiện menu của app kiểu thường (có biểu tượng ở Dock); app kiểu phụ trợ thì hiện được. Vì vậy lúc bấm, nếu thấy toàn màn hình thì app chuyển sang `.accessory`, chờ 0,12 giây, mở menu, đóng menu thì trả về `.regular`. Đổi kiểu ngay trong `menuWillOpen` là quá muộn. App coi là có app toàn màn hình khi một cửa sổ của app khác phủ hết bề ngang, chạm đáy và cao hơn 60% màn hình; Comet tách thanh công cụ thành cửa sổ riêng nên phần nội dung chỉ cao khoảng 84%.

### Ủng hộ

Cửa sổ Ủng hộ (`Donation.swift`, cửa sổ `donate`) mở từ link Ủng hộ ở chân cửa sổ chính, menu OverSub, thanh menu và Cài đặt → Chung. Cửa sổ có hai cột: trái là kênh, mức tiền và thông tin chuyển khoản, phải là mã QR. Chiều cao vừa nội dung nhưng không vượt màn hình dùng được (`visibleFrame`), thấp hơn thì cuộn, và tính lại khi đổi độ phân giải.

Có hai kênh: VietQR (mặc định khi giao diện tiếng Việt) và PayPal (`paypal.me/ngochieuit/<số>USD`, mặc định khi tiếng Anh). Mã VietQR dựng trên máy theo chuẩn EMVCo từ mã "Nhận tiền" của ví MoMo: thẻ 38 người nhận giữ nguyên, thêm thẻ 54 số tiền (điểm khởi tạo đổi 11 thành 12) và thẻ 62-08 nội dung, rồi tính lại CRC-16/CCITT-FALSE. Bỏ số tiền và nội dung thì ra đúng mã gốc (đã đối chiếu). Mã có icon ở giữa nên dùng mức sửa lỗi H; đã đọc lại bằng Vision từ ảnh chụp cửa sổ.

Nhiều app ngân hàng khoá ô nội dung (và số tiền) khi quét mã có sẵn hai thứ này, nên cửa sổ có ô Tên của bạn. Mã tự đổi nội dung thành "OverSub <tên>" (`Donation.message`: bỏ dấu, đ thành d, chỉ giữ chữ, số và khoảng trắng, gọn trong 25 ký tự). Tài liệu VietQR cho tối đa 50 ký tự không ký tự đặc biệt; chuẩn EMV gốc chặt hơn.

Bảng cảm ơn (`Supporters`) tải `Docs/supporters.json` từ nhánh `main` trên GitHub mỗi lần mở cửa sổ (chỉ tải về) và nhớ bản gần nhất. Thêm người ủng hộ: thêm `{"name": "…"}` lên đầu mảng `supporters`, thêm tên vào mục Bảng cảm ơn của hai README, commit và đẩy, không cần ra bản app mới. Chỉ ghi tên mà người ủng hộ tự ghi trong nội dung chuyển khoản hay lời nhắn PayPal.

Lời cảm ơn theo mốc (`SupportPrompt`) hiện ở dòng trạng thái khi số câu đã dịch (`statLinesTranslated`) vượt 300, 1.000, 3.000 hay 10.000. Mỗi mốc một lần (`supportMilestoneShown`), chỉ lúc không chơi; báo bản mới được ưu tiên hơn. Bấm "Mình đã ủng hộ rồi" (`supportDonated`) thì thôi hẳn, và có nút Hoàn tác nếu lỡ bấm. `.github/FUNDING.yml` tạo nút Sponsor trên GitHub.

Ghi chú phát hành không liệt kê thay đổi liên quan tới Ủng hộ trong mục Có gì mới; chỉ giữ mục "Ủng hộ · Support" cố định ở cuối.

## Hồ sơ game

Mỗi game một hồ sơ gồm cài đặt (vùng phụ đề, vùng dịch màn hình, ngôn ngữ, phụ đề, giọng đọc, dịch vụ dịch) và trí nhớ game (ngữ cảnh 30 câu, dàn diễn viên, thuật ngữ, danh sách bỏ qua, trí nhớ dịch).

Mọi thay đổi tự ghi vào hồ sơ đang dùng (`syncActiveProfile`, gom sau 0,6 giây), không có nút Lưu đè. Tạo mới lấy cài đặt hiện tại với trí nhớ trống; Nhân bản mang theo cả trí nhớ. Xoá hồ sơ cuối cùng thì app tạo lại hồ sơ "Mặc định" với cài đặt ban đầu. Mỗi hồ sơ có Khôi phục cài đặt ban đầu (giữ vùng và trí nhớ) và Xoá trí nhớ game.

App tự chuyển hồ sơ khi một game được đưa ra trước, theo bundle id của app đang hiện game; nhiều hồ sơ cùng app thì lấy hồ sơ dùng gần nhất. Game console chơi qua app xem capture card (OBS, VisionRelay) đều hiện qua cùng một app, nên phải chọn hồ sơ bằng tay.

## Điều khiển

Phím tắt toàn cục dùng được khi game toàn màn hình và không cần quyền Trợ năng. Tổ hợp người dùng đã đổi lưu ở khoá `hotkeys` (`KeyCombo`, `HotkeyCenter.setCombo`). Mọi nhãn phím trong giao diện lấy từ `HotkeyCenter.Action.<tên>.display`, không viết cứng.

Tay cầm (`GamepadControl`) dùng GameController, nhận nút cả khi game ở phía trước: giữ View/Share rồi bấm Y để đọc lại, X để bật tắt giọng đọc, B để ẩn hiện phụ đề.

## Ove (linh vật 3D)

Ove là đầu kính mờ có lõi cam, dựng bằng three.js ở `Tools/Ove/oversub-head.js` (cùng bộ dựng của prototype trên Claude
Design). App không chạy 3D: mọi trạng thái và biểu cảm được dựng sẵn thành tấm khung hình HEIC trong `Resources/Ove`,
`Ove.swift` lật khung bằng `contentsRect` của Core Animation.

- Bộ góc đầu `idle` và `live`: 9 hướng ngang × 5 hướng dọc, mỗi góc một khung mở mắt và một khung nhắm mắt. Từ 1.1.76
  Ove luôn nhìn thẳng (người dùng thấy quay đầu theo trạng thái là rối khi đã bỏ chuột): lúc nạp, app chỉ cắt hai khung
  nhìn thẳng (mở, nhắm) để chớp mắt rồi bỏ tấm lớn. Các góc khác giữ trong tấm để dùng sau.
- Vòng đọc `speak` (3 giây, khớp đầu đuôi), các đoạn `happy` (có khoảng giữ khi được vuốt ve), `sad`, `angry`, `dizzy`,
  `cry`, và `yawn`, `wake` riêng cho nền sáng, nền tối (mặt lúc ngủ xám khác nhau). Gợn sóng là một vòng ảnh
  `ripple-light`, `ripple-dark` được phóng và làm mờ bằng Core Animation.
- Mỗi khung dựng hai lần trên nền đen và nền trắng (nền chỉ dùng cho lượt khúc xạ của kính) rồi tách độ trong thật của kính,
  nên một khung dùng được trên cả nền sáng lẫn nền tối.
- Tương tác: bấm là bật tắt giọng đọc (ngáp rồi ngủ, tỉnh dậy; bấm thêm trong 1,6 giây bị bỏ qua). Tương tác chuột (nhìn
  theo, vuốt ve, rung, rê vòng) có ở bản thử 1.1.75 rồi bỏ theo yêu cầu người dùng; bộ hình biểu cảm vẫn giữ, móc thử gọi
  được.
- Lớp hình Ove tắt hoạt ảnh ngầm (`actions` của `contentsRect`, `contents`): thiếu nó thì mỗi lần đặt khung ngoài hoạt ảnh
  lật khung, Core Animation trượt ô cắt 0,25 giây qua tấm và Ove hiện thành mảnh ghép bốn khung.
- Đang phát tiếng thì Ove đọc và nền rực theo, kể cả khi nghe thử giọng lúc giọng đọc đang tắt; đi giữa ngủ và đọc thì mờ
  chuyển nhanh, ngáp và tỉnh dậy chỉ chạy khi bấm tắt, bật giọng đọc.
- Đo trên M1 Pro (Ove 128 điểm, cửa sổ hiện): đang đọc 0,3% một nhân, chờ khoảng 0,4%, bị che 0%; bộ nhớ cao nhất khoảng
  124 MB lúc chuyển trạng thái, lúc thường khoảng 46 MB (app chỉ giữ tấm đang chiếu và bộ góc đầu của mặt hiện tại).

Dựng lại bộ hình sau khi sửa `oversub-head.js` hay `export.html`:

```sh
python3 Tools/Ove/serve.py 8731          # phục vụ thư mục cha của Tools/Ove và nhận ảnh gửi về thư mục out/
open http://127.0.0.1:8731/Ove/export.html   # chạy trong trình duyệt có WebGL, xong thì trang ghi "Xong."
swift Tools/Ove/ove_pack.swift Tools/out  # nén sang HEIC, chép vào Resources/Ove kèm ove.json
```

## Công cụ tự kiểm tra

Các móc thử chỉ có trong bản dựng `OVERSUB_DEV=1 ./build.sh` (`DebugSnapshot.swift`), người dùng bình thường không bao giờ kích hoạt. Cách chạy: `open --env TÊN=giá-trị OverSub.app --args -onboardingDone YES`. Thử xong luôn mở lại app cho người dùng, vì mỗi lần thử phải tắt app đang chạy. Bài thử có ghi dữ liệu thì đặt `OVERSUB_CONTEXT_FILE` và `OVERSUB_MEMORY_DIR` vào thư mục tạm để không đụng dữ liệu thật.

| Biến môi trường | Làm gì |
|---|---|
| `OVERSUB_SNAPSHOT_DIR=<thư mục>` | Chụp cửa sổ chính (kể cả lúc đang chạy, đang đọc), lịch sử, Cửa sổ phụ đề các cỡ và từng trang Cài đặt. |
| `OVERSUB_SNAPSHOT_MAIN_ONLY=1` | Dừng sau các ảnh cửa sổ chính. |
| `OVERSUB_SNAPSHOT_SELECT=1` | Chụp thêm trình chọn vùng. |
| `OVERSUB_SNAPSHOT_DONATE=1`, `OVERSUB_SUPPORT_TEST=1`, `OVERSUB_DONATE_NICK=<tên>`, `OVERSUB_SCREEN_HEIGHT=560` | Chụp cửa sổ Ủng hộ, hiện lời cảm ơn theo mốc (không ghi cài đặt), điền sẵn tên, giả lập màn hình thấp. |
| `OVERSUB_APPEARANCE=light` hoặc `dark` | Ép giao diện sáng hoặc tối; thắng lựa chọn của người dùng. |
| `OVERSUB_ONBOARD=1` kèm `--args -onboardStep <0–4>` | Mở hướng dẫn lần đầu ở bước chỉ định để chụp. |
| `OVERSUB_PROG_TEST=1`, `cutscene`, `label`, `return`, `retalk`, `menu`, `emotion` | Thử chữ chạy và giọng đọc bằng đoạn hội thoại lấy từ nhật ký thật (dịch, đọc thật); xem kết quả trong nhật ký. `menu`: lướt menu → thoại → menu, mong đợi mọi nhãn ghi "Bỏ qua (lý do)". `emotion`: câu do dự, buồn, hét; hệ số × trong dòng "Lồng tiếng: đọc" không được dưới 1. |
| `OVERSUB_VISION_HANG=<n>` kèm `--args -resumeAfterRelaunch YES` | Lệnh Vision thứ n trở đi treo hẳn, như lần đo thực; app phải tự khởi động lại sau khoảng 12 giây và chạy tiếp. |
| `OVERSUB_VISION_SLOW_PREPARE=<giây>` | Mỗi lần chuẩn bị bộ nhận chữ chờ thêm từng ấy giây, để xem bảng "Đang chuẩn bị". Muốn thử như máy mới thật thì đổi tên tạm `~/Library/Caches/vn.imhillxtz.phude/com.apple.e5rt.e5bundlecache` (khoảng một phút). |
| `--args -visionAutoRestartAt "<date>...Z</date>"` | Giả như vừa tự khởi động lại; đi cùng `OVERSUB_VISION_HANG` để thử hộp thoại "vẫn không phản hồi". Tham số kiểu bool viết `"<false/>"`, viết `NO` thì không đọc được. |
| `OVERSUB_FAKE_NO_SCREEN_PERMISSION=1` | Coi như thiếu quyền Ghi màn hình, không cần gỡ quyền thật. |
| `OVERSUB_PERMISSION_DOCK_TEST=1` | Hiện hướng dẫn cấp quyền, bấm Mở Cài đặt hệ thống (chỉ mở trang xem), ghi khung thẻ thu gọn và khung Cài đặt vào nhật ký. |
| `OVERSUB_SNAPSHOT_NOTICES=1` | Chụp bảng đang chuẩn bị, đã sẵn sàng, hộp thoại "vẫn không phản hồi" và hướng dẫn cấp quyền. |
| `OVERSUB_REPORT_TEST=1` | Chỉ tạo gói báo lỗi và ghi đường dẫn, thời gian vào nhật ký. `=show` thêm cửa sổ Gửi báo lỗi và chụp vào `OVERSUB_SHOT_DIR`; `=issue` thêm bước mở trang Issue điền sẵn trong trình duyệt và chụp thẻ thu gọn (không bấm gửi). |
| `OVERSUB_LOG_ROTATE_TEST=<số dòng>` kèm `OVERSUB_LOG_ROTATE_BYTES=<byte>`, `OVERSUB_LOG_DIR=<thư mục>` | Ghi liền từng ấy dòng đánh số với ngưỡng xoay nhỏ, vào thư mục tạm để không đụng nhật ký thật (xoay ngay trên nhật ký thật sẽ đè mất `debug.1.log` của các buổi chơi trước). Đạt khi `debug.1.log` không vượt ngưỡng quá một dòng và số dòng ở cuối `debug.1.log` nối liền đầu `debug.log`. Thêm `OVERSUB_REPORT_TEST=1` để xem gói báo lỗi có kèm `debug.1.log`. `OVERSUB_LOG_ROTATE_BYTES` và `OVERSUB_LOG_DIR` dùng được với mọi bài thử khác. |
| `OVERSUB_UPDATE_PROMPT_TEST=1` | Như bấm Kiểm tra cập nhật… ở menu, dùng `OVERSUB_UPDATE_FEED` (và `OVERSUB_UPDATE_LIST` dạng danh sách bản phát hành); chụp hộp thoại vào `OVERSUB_SHOT_DIR`. |
| `OVERSUB_SHOT_DIR=<thư mục>` | Nơi các móc thử mới lưu ảnh chụp, không kéo theo lượt chụp toàn bộ giao diện như `OVERSUB_SNAPSHOT_DIR`. |
| `OVERSUB_OVE_TEST=1` (kèm `OVERSUB_SHOT_DIR`) | Thử Ove: chờ, tắt giọng đọc (ngáp rồi ngủ), bật lại (tỉnh dậy), nghe, đang đọc kèm bong bóng thoại, rồi vui, buồn, giận, chóng mặt và khóc; mỗi bước chụp cửa sổ chính, xong trả công tắc giọng đọc như cũ. `OVERSUB_OVE_HOLD=<giây>` giữ trạng thái chờ và đang đọc lâu hơn để đo CPU. Cửa sổ phải lộ ra: bị che thì Ove dừng hoạt ảnh (đúng thiết kế) và ảnh biểu cảm sẽ đứng yên. |
| `OVERSUB_REGION_STATE=<phụ đề>,<số vùng dịch>` | Đổi tên các nút vùng như khi có hoặc chưa có vùng (ví dụ `0,0`, `1,2`, `1,3`) để chụp, không đụng vùng thật. |
| `OVERSUB_DUB_TEST=1`, `voiceover`, `gemini` | Thử ba đường phát giọng, một câu Voice-over, một câu Gemini (tốn một lượt). |
| `OVERSUB_SCENE_TEST=1` | Chạy trọn quy trình dịch màn hình trên cảnh menu vẽ sẵn, lưu ảnh trước và sau. |
| `OVERSUB_QUICK_TEST=x,y,w,h` (kèm `OVERSUB_QUICK_TEXT=1`) | Mở Dịch nhanh trên vùng chỉ định và chụp kết quả. |
| `OVERSUB_MENU_TEST=<tên app toàn màn hình>` | Bấm biểu tượng thanh menu bằng mã khi app khác toàn màn hình, rồi chụp. |
| `OVERSUB_FRONT_TEST=<giây>` | Ghi mỗi giây app có quét hay không, đang chọn app nào. |
| `OVERSUB_HIDE_TEST=<giây>` | Ẩn app sau số giây đó, để đo CPU lúc bị ẩn. |
| `OVERSUB_SCREEN_RECT=x,y,w,h` | Chụp một vùng màn hình của app khác, ví dụ cửa sổ cài đặt .dmg trong Finder. |
| `OVERSUB_UPDATE_TEST=1` | Thử tải và cài bản cập nhật từ feed cục bộ (xem phần Phát hành). |
| `OVERSUB_PLAY_TEST=pattern` hoặc `pattern-full` | Mở màn hình chơi với nguồn hình dựng sẵn (thang xám độ sáng biết trước, ba ô màu, một dòng phụ đề), dải giới hạn hoặc dải đầy đủ trong khung ghi giới hạn. Đo màu từng ô theo từng cách hiểu dải sáng, đọc phụ đề qua đúng đường chụp của vòng quét (cả khi cửa sổ khác của OverSub che lên), thu nhỏ, đổi cỡ và đo viền đen, bật từng tuỳ chọn xử lý hình, thử Lấp đầy ở cửa sổ rất rộng (viền trái phải bằng 0), giữ mở 12 giây, đóng, chờ 12 giây. `OVERSUB_PLAY_PATTERN_FORMAT=2vuy` hoặc `yuvs` thử đường đọc 4:2:2; `OVERSUB_PLAY_FULLSCREEN=1` thử thêm toàn màn hình. Tuỳ chọn ghi vào miền riêng `vn.imhillxtz.phude.playtest`. |
| `OVERSUB_PLAY_TEST=device` | Như trên với capture card thật đang cắm: chờ hình (lần đầu macOS hỏi quyền Camera, Micrô), chụp theo ba cách hiểu dải sáng, giả lập rút rồi cắm lại card. `OVERSUB_PLAY_SETTLE=<giây>` chờ máy console lên hình, `OVERSUB_PLAY_NO_AUDIO=1` bỏ tiếng, `OVERSUB_PLAY_EFFECTS_UI=1` mở bảng Hiệu ứng video và chờ tắt Reactions. |
| `OVERSUB_PLAY_TEST=motion` kèm `OVERSUB_PLAY_PATTERN_MOTION=60` hoặc `30` | Nguồn thử có hình vuông chạy (đổi chỗ mỗi khung, hoặc mỗi hai khung như game 30 khung/giây); lần lượt các bộ chỉnh hình, mỗi bộ 11 giây; ghi CPU của tiến trình, thời gian GPU, các bước xử lý và số khung hiện mỗi giây (dòng "xử lý hình" 10 giây một lần), chụp từng bộ. Bài thử pattern cũng chạy từng bộ và đo màu thang xám. |
| `OVERSUB_PLAY_TEST=menu` | Nguồn thử với bộ Mịn cạnh, chờ 9 giây cho bộ vẽ đo GPU, rồi ghi mọi dòng của menu tuỳ chọn trong cửa sổ (cả menu con, dấu ✓ ở mục đang chọn) ra nhật ký, để kiểm số trễ thêm và các đánh đổi. Thêm `OVERSUB_PLAY_HOLD=<giây>` để giữ cửa sổ mở mà thử bằng tay (kéo cửa sổ: dòng "di chuyển xong"). `OVERSUB_PLAY_PATTERN_FPS=30` cho nguồn thử chạy 30 khung/giây như chế độ 1440p30 của card, dùng được với mọi bài thử có nguồn thử. |
| `OVERSUB_PLAY_TEST=hold` kèm `OVERSUB_PLAY_FULLSCREEN=1`, `OVERSUB_PLAY_PRESETS=original,game3D,…` | Mở bằng card thật, toàn màn hình như lúc chơi, giữ từng bộ chỉnh hình `OVERSUB_PLAY_HOLD` giây; dòng nhật ký 10 giây cho nhịp card, thời gian chờ drawable, GPU cả máy. Dùng để tìm nguyên nhân tụt khung. |
| `OVERSUB_PLAY_TEST=hold` | Chỉ mở card thật, chờ hình, giữ mở `OVERSUB_PLAY_HOLD` giây (mặc định 30) rồi đóng, không đổi cỡ hay chụp; dùng để đo CPU. `OVERSUB_PLAY_PATH=avf` ép hình đi qua `AVCaptureSession` như bản 1.1.68 để so hai đường. `OVERSUB_PLAY_RANGE_DUMP=<thư mục>` ghi mọi mẫu độ sáng của bộ dò dải sáng ra tệp `range-*.bin` (mỗi mẫu: số giây kiểu Double rồi 64×36 byte), để thử lại luật dò trên số liệu card thật mà không phải mở card. |
| `OVERSUB_PLAY_TEST=ui` | Chụp chân cửa sổ chính (cỡ thường và nhỏ nhất), lời báo trong cửa sổ ở mọi trạng thái, thanh điều khiển, hai hướng dẫn cấp quyền và trang Cài đặt › Màn hình chơi game. |
| `OVERSUB_PLAY_DEVICE=facetime` | Coi camera FaceTime là capture card, chỉ để thử đường ống khi không có card. Bản thử chạy với cờ này sẽ báo camera ở chân cửa sổ chính; thử xong phải mở lại app bình thường. |
| `OVERSUB_PLAY_FAKE_DENIED=camera` hoặc `microphone` | Coi như bị từ chối quyền đó. |

Người dùng bật Stage Manager: cửa sổ nằm ở dải bên thì ảnh chụp bị méo phối cảnh, nên móc chụp tự đưa cửa sổ lên trước.

Nhật ký `~/Library/Logs/OverSub/debug.log` là cách nhanh nhất để tìm lỗi người dùng gặp khi chơi. Với lỗi lặp lại nhiều lần, nên rà toàn bộ nhật ký nhiều buổi chơi bằng script đo số liệu thay vì chỉ xem đoạn vừa xảy ra; lỗi "không nhận thoại" chỉ tìm ra gốc theo cách đó.

Khi `debug.log` quá 2 MB, app đổi tên nó thành `debug.1.log` (đè bản cũ) rồi ghi tệp mới, nên lúc nào cũng còn một tệp trước đó, tổng cộng khoảng 4 MB. Bản 1.1.73 trở về trước xoá hẳn nội dung cũ: ngày 09/10/2026 đang điều tra lỗi tụt khung thì mất nhật ký trước 08:22. Rà nhiều buổi chơi thì đọc cả hai tệp theo thứ tự `debug.1.log` rồi `debug.log`; gói Gửi báo lỗi cũng kèm cả hai.

## Ghi chú SwiftUI

Không dùng `@State` hay `@Observable`, vì Command Line Tools thiếu plugin macro của SwiftUI; dùng `ObservableObject`.

App không quan sát trực tiếp `Engine` hay `AppSettings` ở cấp `App` hoặc `Commands`, và các binding của sheet, inspector đi qua `.deduplicated`. `@Published` báo thay đổi cả khi gán lại giá trị cũ; không lọc thì SwiftUI dựng lại danh sách scene lặp vô hạn tới tràn stack lúc mở app.

## Dữ liệu và đường dẫn

| Thứ | Ở đâu |
|---|---|
| Key API | `~/Library/Application Support/OverSub/keys.json` (quyền 0600) |
| Hồ sơ, ngữ cảnh, trí nhớ dịch | `~/Library/Application Support/OverSub` |
| Nhật ký chẩn đoán | `~/Library/Logs/OverSub/debug.log`, quá 2 MB thì chuyển sang `debug.1.log` (giữ một tệp trước đó) |
| Nhật ký cập nhật | `~/Library/Logs/OverSub/update.log` |
| Khoá ký bản phát hành | `~/Library/Application Support/OverSub Release/update-signing.key` (ngoài kho mã) |

Dữ liệu từ tên cũ PhuDeDich được tự chuyển sang thư mục OverSub ở lần mở đầu tiên.
