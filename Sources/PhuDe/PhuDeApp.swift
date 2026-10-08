import SwiftUI
import Combine

/// Giữ các model của app. App không quan sát trực tiếp Engine hay AppSettings: mỗi lần chúng đổi, SwiftUI sẽ dựng lại
/// toàn bộ danh sách scene và có thể lặp vô hạn (tràn stack lúc mở app). Chỉ trạng thái hiện biểu tượng menu được quan sát.
@MainActor
final class AppModel {
    static let shared = AppModel()
    let settings = AppSettings.shared
    let hub: TranslationHub
    let engine: Engine

    private init() {
        Speaker.setProcessLanguage(settings.target.base)
        hub = TranslationHub(settings: settings)
        engine = Engine(settings: settings, hub: hub)
        let appearance = settings.appearance
        DispatchQueue.main.async { AppAppearance.apply(appearance) }
        #if DEVTOOLS
        // Chụp kiểm tra ở chế độ sáng hoặc tối bất kể máy đang để gì.
        if let a = ProcessInfo.processInfo.environment["OVERSUB_APPEARANCE"] {
            DispatchQueue.main.async { NSApp.appearance = NSAppearance(named: a == "light" ? .aqua : .darkAqua) }
        }
        DebugSnapshot.runIfRequested(engine: engine)
        DebugSnapshot.dubTestIfRequested(engine: engine)
        DebugSnapshot.screenTestIfRequested(engine: engine)
        DebugSnapshot.layoutTestIfRequested(settings: settings)
        DebugSnapshot.sceneTestIfRequested(engine: engine, hub: hub, settings: settings)
        DebugSnapshot.excludeTestIfRequested(settings: settings)
        DebugSnapshot.siriProbeIfRequested()
        DebugSnapshot.siriCoachIfRequested()
        DebugSnapshot.ocrFilesIfRequested()
        DebugSnapshot.quickTestIfRequested(engine: engine)
        DebugSnapshot.menuTestIfRequested()
        DebugSnapshot.progressiveTestIfRequested(engine: engine)
        DebugSnapshot.updateTestIfRequested()
        DebugSnapshot.hideTestIfRequested()
        DebugSnapshot.restartNoticeTestIfRequested()
        DebugSnapshot.noticesTestIfRequested(engine: engine)
        DebugSnapshot.reportTestIfRequested()
        DebugSnapshot.permissionDockTestIfRequested(engine: engine)
        DebugSnapshot.updatePromptTestIfRequested()
        DebugSnapshot.screenRectIfRequested()
        if let s = ProcessInfo.processInfo.environment["OVERSUB_FRONT_TEST"], let n = Int(s) {
            let engine = engine
            Task { @MainActor in try? await Task.sleep(for: .seconds(2)); await engine.debugFrontCheck(seconds: n) }
        }
        // Thẻ cảm ơn theo mốc, chỉ để chụp giao diện (không ghi vào cài đặt).
        if ProcessInfo.processInfo.environment["OVERSUB_SUPPORT_TEST"] != nil { SupportPrompt.shared.debugShow(1_000) }
        #endif
        // Lần trước app tự khởi động lại vì Vision treo giữa lúc đang chạy: chạy tiếp.
        DispatchQueue.main.async { self.engine.resumeAfterRelaunchIfNeeded() }
        // Mở app mà chưa có quyền Ghi màn hình (đã qua hướng dẫn lần đầu, ví dụ vừa gỡ quyền trong Cài đặt hệ thống): hướng dẫn ngay,
        // không đợi tới lúc bấm Bắt đầu mới báo.
        if settings.onboardingDone {
            let engine = engine
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if !ScreenPermission.granted { engine.showPermissionGuide() } }
        }
        // Đợi AppModel dựng xong rồi mới mở lại Cửa sổ phụ đề (nó cần AppModel.shared).
        DispatchQueue.main.async { SubtitleWindowState.shared.restore() }
        // Biểu tượng thanh menu dựng bằng AppKit (xem StatusMenu).
        DispatchQueue.main.async { StatusMenu.shared.start(engine: self.engine, settings: self.settings) }
        DispatchQueue.main.async { Updater.shared.start() }
    }
}

@main
struct OverSubApp: App {
    private let model = AppModel.shared

    var body: some Scene {
        WindowGroup("OverSub", id: "main") {
            ContentView()
                .environmentObject(model.settings)
                .environmentObject(model.hub)
                .environmentObject(model.engine)
                .frame(minWidth: 660, minHeight: 440)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 820, height: 500)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { OverSubCommands(engine: model.engine, settings: model.settings) }

        Window(L("Ủng hộ OverSub", "Support OverSub"), id: "donate") {
            DonateView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            SettingsView()
                .environmentObject(model.settings)
                .environmentObject(model.hub)
                .environmentObject(model.engine)
        }
    }
}

/// Mục trong thanh menu của app, kèm phím tắt khi cửa sổ OverSub đang mở.
struct OverSubCommands: Commands {
    // Tham chiếu thường, không quan sát: Commands được dựng lại cùng danh sách scene, quan sát model ở đây gây lặp vô hạn.
    let engine: Engine
    let settings: AppSettings

    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(L("Kiểm tra cập nhật…", "Check for Updates…")) { UpdatePrompt.shared.checkNow() }
            Button(L("Ủng hộ OverSub…", "Support OverSub…")) { openWindow(id: "donate") }
        }
        CommandGroup(replacing: .help) {
            Button(L("Gửi báo lỗi…", "Send Bug Report…")) { ErrorReport.send() }
        }
        CommandMenu(L("Dịch", "Translate")) {
            Button(L("Bắt đầu / Dừng", "Start / Stop")) { engine.toggleRunning() }
                .keyboardShortcut("r")
            Button(L("Bật / tắt giọng đọc", "Turn voice on / off")) { engine.toggleDub() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button(L("Ẩn / hiện phụ đề đè lên game", "Hide / show subtitles over the game")) { engine.toggleOverlay() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button(L("Đọc lại câu vừa rồi", "Replay last line")) { engine.replayLast() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button(L("Chọn vùng phụ đề", "Select subtitle region")) { engine.selectRegion() }
                .keyboardShortcut("k")
            Button(L("Lịch sử thoại", "Dialogue history")) { engine.showHistory.toggle() }
                .keyboardShortcut("l")
            Button(L("Mở / đóng Cửa sổ phụ đề", "Open / close subtitle window")) { SubtitleWindowState.shared.toggle() }
                .keyboardShortcut("j")
            Button(L("Dịch nhanh một vùng", "Quick-translate an area")) { engine.quickTranslate() }
                .keyboardShortcut("e")
            Button(L("Bật / tắt dịch màn hình", "Turn screen translation on / off")) { engine.toggleScreenTranslate() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
        }
    }
}

extension Binding where Value: Equatable {
    /// Chỉ ghi khi giá trị thật sự đổi. @Published báo thay đổi cả khi gán lại đúng giá trị cũ; SwiftUI lại hay ghi ngược giá trị
    /// hiện tại vào binding của sheet, inspector, MenuBarExtra trong lúc cập nhật, nên không lọc thì vòng cập nhật lặp mãi tới tràn stack.
    var deduplicated: Binding<Value> {
        Binding(get: { wrappedValue }, set: { if $0 != wrappedValue { wrappedValue = $0 } })
    }
}
