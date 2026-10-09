import AVFoundation
import Metal
import MetalFX
import SwiftUI

/// Trang Cài đặt › Màn hình chơi game: cùng các tuỳ chọn với menu trong cửa sổ, đổi ở đâu cũng áp dụng ngay cho cửa sổ đang mở.
struct PlaySettingsPage: View {
    @ObservedObject private var s = PlaySettings.shared
    @ObservedObject private var cards = CaptureCards.shared
    @ObservedObject private var play = PlayScreen.shared
    private static let superResolution = MTLCreateSystemDefaultDevice().map { MTLFXSpatialScalerDescriptor.supportsDevice($0) } ?? false

    /// Các mục xử lý hình đang chọn, để tính độ trễ thêm của Tuỳ chỉnh và của từng lựa chọn.
    private var current: PlayCost.Values { (s.upscaler, s.sharpen, s.antiAlias, s.frameGen) }

    /// Thiết bị mà các tuỳ chọn định dạng và nguồn tiếng đang nói tới: thiết bị đã chọn, không có thì capture card đang cắm.
    private var device: AVCaptureDevice? {
        cards.devices.first { $0.uniqueID == s.deviceID } ?? cards.devices.first { $0.uniqueID == cards.card?.id } ?? cards.devices.first
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(L("Capture card", "Capture card")) {
                    HStack(spacing: 10) {
                        Text(cards.card.map { $0.name + ($0.summary.map { " · \($0)" } ?? "") } ?? L("Chưa thấy capture card", "No capture card found"))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button(play.isOpen ? L("Đóng màn hình chơi", "Close game screen") : L("Mở màn hình chơi", "Open game screen")) {
                            play.isOpen ? play.close() : play.open()
                        }
                    }
                }
                Toggle(L("Báo ở chân cửa sổ chính khi cắm capture card", "Show a notice in the main window when a capture card is connected"), isOn: $s.notifyCard)
                Note(L("Màn hình chơi game hiện hình và tiếng từ capture card trong một cửa sổ của OverSub, để chơi máy console ngay trên Mac. Phụ đề, giọng đọc và dịch màn hình chạy trên cửa sổ này như với mọi game khác. Dòng báo không tính webcam và camera FaceTime; muốn dùng camera thì chọn ở Thiết bị hình bên dưới.",
                       "The game screen shows the picture and sound from a capture card in an OverSub window, so you can play your console right on your Mac. Subtitles, voice and screen translation work on it like on any other game. The notice ignores webcams and the FaceTime camera; to use a camera, pick it under Video device below."))
            }

            Section {
                Picker(L("Bộ chỉnh hình", "Picture preset"), selection: $s.preset) {
                    ForEach(PlaySettings.Preset.allCases.filter { $0 != .custom || s.preset == .custom }, id: \.self) { p in
                        Text(PlayLabels.preset(p, current: current, cost: play.cost)).tag(p)
                    }
                }
                Note(PlayLabels.presetDetail(s.preset, cost: play.cost))
                Note(PlayLabels.lagNote(cost: play.cost, measured: play.measuredLag))
            } header: { Text(L("Bộ chỉnh hình", "Picture preset")) }

