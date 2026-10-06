# OverSub · Ghi chú phát triển

> Tài liệu kỹ thuật cho tác giả và người được tác giả cho phép làm việc trên mã nguồn: cách dựng, các công cụ tự kiểm tra, cơ chế bên trong và những bài học đo được khi làm. Giới thiệu và hướng dẫn sử dụng ở [README](../README.md).

App macOS (cần macOS 26 trở lên) dịch và thuyết minh phụ đề game ngay trên màn hình. OverSub chụp vùng phụ đề, nhận diện chữ bằng Vision ngay trên máy, dịch bằng dịch vụ bạn chọn (Gemini, Groq, Cerebras, Mistral, OpenRouter, dịch vụ trả phí kiểu OpenAI, hoặc hai engine của Apple chạy trên máy), hiện bản dịch đè lên phụ đề gốc (cùng vị trí, màu, căn lề) và đọc to bằng giọng Siri. Ngoài lời thoại, app còn dịch tại chỗ chữ giao diện (Dịch màn hình) và dịch nhanh một vùng bất kỳ bằng phím tắt (Dịch nhanh).

Dịch sang 12 ngôn ngữ: tiếng Việt (mặc định, có bộ lời nhắc riêng đã tinh chỉnh về xưng hô và văn phong), English, 简体中文, 日本語, 한국어, ไทย, Bahasa Indonesia, Español, Français, Deutsch, Português (BR), Русский. Các ngôn ngữ khác tiếng Việt dùng bộ lời nhắc tiếng Anh chung, nên trải nghiệm tiếng Việt không bị ảnh hưởng.

## Build và chạy

    ./build.sh && open OverSub.app

Bản để chia sẻ: `./package.sh` tạo `dist/OverSub-<phiên bản>.dmg` và tự tăng số phiên bản. Bản để phát triển (kèm công cụ tự kiểm tra): `OVERSUB_DEV=1 ./build.sh`.

Chỉ cần Command Line Tools, không cần Xcode. Bundle id vẫn là `vn.imhillxtz.phude` để giữ quyền Ghi màn hình và cài đặt từ bản Phụ Đề Dịch cũ.

## Dùng

Lần đầu mở app có hướng dẫn 5 bước: cấp quyền Ghi màn hình, chọn ngôn ngữ, chọn tính năng, cài giọng Siri (có bảng hướng dẫn từng bước đi kèm System Settings), chọn vùng. Không có key vẫn dùng được Dịch máy Apple và Apple Intelligence.

Phím tắt toàn cục (dùng được khi game toàn màn hình, không cần quyền Trợ năng). Đây là tổ hợp mặc định; đổi được ở Cài đặt → Phím tắt & tay cầm (bấm vào ô phím tắt rồi gõ tổ hợp mới):

| Phím | Việc |
|---|---|
| ⌃⌥S | Bắt đầu hoặc dừng |
| ⌃⌥K | Chọn vùng phụ đề |
| ⌃⌥H | Ẩn hoặc hiện phụ đề đè lên |
| ⌃⌥D | Bật hoặc tắt giọng đọc |
| ⌃⌥R | Đọc lại câu vừa rồi |
| ⌃⌥T | Bật hoặc tắt dịch màn hình |
| ⌃⌥Q | Dịch nhanh một vùng |
| ⌃⌥L | Lịch sử thoại |

Trong cửa sổ app còn có ⌘R, ⌘K, ⌘J, ⌘E, ⇧⌘H, ⇧⌘D, ⇧⌘T, ⌘L. Biểu tượng tay cầm trên thanh menu điều khiển được mọi thứ mà không cần mở cửa sổ.

## Giao diện

