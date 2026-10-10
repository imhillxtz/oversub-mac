import SwiftUI

#if DEBUG
/// Model riêng cho Xcode Previews. Không dùng AppModel.shared: nó còn bật biểu tượng thanh menu, kiểm tra cập nhật,
/// theo dõi capture card và hỏi quyền Ghi màn hình, những thứ không nên chạy trong tiến trình xem trước.
@MainActor
private enum PreviewModel {
    static let settings = AppSettings.shared
    static let hub = TranslationHub(settings: settings)
    static let engine = Engine(settings: settings, hub: hub)

    /// Lịch sử thoại mẫu cho bảng Lịch sử thoại.
    static let historyEngine: Engine = {
        let e = Engine(settings: settings, hub: hub)
        e.transcript = [
            TranscriptItem(speaker: "Cloud", source: "Let's mosey.", translation: "Đi thôi."),
            TranscriptItem(speaker: "Barret", source: "Don't you go forgettin' about the payment!", translation: "Đừng có quên vụ trả tiền đấy nhé!"),
            TranscriptItem(speaker: nil, source: "Mako Reactor No. 1", translation: "Lò phản ứng Mako số 1"),
        ]
        return e
    }()
}

private extension View {
    @MainActor
    func previewModels(engine: Engine? = nil) -> some View {
        environmentObject(PreviewModel.settings)
            .environmentObject(PreviewModel.hub)
            .environmentObject(engine ?? PreviewModel.engine)
    }
}

#Preview("Màn hình chính") {
    ContentView()
        .previewModels()
        .frame(width: 760, height: 520)
}

#Preview("Cài đặt") {
    SettingsView()
        .previewModels()
        .frame(width: 860, height: 680)
}

#Preview("Lịch sử thoại") {
    HistoryView()
        .previewModels(engine: PreviewModel.historyEngine)
        .frame(width: 340, height: 480)
}

#Preview("Lịch sử thoại trống") {
    HistoryView()
        .previewModels()
        .frame(width: 340, height: 480)
}
#endif
