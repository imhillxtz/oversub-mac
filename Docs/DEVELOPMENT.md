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

## Dịch màn hình và Dịch nhanh

Dịch màn hình (⌃⌥T) dịch tại chỗ chữ ngoài lời thoại như bảng nhiệm vụ, menu, mô tả vật phẩm. Nó không đọc to và không vào Cửa sổ phụ đề hay lịch sử. Tối đa 3 vùng, lưu theo hồ sơ game.

Mỗi vùng được chia thành cụm chữ (`ScreenText.blocks`): mục menu, nút, đoạn mô tả, với các dòng xuống hàng của cùng một đoạn được gộp. Chữ gốc bị xoá bằng cách dựng lại nền từ điểm ảnh xung quanh (`Inpaint`, khoảng 10 ms), cắt theo từng mảng với mép làm mềm. Chữ dịch cùng màu chữ gốc, cỡ ước theo bề ngang dòng gốc (`ScreenText.fontSize`), độ đậm theo độ dày nét; các mục cùng cột hay cùng hàng có cỡ gần nhau thì dùng chung một cỡ. Câu dịch dài hơn được nén ngang tới 0,88 trước khi phải giảm cỡ chữ.

App dịch mọi cụm còn thiếu trong một lần gọi AI (`TranslationHub.translateUI`, lời nhắc riêng cho chữ giao diện, đánh số từng dòng), Groq trước, thường dưới 0,6 giây, chia lô 12 dòng, lỗi thì thử lại sau 3 giây. AI trả "=" cho dòng không cần dịch (tên riêng, Menu, ký hiệu nút); bản dịch trùng chữ gốc thì không thay. Dòng có số được lưu thành mẫu ("Gold {0}"), số đổi thì điền lại mà không gọi AI. Chữ rất ngắn được nhớ trong phiên. Ba chế độ tốc độ (`ScreenSpeed`): Tức thì (Dịch máy Apple), Tức thì rồi chuốt bằng AI (mặc định), Chờ bản AI. Thiếu gói Dịch máy Apple thì dùng AI, và trang Dịch màn hình có nút tải gói.

App nhận biết chữ đổi bằng dấu hiệu chữ (`OCR.screenSignature`) và độ giống `TextUtil.dice`, không so điểm ảnh, nên hiệu ứng động không làm bản dịch chớp. Chữ sáng thì được đọc nhanh trên ảnh tách riêng chữ sáng, nên cảnh phía sau chuyển động khi nhân vật đi lại cũng không sao; không có chữ sáng thì đọc trên ảnh gốc và bỏ mẩu rác dưới 3 chữ cái. Đang hiện bản dịch thì app quét 0,2 giây một lần: hết chữ hay chữ khác hẳn thì gỡ ngay (tắt dần 0,08 giây), hơi khác thì chờ thêm một lần quét. Chữ không đổi mà vệt chọn di chuyển thì chỉ dựng lại nền và màu chữ. `ScreenText.cleanRange` bỏ ký tự rác do đọc nhầm biểu tượng ở hai đầu dòng. Phụ đề đang chạy thì dịch màn hình bỏ qua chữ nằm trong vùng phụ đề, để không có hai lớp bản dịch đè nhau.

Dịch nhanh (`QuickTranslate.swift`, ⌃⌥Q, không cần bấm Bắt đầu) mở lớp chọn toàn màn hình; kéo một khung, thả chuột là dịch tại chỗ bằng cùng quy trình với dịch màn hình. Vùng chỉ dùng một lần. Mặc định dừng hình lúc chọn và lúc đọc. Dưới vùng có ba nút biểu tượng: xem dạng chữ, chép chữ gốc, đóng; hộp dạng chữ có nút chép bản dịch. ⌘C chép chữ gốc, ⇧⌘C chép bản dịch, Esc hoặc bấm ra ngoài để tắt.

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