- **Cửa sổ chính, Sub & giọng đọc:** hai nút lớn ngang nhau: **Phụ đề** (đè lên game, ⌃⌥H) và **Voice-over** / **Dub** (giọng đọc, ⌃⌥D). Câu đang đọc hiện như phụ đề trên game (nền tối) và sáng dần theo giọng (Siri báo từng từ qua `willSpeakWord` khi đọc thẳng; đọc qua bộ đệm thì ước theo thời lượng). Nút Đọc lại (⌃⌥R). Bảng âm thanh thu gọn được: âm lượng, nghe thử, tốc độ, loa phát, giảm tiếng game. Hàng chip phía dưới: engine, ngôn ngữ dịch, nội dung, thể loại, cỡ chữ.
- **Cửa sổ phụ đề** (⌘J): cửa sổ nổi riêng chỉ có phụ đề lời thoại (sáng dần theo giọng). Rê chuột mới hiện nút, nút nổi đè lên chữ nên không tốn chỗ; mép trái có nút Bắt đầu / Dừng cả phiên (kính xám khi đang dừng, cam khi đang chạy) và nút Bỏ qua câu này, đặt xa nút đóng để khỏi bấm nhầm. Nút Bỏ qua câu này ở mọi nơi dùng biểu tượng chữ có dấu × (`text.badge.xmark`), thay cho con mắt gạch chéo dễ bị hiểu là ẩn phụ đề. Kéo thấp xuống hoặc bấm "Một dòng" thì còn một dải chữ mỏng (tên nhân vật đứng trước câu, cùng cỡ chữ; câu dài thì cả dòng cùng co cho vừa) để không che thông tin game khi chơi trên một màn hình. Mở lên là ghim sẵn: nổi trên cùng, kể cả trên Dock (vẫn dưới thanh menu), và theo sang mọi Space, kể cả Space của game toàn màn hình. Trước bản 1.1.38 cửa sổ chưa ghim kéo xuống sát đáy thì bị Dock che, không lấy lên được; giờ bỏ ghim mà đang ở vùng Dock thì tự đẩy lên, nằm ngoài mọi màn hình thì về chỗ mặc định. Chỉnh nền: kính mờ (0% là trong suốt hẳn, chữ có bóng) và độ tối, ở nút trên cửa sổ hoặc Cài đặt → Phụ đề. Thoát app khi Cửa sổ phụ đề đang mở thì lần sau tự mở lại đúng chỗ cũ.
- **Chụp màn hình** (`ScreenGrabber`): loại trừ cả ứng dụng OverSub (không liệt kê từng cửa sổ), để lớp bản dịch vừa hiện lại hay vừa tạo không lọt vào ảnh rồi bị đọc lại. Cỡ chữ phụ đề đè lên ước theo bề ngang dòng (`TextFit.fontSize`) và lấy trung vị 9 câu gần nhất, không nhảy to nhỏ.
- **Ba tính năng bật/tắt độc lập** (ba nút tròn ở cửa sổ chính): Phụ đề (⌃⌥H), Voice-over/Dub (⌃⌥D), Dịch màn hình (⌃⌥T, `screenTranslateEnabled`). **Bắt đầu / Dừng** (⌘R, ⌃⌥S) chạy cả phiên: phụ đề nếu có khung phụ đề, dịch màn hình nếu đang bật và có vùng; đang chạy mà bật/tắt nút tròn thì có tác dụng ngay. Vùng phụ đề và vùng dịch màn hình chồng nhau thì ưu tiên phụ đề.
- **Cài đặt**: Tính năng (Phụ đề: nội dung, cách bắt thoại, phụ đề đè lên, Cửa sổ phụ đề · Giọng đọc · Dàn diễn viên · Dịch màn hình: bật, tốc độ) · Dịch (Engine, Chất lượng) · Quét (Vùng chọn: nơi duy nhất xem và sửa vùng, có ảnh xem trước mọi vùng) · Chung. Trang tính năng chỉ có một dòng tóm tắt vùng kèm đường dẫn sang Vùng chọn.
- **Chọn vùng** (`RegionEditor`): một trình chọn dùng chung cho hai nút ngang hàng trên thanh công cụ. "Chọn vùng phụ đề" (⌘K, ⌃⌥K): kéo chỗ trống để vẽ lại khung phụ đề, có nút Tự tìm phụ đề và nút + Dịch màn hình để thêm một vùng. "Thêm dịch màn hình": kéo chỗ trống là thêm vùng dịch màn hình (tối đa 3), nút "Thêm vùng · n/3". Mở ra là xem trực tiếp; bấm Dừng hình (hoặc Space) để chọn trên ảnh đứng yên, lúc đó nút tô cam, viền màn hình cam và dòng hướng dẫn ghi "Hình đang dừng". Kéo vùng để di chuyển, kéo góc để chỉnh, × hoặc Delete để xoá vùng dịch màn hình. Bấm Xong (Enter) để xem lại chữ đọc được ở mọi vùng (mỗi vùng một ô), rồi Lưu hoặc Lưu & bắt đầu (bắt đầu đúng phần vừa chọn: phụ đề hoặc dịch màn hình). Lúc bấm Xong app chụp một ảnh để đọc thử chữ và làm ảnh xem lại ở trang hồ sơ. Trình chọn giành phím khi mở (Esc, Enter, Space không lọt sang app khác) và trả phím về game khi đóng; thanh hướng dẫn nằm dưới tai thỏ.
- **Cài đặt** (⌘,): Sub & giọng đọc (Phụ đề, Giọng đọc, Dàn diễn viên), Dịch, Quét, Chung (Hồ sơ game, Phím tắt & thanh menu, Giới thiệu).