            Section {
                Picker(L("Thiết bị hình", "Video device"), selection: Binding(get: { device?.uniqueID ?? "" }, set: { s.deviceID = $0.isEmpty ? nil : $0 })) {
                    if cards.devices.isEmpty { Text(L("Chưa thấy thiết bị nào", "No device found")).tag("") }
                    ForEach(cards.devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
                .disabled(cards.devices.isEmpty)
                if let d = device {
                    Picker(L("Định dạng hình", "Video format"), selection: Binding(get: { s.formats[d.uniqueID] ?? "" }, set: { s.formats[d.uniqueID] = $0.isEmpty ? nil : $0 })) {
                        Text(L("Tự động", "Automatic") + (CaptureCards.bestFormat(d).map { " (\(CaptureCards.describe($0.format, fps: $0.fps)))" } ?? "")).tag("")
                        ForEach(Self.formats(d), id: \.self) { f in
                            Text(PlayLabels.format(f)).tag(CaptureCards.key(f))
                        }
                    }
                    Note(PlayLabels.formatNotes.joined(separator: " "))
                    Picker(L("Nguồn tiếng", "Audio source"), selection: Binding(get: { s.audioSources[d.uniqueID] ?? "" }, set: { s.audioSources[d.uniqueID] = $0.isEmpty ? nil : $0 })) {
                        Text(L("Tự động", "Automatic") + " (\(CaptureCards.audioDevice(for: d)?.localizedName ?? L("không thấy", "none found")))").tag("")
                        Text(L("Không dùng tiếng", "No audio")).tag("none")
                        ForEach(CaptureCards.audioDevices(), id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                    }
                }
                Picker(L("Phát tiếng ra", "Audio output"), selection: Binding(get: { s.outputUID ?? "" }, set: { s.outputUID = $0.isEmpty ? nil : $0 })) {
                    Text(L("Theo loa của macOS", "Same as macOS")).tag("")
                    ForEach(AudioDevices.outputs(), id: \.uid) { Text(PlayLabels.output($0)).tag($0.uid) }
                }
                Note(PlayLabels.outputNote)
                SliderRow(title: L("Âm lượng", "Volume"), value: Binding(get: { s.volume * 100 }, set: { s.volume = $0 / 100 }),
                          range: 0...100, step: 5, format: "%.0f%%")
                Toggle(L("Tắt tiếng khi chuyển sang app khác", "Mute when another app is active"), isOn: $s.muteWhenInactive)
                Toggle(L("Luôn nằm trên cùng", "Always on top"), isOn: $s.onTop)
            } header: { Text(L("Thiết bị và tiếng", "Device and sound")) }

            Section {
                Picker(L("Dải màu", "Color range"), selection: $s.range) {
                    Text(L("Tự động", "Automatic")).tag(PlaySettings.Range.auto)
                    Text(L("Đầy đủ (0–255)", "Full (0–255)")).tag(PlaySettings.Range.full)
                    Text(L("Giới hạn (16–235)", "Limited (16–235)")).tag(PlaySettings.Range.limited)
                }
                Note(L("Tự động đọc độ sáng thật của tín hiệu, vì card hay ghi sai dải màu. Hình nhạt, màu đen ngả xám: chọn Giới hạn. Hình gắt, vùng tối mất chi tiết: chọn Đầy đủ. Vẫn nhạt dù đã chọn Giới hạn: trên Switch 2, vào System Settings › Display › RGB Range và chọn Full Range.",
                       "Automatic reads the actual brightness of the signal, because cards often label the range wrong. Washed out with grey blacks: choose Limited. Harsh with crushed shadows: choose Full. Still washed out on Limited: on Switch 2, open System Settings › Display › RGB Range and choose Full Range."))
                Picker(L("Chuẩn màu", "Color matrix"), selection: $s.matrix) {
                    Text(L("Tự động", "Automatic")).tag(PlaySettings.Matrix.auto)
                    Text("BT.709 (HD)").tag(PlaySettings.Matrix.bt709)
                    Text("BT.601 (SD)").tag(PlaySettings.Matrix.bt601)
                }
                Picker(L("Không gian màu", "Color space"), selection: $s.gamut) {
                    Text(L("sRGB (đúng màu)", "sRGB (accurate)")).tag(PlaySettings.Gamut.srgb)
                    Text(L("Display P3 (rực hơn, lệch màu gốc)", "Display P3 (more vivid, less accurate)")).tag(PlaySettings.Gamut.p3)
                }
                Picker("HDR", selection: $s.hdr) {
                    Text(L("Tắt (tín hiệu SDR)", "Off (SDR signal)")).tag(PlaySettings.HDR.off)
                    Text(L("Chuyển HDR về SDR", "Tone-map HDR to SDR")).tag(PlaySettings.HDR.tone)
                    Text(L("Hiện HDR (EDR)", "Show HDR (EDR)")).tag(PlaySettings.HDR.edr)
                }
                Note(L("Chỉ bật khi máy chơi game gửi tín hiệu HDR10 qua card: nếu Switch 2 bật HDR mà hình xám, nhạt màu, chọn Chuyển HDR về SDR, hoặc tắt HDR Output trên Switch 2. Với tín hiệu thường, để Tắt. " + PlayLabels.edrNote,
                       "Only for consoles that send HDR10 through the card: if Switch 2 outputs HDR and the picture looks grey and dull, choose Tone-map HDR to SDR, or turn off HDR Output on Switch 2. For a normal signal, leave it Off. " + PlayLabels.edrNote))
            } header: { Text(L("Màu", "Color")) }

            Section {
                Picker(L("Phóng to", "Upscaling"), selection: $s.upscaler) {
                    ForEach(PlayEffects.Upscaler.allCases.filter { $0 != .metalFX || Self.superResolution }, id: \.self) { Text(PlayLabels.upscaler($0, current: current, cost: play.cost)).tag($0) }
                }
                if let note = PlayLabels.upscaleNote(cost: play.cost) { Note(note) }
                Picker(L("Làm nét (RCAS)", "Sharpen (RCAS)"), selection: $s.sharpen) {
                    ForEach(PlaySettings.Sharpen.allCases, id: \.self) { Text(PlayLabels.sharpen($0, current: current, cost: play.cost)).tag($0) }
                }
                Toggle(PlayLabels.antiAlias(current: current, cost: play.cost), isOn: $s.antiAlias)
                Note(PlayLabels.sharpenNote + " " + PlayLabels.antiAliasNote)
                Picker(L("Tăng FPS", "Frame generation"), selection: $s.frameGen) {
                    ForEach(PlayInterpolator.Mode.allCases, id: \.self) { Text(PlayLabels.frameGen($0, current: current, cost: play.cost)).tag($0) }
                }
                Note(PlayLabels.frameGenNote(cost: play.cost))
                Picker(L("Khung hình", "Picture size"), selection: $s.fill) {
                    Text(L("Vừa khung (giữ trọn hình)", "Fit (show the whole picture)")).tag(false)
                    Text(L("Lấp đầy (cắt bớt phần thừa)", "Fill (crop what doesn't fit)")).tag(true)
                }
                Picker(L("Độ trễ", "Latency"), selection: $s.latency) {
                    Text(L("Thấp nhất", "Lowest")).tag(PlaySettings.Latency.lowest)
                    Text(L("Mượt (trễ thêm tối đa \(Int((1000 / play.cost.fps).rounded())) ms)", "Smooth (adds up to \(Int((1000 / play.cost.fps).rounded())) ms)")).tag(PlaySettings.Latency.smooth)
                }
                Note(L("Lấp đầy bỏ viền đen khi toàn màn hình trên MacBook (màn 16:10), đổi lại hai bên hình mất một dải mỏng khoảng 5%. Độ trễ Mượt giữ nhịp khung đều hơn trên màn hình 120 Hz.",
                       "Fill removes the black bars in full screen on a MacBook (16:10 display), at the cost of a thin strip, about 5%, on each side. Smooth latency keeps frame pacing steadier on 120 Hz displays."))
            } header: { Text(L("Tuỳ chỉnh hình", "Picture options")) }

            Section {
                LabeledContent(L("Hiệu ứng video của macOS", "macOS video effects")) {
                    Button(L("Mở…", "Open…")) { AVCaptureDevice.showSystemUserInterface(.videoEffects) }
                }
                    .disabled(!play.isOpen)
                Note(L("macOS có thể áp hiệu ứng camera (Portrait, Studio Light, Reactions…) lên hình từ capture card. Hình game bị làm mờ nền, chiếu sáng hay có hiệu ứng lạ thì tắt các hiệu ứng trong bảng này. Bảng chỉ có khi màn hình chơi đang nhận hình từ card; cũng mở được bằng biểu tượng camera xanh trên thanh menu.",
                       "macOS can apply camera effects (Portrait, Studio Light, Reactions…) to the picture from a capture card. If the game picture gets a blurred background, extra lighting or odd effects, turn them off in this panel. The panel only exists while the game screen is receiving from the card; the green camera icon in the menu bar opens it too."))
            } header: { Text(L("Hệ thống", "System")) }
        }
    }

    /// Định dạng của thiết bị, mỗi cỡ, khung/giây và kiểu nén một mục, lớn trước.
    private static func formats(_ d: AVCaptureDevice) -> [AVCaptureDevice.Format] {
        var seen = Set<String>()
        return d.formats.sorted { a, b in
            let sa = CaptureCards.size(a), sb = CaptureCards.size(b)
            return (Int(sa.width) * Int(sa.height), CaptureCards.fps(a)) > (Int(sb.width) * Int(sb.height), CaptureCards.fps(b))
        }.filter { seen.insert(CaptureCards.key($0)).inserted }
    }
}

/// Dòng ghi chú nhỏ dưới một cài đặt.
private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
}