`RegionEditor` là trình chọn dùng chung cho hai nút trên thanh công cụ. Chọn vùng phụ đề (⌘K, ⌃⌥K) vẽ lại vùng phụ đề, có nút Tự tìm phụ đề. Thêm vùng dịch thêm vùng dịch màn hình, tối đa 3. Trình chọn mở ra là hình trực tiếp; bấm Dừng hình (hoặc Space) để chọn trên ảnh đứng yên, lúc đó nút tô cam, viền màn hình cam và dòng hướng dẫn ghi "Hình đang dừng". Bấm Xong (Enter) để xem lại chữ đọc được ở từng vùng, rồi Lưu hoặc Lưu & bắt đầu. Lúc bấm Xong, app chụp một ảnh để đọc thử chữ và làm ảnh xem lại ở trang hồ sơ.

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
| `OVERSUB_PROG_TEST=1`, `cutscene`, `label`, `return`, `retalk` | Thử chữ chạy và giọng đọc bằng đoạn hội thoại lấy từ nhật ký thật (dịch, đọc thật); xem kết quả trong nhật ký. |
| `OVERSUB_DUB_TEST=1`, `voiceover`, `gemini` | Thử ba đường phát giọng, một câu Voice-over, một câu Gemini (tốn một lượt). |
| `OVERSUB_SCENE_TEST=1` | Chạy trọn quy trình dịch màn hình trên cảnh menu vẽ sẵn, lưu ảnh trước và sau. |
| `OVERSUB_QUICK_TEST=x,y,w,h` (kèm `OVERSUB_QUICK_TEXT=1`) | Mở Dịch nhanh trên vùng chỉ định và chụp kết quả. |
| `OVERSUB_MENU_TEST=<tên app toàn màn hình>` | Bấm biểu tượng thanh menu bằng mã khi app khác toàn màn hình, rồi chụp. |
| `OVERSUB_FRONT_TEST=<giây>` | Ghi mỗi giây app có quét hay không, đang chọn app nào. |
| `OVERSUB_HIDE_TEST=<giây>` | Ẩn app sau số giây đó, để đo CPU lúc bị ẩn. |
| `OVERSUB_SCREEN_RECT=x,y,w,h` | Chụp một vùng màn hình của app khác, ví dụ cửa sổ cài đặt .dmg trong Finder. |
| `OVERSUB_UPDATE_TEST=1` | Thử tải và cài bản cập nhật từ feed cục bộ (xem phần Phát hành). |

Người dùng bật Stage Manager: cửa sổ nằm ở dải bên thì ảnh chụp bị méo phối cảnh, nên móc chụp tự đưa cửa sổ lên trước.

Nhật ký `~/Library/Logs/OverSub/debug.log` là cách nhanh nhất để tìm lỗi người dùng gặp khi chơi. Với lỗi lặp lại nhiều lần, nên rà toàn bộ nhật ký nhiều buổi chơi bằng script đo số liệu thay vì chỉ xem đoạn vừa xảy ra; lỗi "không nhận thoại" chỉ tìm ra gốc theo cách đó.

## Ghi chú SwiftUI

Không dùng `@State` hay `@Observable`, vì Command Line Tools thiếu plugin macro của SwiftUI; dùng `ObservableObject`.

App không quan sát trực tiếp `Engine` hay `AppSettings` ở cấp `App` hoặc `Commands`, và các binding của sheet, inspector đi qua `.deduplicated`. `@Published` báo thay đổi cả khi gán lại giá trị cũ; không lọc thì SwiftUI dựng lại danh sách scene lặp vô hạn tới tràn stack lúc mở app.

## Dữ liệu và đường dẫn

| Thứ | Ở đâu |
|---|---|
| Key API | `~/Library/Application Support/OverSub/keys.json` (quyền 0600) |
| Hồ sơ, ngữ cảnh, trí nhớ dịch | `~/Library/Application Support/OverSub` |
| Nhật ký chẩn đoán | `~/Library/Logs/OverSub/debug.log` (tự xoá khi quá 2 MB) |
| Nhật ký cập nhật | `~/Library/Logs/OverSub/update.log` |
| Khoá ký bản phát hành | `~/Library/Application Support/OverSub Release/update-signing.key` (ngoài kho mã) |

Dữ liệu từ tên cũ PhuDeDich được tự chuyển sang thư mục OverSub ở lần mở đầu tiên.