## Hồ sơ game

Mỗi game một hồ sơ: cài đặt (khung phụ đề, vùng dịch màn hình, ngôn ngữ, phụ đề, giọng đọc, engine) và trí nhớ game (ngữ cảnh 30 câu, dàn diễn viên, thuật ngữ, danh sách bỏ qua, bộ nhớ dịch).

- **Tự lưu:** mọi thay đổi ghi vào hồ sơ đang dùng (`syncActiveProfile`, gom sau 0,6 giây); không còn Lưu đè.
- **Tạo mới** = cài đặt hiện tại, trí nhớ trống. **Nhân bản** = mang theo cả trí nhớ.
- Hồ sơ đầu tiên là hồ sơ bình thường; xoá hồ sơ cuối cùng thì tạo lại hồ sơ "Mặc định" cài đặt ban đầu. Mỗi hồ sơ có Khôi phục cài đặt ban đầu (giữ khung và trí nhớ) và Xoá trí nhớ game.
- **Tự chuyển hồ sơ** khi một game được đưa ra phía trước (theo bundle id của app đang hiện game; nhiều hồ sơ cùng app thì lấy hồ sơ dùng gần nhất). OverSub dùng cho mọi game trên màn hình Mac; game console chơi qua app xem capture card (OBS, VisionRelay) thì đều hiện qua cùng một app nên phải chọn hồ sơ tay.

## Tốc độ và hiệu năng

- **Bộ nhớ dịch** (`TranslationMemory`): câu đã dịch lưu theo hồ sơ và ngôn ngữ dịch (tối đa 4.000 câu), gặp lại thì dùng ngay, không gọi API.
- **Dịch theo luồng:** Gemini và Groq trả chữ dần (SSE); phụ đề hiện dần, câu trọn đầu tiên được đọc ngay. Engine đầu đã ra chữ thì không gửi engine dự phòng; chỉ hiện chữ của một engine.
- **Hiện tạm bản Dịch máy Apple** khi AI chưa trả lời sau 0,25 giây; giọng đọc chờ bản AI.
- **Gửi song song** khi engine đầu chậm quá 1 giây hoặc lỗi sớm (`Hedge`).
- **Đọc nhanh trước khi đọc kỹ:** Vision chế độ fast (khoảng 14 ms) xem chữ có đổi không, chỉ đọc kỹ (khoảng 120 ms) khi khác; cảnh nền chuyển động không làm đọc lại liên tục.
- **Dịch màn hình** (⌃⌥T, trang Cài đặt riêng): dịch tại chỗ chữ ngoài lời thoại (bảng nhiệm vụ, menu, mô tả vật phẩm), không đọc to, không vào Cửa sổ phụ đề hay lịch sử. Mỗi vùng được chia thành cụm chữ (`ScreenText.blocks`: mục menu, nút, đoạn mô tả; dòng xuống hàng của cùng một đoạn được gộp). Mỗi cụm được thay ngay trên nền game: chữ gốc bị xoá bằng cách dựng lại nền từ điểm ảnh xung quanh (`Inpaint`, khoảng 10 ms), cắt theo từng mảng với mép làm mềm; chữ dịch cùng màu chữ gốc, cỡ chữ ước theo bề ngang dòng gốc (`ScreenText.fontSize`), độ đậm theo độ dày nét; các mục cùng cột hoặc cùng hàng có cỡ gần nhau dùng chung một cỡ; chữ luôn nằm trong khung. Dịch mọi cụm còn thiếu trong một lần gọi AI (`TranslationHub.translateUI`, lời nhắc riêng cho chữ giao diện, đánh số từng dòng; Groq trước, thường dưới 0,6 giây). Nhận biết chữ đổi bằng dấu hiệu chữ (`OCR.screenSignature`: chữ sáng thì đọc nhanh trên ảnh tách chữ sáng, chịu được cảnh phía sau đang chạy khi nhân vật di chuyển; không có chữ sáng thì đọc nhanh trên ảnh gốc, bỏ mẩu rác dưới 3 chữ cái), so độ giống `TextUtil.dice`, không theo điểm ảnh, nên hiệu ứng động không làm chớp. Đang hiện bản dịch thì quét 0,2 giây một lần: hết chữ hoặc chữ khác hẳn thì gỡ ngay (tắt dần 0,08 giây), hơi khác thì chờ thêm một lần quét; chữ không đổi mà vệt chọn di chuyển (màu viền quanh cụm đổi) thì chỉ dựng lại nền và màu chữ. Bỏ ký tự rác do đọc nhầm biểu tượng ở hai đầu dòng (`ScreenText.cleanRange`, lấy đúng khung phần chữ thật từ Vision); AI trả "=" cho dòng không cần dịch (tên riêng, amiibo, Menu, ký hiệu nút) và bản dịch trùng chữ gốc thì không thay. Câu dịch dài hơn thì nén ngang nhẹ (tới 0,88) trước khi giảm cỡ chữ. Phụ đề đang chạy thì dịch màn hình bỏ qua chữ nằm trong khung phụ đề, để không có hai lớp bản dịch đè nhau. Ba chế độ tốc độ (`ScreenSpeed`): Tức thì (Dịch máy Apple), Tức thì rồi chuốt bằng AI (mặc định), Chờ bản AI; trí nhớ dịch có sẵn thì hiện ngay. Thiếu gói Dịch máy Apple thì dùng AI thay, trang Dịch màn hình có nút Tải gói dịch. Vùng lưu theo hồ sơ game (khoá cũ `secondaryRegions`). Thử không cần game: `OVERSUB_SCENE_TEST=1 OVERSUB_SNAPSHOT_DIR=…` vẽ ba cảnh menu, chạy trọn quy trình và lưu ảnh trước/sau.
- **Dịch nhanh** (`QuickTranslate.swift`, ⌃⌥Q, không cần bấm Bắt đầu): hiện lớp chọn toàn màn hình, kéo một khung, thả chuột là dịch ngay tại chỗ bằng cùng quy trình với dịch màn hình; vùng dùng một lần, không lưu. Mặc định dừng hình lúc chọn và lúc đọc (tắt được ở Cài đặt → Dịch màn hình). Dưới vùng có ba nút biểu tượng: xem dạng chữ, chép chữ gốc, đóng; hộp dạng chữ có nút chép bản dịch. ⌘C chép chữ gốc (để tra cứu), ⇧⌘C chép bản dịch, Esc hoặc bấm ra ngoài để tắt. Thử không cần game: `OVERSUB_QUICK_TEST=x,y,w,h` (thêm `OVERSUB_QUICK_TEXT=1` để mở sẵn hộp dạng chữ).
- Bỏ qua chữ đã là ngôn ngữ đích (`TextUtil.isAlreadyTarget`, NaturalLanguage) và nhãn tên rác.

## Điều khiển

Phím tắt toàn cục: xem bảng ở phần Dùng. Tổ hợp người dùng đã đổi lưu ở khoá `hotkeys` (`KeyCombo`, `HotkeyCenter.setCombo`); mọi nhãn phím trong giao diện lấy từ `HotkeyCenter.Action.<tên>.display`, không viết cứng. Tay cầm (`GamepadControl`, GameController nhận nút cả khi game ở phía trước): giữ View/Share + Y đọc lại, + X bật/tắt giọng đọc, + B ẩn/hiện phụ đề.

## Dịch vụ dịch

- **Chạy trên máy, không giới hạn:** Dịch máy Apple và Apple Intelligence.
- **Qua mạng, cần key:** Gemini, Groq, Cerebras, Mistral, OpenRouter, và một "dịch vụ tự thêm" cho API trả phí kiểu OpenAI (OpenAI, DeepSeek, xAI, Together, Fireworks: nhập địa chỉ, model, key). Trừ Gemini, tất cả đi chung một hàm (`Providers.openAI`). Mỗi dịch vụ nhận nhiều key; key chỉ được thêm khi kiểm tra chạy được.
- **Hạn mức Gemini tính theo dự án Google Cloud, không theo key.** Hai key cùng dự án dùng chung hạn mức, và Google từng khoá dự án lập ra để né hạn mức. Dự phòng nên là key của dịch vụ khác.
- **Thứ tự tự động** (`TranslationHub.currentOrder`): chất lượng, tốc độ, cân bằng hoặc tuỳ chỉnh. Tốc độ là trung vị 20 lần dịch gần nhất, cộng phạt theo tỉ lệ lỗi (`typicalMs`); số đo lưu qua các lần mở app. Thêm key thì app gửi ba câu thử để có số đo ngay; nút Đo lại ở trang Dịch vụ dịch. Lô chữ dài của dịch màn hình không tính vào số đo. Dịch màn hình và Dịch nhanh dùng dịch vụ nhanh nhất đang có.
- **Thứ tự tuỳ chỉnh** chỉ liệt kê dịch vụ đang bật và đã có key; dịch vụ mới bật hoặc mới thêm key nằm cuối.
- Dịch vụ chậm hoặc lỗi tự xuống cuối, key hết hạn mức tự chuyển key khác, model không còn dùng được thì app tự chọn model khác từ danh sách của tài khoản (`repairModel`). Trang Dịch vụ dịch hiện trạng thái từng dịch vụ, từng key và nhật ký chuyển đổi.
- Mới thử thật với key Gemini và Groq. Cerebras, Mistral, OpenRouter và dịch vụ trả phí mới kiểm được địa chỉ API và cách báo lỗi key sai.

## Chất lượng dịch (lọc nội dung, văn phong, tên riêng)

- **Chỉ dịch phụ đề:** luật trong app (`SubtitleFilter`, mọi engine), lời nhắc có dấu `[BỎ QUA]` (hoặc `[SKIP]` với ngôn ngữ khác) cho Gemini và Groq, và danh sách "luôn bỏ qua".
- **Xưng hô và văn phong:** đọc tên người nói, gửi kèm tối đa 10 câu trước, theo thể loại game (13 thể loại có sẵn, Tự động, và Tuỳ chỉnh). Thể loại Tuỳ chỉnh (`CustomStyle`, lưu theo hồ sơ game) cho người dùng tự mô tả: bối cảnh game, nhân vật và quan hệ, xưng hô, giọng văn, mức trang trọng, từ chửi thề, giữ kính ngữ, yêu cầu khác; mỗi ô tối đa 400 ký tự được gửi kèm mỗi câu, có nút điền sẵn từ thể loại có sẵn và phần xem trước hướng dẫn gửi cho AI. Bối cảnh game cũng được đưa vào lời nhắc của dịch màn hình. Im lặng quá lâu (mặc định 45 giây) thì quên ngữ cảnh.
- **Tên riêng:** từ điển thuật ngữ dùng mã tạm (Xqza...) nên giữ đủ tên trên Gemini, Groq và Dịch máy Apple.

## Giọng đọc (Voice-over / Dub)

- **Mặc định bật:** phụ đề + thuyết minh (đọc to bản dịch bằng một giọng Siri, phát thẳng nên gần như không trễ). Nút loa ở chân cửa sổ hoặc ⌃⌥D để bật/tắt; chuột phải nút loa để chọn Chỉ phụ đề / Phụ đề + thuyết minh / Chỉ thuyết minh. Giọng được khởi động sẵn lúc mở app nên câu đầu cũng đọc ngay.
- **Nhịp:** hàng đợi không cắt câu đang đọc; câu trễ quá 6 giây mà có câu mới hơn thì bỏ (tắt được); tự cân tốc độ theo nhịp thoại, câu đang chờ phía sau đọc nhanh hơn theo độ dài hàng đợi.
- **Chữ chạy** chỉ đọc khi đủ câu: chữ gốc hoặc bản dịch có dấu kết thúc, hoặc chữ đã đứng yên. Xét cả chữ gốc vì với cụm nối tiếp AI hay bỏ dấu chấm cuối bản dịch; trước bản 1.1.35 câu như vậy nằm chờ tới khi câu sau hiện ra. Thử không cần game: `OVERSUB_PROG_TEST=1` (dịch và đọc thật một đoạn hội thoại, xem nhật ký).
- **Chữ chạy không chặn vòng quét** (`Engine.ProgLine`, từ bản 1.1.37): việc dịch chạy riêng, vòng quét vẫn chụp đều trong lúc chờ AI. Trước đây vòng quét chờ dịch xong mới quét tiếp, có lần bị chặn 7 giây, nên ở cắt cảnh các khung phụ đề hiện rồi tắt trong lúc đó bị bỏ lỡ hẳn. Các cụm của cùng một câu vẫn dịch nối tiếp (cụm sau lấy bản dịch cụm trước làm ngữ cảnh), câu khác không phải chờ; kết quả ghép đúng thứ tự, câu bị thay giữa chừng vẫn được dịch và đọc nốt. Câu bị cắt bằng dấu phẩy, hai chấm (sang khung phụ đề sau) được đọc sau 3 nhịp đứng yên thay vì 6. Tốc độ đọc tính một lần cho cả câu; cụm sau của cùng câu mà cụm trước còn chờ trong hàng đợi thì nối vào đọc liền một lần. Thử: `OVERSUB_PROG_TEST=cutscene`.
- **Không đọc lặp:** nhãn tên người nói có lúc không tách được và dính vào đầu câu ("Experienced Farmer These vineyards..."); dòng đầu trùng một tên vừa gặp thì vẫn coi là nhãn tên (`Engine.splitKnownLabel`), không thì app tưởng câu mới và đọc lại (đo thực: một câu bị đọc 5 lần). Lớp chặn cuối (`recentDubs`, `alreadySpoken`): câu giống câu vừa đọc trong 45 giây thì bỏ, trừ khi bấm Đọc lại; so cả bản dịch lẫn câu gốc (cùng câu gốc mà AI dịch hai cách thì bản dịch không trùng); câu ngắn chỉ tính là lặp khi cùng người nói. Gặp thực tế (07/10): chuyển sang app khác rồi quay lại game, câu cũ vẫn trên màn hình bị đọc lại sau 16 giây. Nhãn tên lệch một ký tự ("Hill×") vẫn được nhận. Thử: `OVERSUB_PROG_TEST=return`. Thử: `OVERSUB_PROG_TEST=label`.
- **Không tăng tốc giữa câu:** giọng Siri tiếng Việt báo vị trí từ không đáng tin (có lúc báo trọn câu đầu ngay khi mới đọc) và lệnh dừng ở cuối từ hay cuối câu đều cắt ngay, nên dừng giữa chừng rồi đọc tiếp nhanh hơn làm mất một đoạn. Cơ chế này đã bỏ ở bản 1.1.35.
- **Âm thanh:** chọn loa hoặc tai nghe riêng (mỗi câu chậm thêm khoảng 1 giây vì phải dựng âm thanh trước); thử nghiệm giảm tiếng riêng của game khi đang đọc bằng Core Audio process tap (`AudioDucker`, cần quyền ghi âm thanh hệ thống).
- macOS chỉ cho app khác dùng giọng Siri đang chọn cho mỗi ngôn ngữ (giọng A và D tiếng Việt dựng ra giống hệt nhau), và giọng Siri neural bỏ qua `pitchBase` khi đọc thẳng.

### Dub · giọng theo nhân vật (beta, mặc định Voice-over)

- Mỗi nhân vật (từ nhãn tên trên hộp thoại) một giọng theo giới tính, tuổi; Groq/Gemini đoán giới tính, tuổi ở câu đầu (`TranslationHub.ask`, chỉ chạy khi bật tính năng này). Giọng Apple: Siri và Linh, đổi cao độ bằng AVAudioUnitTimePitch để phân biệt. Dàn diễn viên lưu theo preset.
- Trang Thuyết minh có hướng dẫn 3 bước kiểm tra trực tiếp: bật hiện tên nhân vật trong game, khung chọn gồm cả nhãn tên (app báo đọc được tên ở bao nhiêu câu gần nhất), kiểm tra giọng ở Dàn diễn viên.
- Câu nào chưa dựng kịp giọng nhân vật trong 1 giây thì đọc ngay bằng giọng thuyết minh.
- Gemini TTS (`GeminiTTS`, Interactions API, theo luồng, chỉ dẫn qua `speech_metadata.style`) đang phát triển và tạm khoá: đo được chậm 4–8 giây mỗi câu.

## Ghi chú phát triển

- Không dùng `@State`/`@Observable` vì Command Line Tools thiếu plugin macro của SwiftUI; dùng `ObservableObject`.
- App không quan sát trực tiếp `Engine`/`AppSettings` ở cấp `App` hay `Commands`, và các binding của sheet, inspector đi qua `.deduplicated`: `@Published` báo thay đổi cả khi gán lại giá trị cũ, không lọc thì SwiftUI dựng lại danh sách scene lặp vô hạn tới tràn stack lúc mở app.
- **Biểu tượng thanh menu** (`StatusMenu.swift`) dựng bằng AppKit, menu dựng lại mỗi lần bấm. Khi app khác đang toàn màn hình, macOS nhận cú bấm nhưng không hiện menu của app kiểu thường (có biểu tượng ở Dock); app kiểu phụ trợ thì hiện được. Vì vậy lúc bấm, nếu thấy toàn màn hình thì app chuyển sang `.accessory`, chờ 0,12 giây, mở menu, đóng menu thì trả về `.regular` (đổi kiểu ngay trong `menuWillOpen` là quá muộn). Nhận biết toàn màn hình: có cửa sổ của app khác phủ hết bề ngang, chạm đáy và cao hơn 60% màn hình (Comet tách thanh công cụ thành cửa sổ riêng nên phần nội dung chỉ cao khoảng 84%). Thử: `OVERSUB_MENU_TEST=<tên app đang toàn màn hình>` bấm biểu tượng bằng mã rồi chụp màn hình.
- Chụp giao diện để kiểm tra: `open --env OVERSUB_SNAPSHOT_DIR=/thư/mục OverSub.app` (app tự chụp cửa sổ chính và từng trang Cài đặt; thêm `--env OVERSUB_SNAPSHOT_SELECT=1` để chụp khung chọn).
- Tự kiểm tra lồng tiếng: `open --env OVERSUB_DUB_TEST=1 OverSub.app` đọc 3 câu bằng 3 đường phát và ghi thời gian vào nhật ký; `OVERSUB_DUB_TEST=voiceover` đọc 1 câu thuyết minh; `OVERSUB_DUB_TEST=gemini` đọc 1 câu bằng Gemini (tốn 1 lượt). Bài test dùng `OVERSUB_CONTEXT_FILE` để không đụng tệp ngữ cảnh thật.
- Nhật ký chẩn đoán: `~/Library/Logs/OverSub/debug.log`. Key API: `~/Library/Application Support/OverSub/keys.json` (quyền 0600). Giữ tên thư mục cũ để không phải chuyển dữ liệu.
- Icon vẽ bằng `Resources/make_icon.swift`, đóng gói bằng `iconutil` thành `Resources/AppIcon.icns`.

## Cập nhật 05/10/2026 (rà soát toàn app)

- **Cài đặt** xếp lại: Bắt đầu nhanh (Ngôn ngữ & game · Vùng) · Tính năng (Phụ đề · Cửa sổ phụ đề · Giọng đọc · Nhân vật · Dịch màn hình) · Bản dịch (Dịch vụ dịch · Văn phong & thuật ngữ) · Ứng dụng (Hồ sơ game · Phím tắt & tay cầm · Chung). Từ dùng thống nhất: "vùng" (không còn "khung"), "Cửa sổ phụ đề", "dịch vụ dịch".
- **Màn hình chính**: ba nút tròn ba trạng thái (tắt · bật chưa chạy: cam dịu · đang chạy: phát sáng); nút giọng đọc lớn ở giữa, có sóng loang (`SpeakingRipples`) khi đang đọc; thanh âm lượng mảnh (`SlimSlider`); nút Bắt đầu chính dùng gradient cam.
- **Song ngữ Việt–Anh**: mọi chuỗi giao diện viết `L("Tiếng Việt", "English")` (`Localization.swift`); chọn ở Cài đặt → Chung hoặc bước đầu của hướng dẫn (mặc định theo máy). Thử nhanh: `open OverSub.app --args -appLanguage en`. Lời nhắc gửi AI và nhật ký không đổi.
- **Luồng phụ đề**: không còn quét thưa khi rảnh, thấy chữ mới thì đọc lại sau 0,15 giây (cắt khoảng 1 giây chờ); chế độ Chờ đủ câu và Chữ chạy chốt theo chữ (không kẹt khi nền chuyển động); câu dịch lỗi được đọc lại; bản tạm Apple hiện sau 0,25 giây.
- **Dịch màn hình**: đi qua cùng đường xử lý hạn mức với phụ đề, chia lô 12 dòng, thử lại sau 3 giây khi lỗi; câu có số lưu thành mẫu ("Gold {0}"), số đổi thì điền lại không gọi AI; chữ rất ngắn nhớ trong phiên; xử lý ảnh chạy ngoài luồng chính.
- **Phát hành**: `./package.sh` tạo `dist/OverSub-<phiên bản>.dmg` (kéo vào Applications, kèm hướng dẫn "Vẫn mở"). Công cụ tự kiểm tra (`DebugSnapshot`) chỉ có khi build `OVERSUB_DEV=1 ./build.sh`. Dữ liệu và nhật ký chuyển sang `~/Library/Application Support/OverSub` và `~/Library/Logs/OverSub` (tự chuyển từ tên cũ).
