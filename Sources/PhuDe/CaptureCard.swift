import AVFoundation
import AppKit
import Combine

/// Capture card (thiết bị hình UVC cắm ngoài) đang cắm: tìm lúc mở app, theo dõi cắm/rút, chọn định dạng và nguồn tiếng.
/// macOS xếp capture card chung nhóm với webcam ngoài (`AVCaptureDevice.DeviceType.external`). Dòng báo ở chân cửa sổ chính
/// chỉ nói về capture card (bỏ camera FaceTime, webcam); danh sách thiết bị trong menu và Cài đặt thì có đủ mọi camera, để
/// người dùng tự chọn khi cần.
@MainActor
final class CaptureCards: ObservableObject {
    static let shared = CaptureCards()

    struct Card: Equatable {
        let id: String
        let name: String
        /// Định dạng sẽ dùng khi mở, ví dụ "1920×1080 · 60 fps".
        let summary: String?
    }

    /// Mọi thiết bị hình (capture card, webcam, camera FaceTime), theo thứ tự hệ thống liệt kê.
    @Published private(set) var devices: [AVCaptureDevice] = []
    /// Capture card để báo ở chân cửa sổ chính.
    @Published private(set) var card: Card?

    private var observers: [NSObjectProtocol] = []

    #if DEVTOOLS
    /// Thử không có capture card (OVERSUB_PLAY_DEVICE=facetime): coi camera FaceTime là capture card.
    static let testCamera = ProcessInfo.processInfo.environment["OVERSUB_PLAY_DEVICE"] == "facetime"
    #endif

    func start() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { note in
                let dev = note.object as? AVCaptureDevice
                let connected = note.name == AVCaptureDevice.wasConnectedNotification
                MainActor.assumeIsolated {
                    if let dev, dev.hasMediaType(.video) || dev.hasMediaType(.audio) {
                        DebugLog.write("Thiết bị \(connected ? "cắm vào" : "rút ra"): \(dev.localizedName) (\(dev.hasMediaType(.video) ? "hình" : "tiếng"))")
                    }
                    CaptureCards.shared.refresh()
                }
            })
        }
        refresh()
    }

    func refresh() {
        let list = Self.videoDevices()
        let ids = list.map(\.uniqueID)
        if ids != devices.map(\.uniqueID) { devices = list }
        let found = list.first(where: Self.looksLikeCaptureCard).map { d in
            Card(id: d.uniqueID, name: d.localizedName, summary: Self.bestFormat(d).map { Self.describe($0.format, fps: $0.fps) })
        }
        if found != card {
            card = found
            DebugLog.write(found.map { "Capture card: \($0.name)" + ($0.summary.map { " · \($0)" } ?? "") } ?? "Không còn capture card nào")
        }
    }

    // MARK: Thiết bị

    static func videoDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .builtInWideAngleCamera], mediaType: .video, position: .unspecified).devices
    }

    static func audioDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    /// Capture card, không phải camera: tên có chữ của capture card thì nhận ngay; tên có chữ của webcam (camera, cam, webcam…)
    /// hay do Apple làm (camera Studio Display) thì bỏ; tên lạ (card ít tên tuổi như "Hagibis") thì phải có định dạng từ 720p
    /// 50 khung/giây trở lên, thứ webcam thường không có.
    static func looksLikeCaptureCard(_ d: AVCaptureDevice) -> Bool {
        #if DEVTOOLS
        if testCamera, d.deviceType == .builtInWideAngleCamera { return true }
        #endif
        guard d.deviceType == .external else { return false }   // camera FaceTime, camera iPhone
        let n = d.localizedName.lowercased()
        let card = ["capture", "hdmi", "cam link", "elgato", "avermedia", "live gamer", "hd60", "ugreen", "ripsaw", "usb3", "usb 3", "macrosilicon"]
        let webcam = ["webcam", "cam", "facetime", "camera", "brio", "c920", "c922", "kiyo", "insta360", "obsbot", "iphone", "desk view"]
        if card.contains(where: n.contains) || d.manufacturer.lowercased().contains("macrosilicon") { return true }
        if webcam.contains(where: n.contains) || d.manufacturer == "Apple Inc." { return false }
        return d.formats.contains { size($0).height >= 720 && fps($0) >= 50 }
    }

    /// Nguồn tiếng đi cùng card: thiết bị tiếng cùng một phần cứng (`linkedDevices`), không có thì thiết bị tiếng trùng tên.
    /// Không bao giờ tự chọn micrô gắn trong máy (tiếng phòng sẽ phát ra loa, gây hú).
    static func audioDevice(for video: AVCaptureDevice) -> AVCaptureDevice? {
        let builtIn = Int32(bitPattern: kAudioDeviceTransportTypeBuiltIn)
        if let linked = video.linkedDevices.first(where: { $0.hasMediaType(.audio) && $0.transportType != builtIn }) { return linked }
        let key = normalized(video.localizedName)
        guard key.count >= 4 else { return nil }
        return audioDevices().first { a in
            let k = normalized(a.localizedName)
            return a.transportType != builtIn && k.count >= 4 && (k == key || k.contains(key) || key.contains(k))
        }
    }

    private static func normalized(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    // MARK: Định dạng

    struct Choice {
        let format: AVCaptureDevice.Format
        let fps: Double
    }

    nonisolated static func fps(_ f: AVCaptureDevice.Format) -> Double { f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0 }
    nonisolated static func size(_ f: AVCaptureDevice.Format) -> CMVideoDimensions { CMVideoFormatDescriptionGetDimensions(f.formatDescription) }
    nonisolated static func subtype(_ f: AVCaptureDevice.Format) -> FourCharCode { CMFormatDescriptionGetMediaSubType(f.formatDescription) }

    /// Định dạng không nén (YUV) cho hình nét hơn và không phải giải mã như MJPEG.
    nonisolated static func isRaw(_ f: AVCaptureDevice.Format) -> Bool {
        [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
         kCVPixelFormatType_422YpCbCr8, kCVPixelFormatType_422YpCbCr8_yuvs,
         kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange].contains(subtype(f))
    }

    /// Mặc định: 60 khung/giây trước, rồi 1920×1080, rồi không nén, rồi độ phân giải cao nhất (tới 4K).
    static func bestFormat(_ d: AVCaptureDevice) -> Choice? {
        let ranked = d.formats.max { a, b in rank(a).lexicographicallyPrecedes(rank(b)) }
        return ranked.map { Choice(format: $0, fps: fps($0)) }
    }

    private static func rank(_ f: AVCaptureDevice.Format) -> [Int] {
        let s = size(f)
        return [fps(f) >= 59 ? 1 : 0, s.width == 1920 && s.height == 1080 ? 1 : 0, isRaw(f) ? 1 : 0,
                min(Int(s.width) * Int(s.height), 3840 * 2160), Int(fps(f))]
    }

    /// Khoá nhận một định dạng giữa các lần mở (theo cỡ, khung/giây và kiểu nén).
    nonisolated static func key(_ f: AVCaptureDevice.Format) -> String {
        let s = size(f)
        return "\(s.width)x\(s.height)@\(Int(fps(f).rounded())):\(fourCC(subtype(f)))"
    }

    nonisolated static func describe(_ f: AVCaptureDevice.Format, fps: Double, codec: Bool = false) -> String {
        let s = size(f)
        let base = "\(s.width)×\(s.height) · \(Int(fps.rounded())) fps"
        return codec ? base + " · " + codecName(subtype(f)) : base
    }

    nonisolated static func codecName(_ t: FourCharCode) -> String {
        switch t {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: return "YUV 4:2:0"
        case kCVPixelFormatType_422YpCbCr8, kCVPixelFormatType_422YpCbCr8_yuvs: return "YUV 4:2:2"
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: return "YUV 10 bit"
        case kCMVideoCodecType_JPEG_OpenDML, kCMVideoCodecType_JPEG: return "MJPEG"
        default: return fourCC(t)
        }
    }

    nonisolated static func fourCC(_ t: FourCharCode) -> String {
        let bytes = [UInt8(t >> 24 & 0xff), UInt8(t >> 16 & 0xff), UInt8(t >> 8 & 0xff), UInt8(t & 0xff)]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "\(t)"
    }

    // MARK: Quyền

    /// Quyền Camera (hình) hoặc Micrô (tiếng). Chưa hỏi thì hỏi bằng hộp thoại của macOS.
    static func authorize(_ type: AVMediaType) async -> Bool {
        #if DEVTOOLS
        if ProcessInfo.processInfo.environment["OVERSUB_PLAY_FAKE_DENIED"] == (type == .video ? "camera" : "microphone") { return false }
        #endif
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }
}

/// Tuỳ chọn của màn hình chơi game. Dùng chung cho mọi hồ sơ game (là tuỳ chọn của thiết bị, không phải của game).
@MainActor
final class PlaySettings: ObservableObject {
    static let shared = PlaySettings()

    /// Cách hiểu dải sáng của tín hiệu. Hai bên lệch nhau thì hình nhạt (đen thành xám) hoặc gắt (mất chi tiết vùng tối).
    enum Range: String, CaseIterable { case auto, full, limited }
    /// Ma trận đổi YCbCr sang RGB. Lệch thì sắc màu sai (đỏ ngả cam, xanh lá ngả vàng).
    enum Matrix: String, CaseIterable { case auto, bt709, bt601 }
    enum Gamut: String, CaseIterable { case srgb, p3 }
    /// Tín hiệu HDR10: tắt (coi là SDR), chuyển về SDR, hoặc hiện HDR trên màn hình hỗ trợ.
    enum HDR: String, CaseIterable { case off, tone, edr }
    enum Sharpen: String, CaseIterable { case off, low, medium, high }
    enum Latency: String, CaseIterable { case lowest, smooth }
    /// Bộ chỉnh hình: gom cách phóng to, làm nét, khử răng cưa và tăng FPS thành vài lựa chọn sẵn. Tự chỉnh từng mục thì
    /// thành Tuỳ chỉnh; chỉnh trùng một bộ có sẵn thì tự nhận lại bộ đó.
    enum Preset: String, CaseIterable {
        case original, sharp, smoothEdges, game3D, cartoon, fluid120, fluid30, custom

        typealias Values = (upscaler: PlayEffects.Upscaler, sharpen: Sharpen, antiAlias: Bool, frameGen: PlayInterpolator.Mode)
        var values: Values? {
            switch self {
            case .original: return (.bilinear, .off, false, .off)
            case .sharp: return (.fsr, .low, false, .off)
            case .smoothEdges: return (.fsr, .low, true, .off)
            case .game3D: return (.anime3D, .off, false, .off)
            case .cartoon: return (.animeCel, .off, false, .off)
            case .fluid120: return (.fsr, .low, false, .double)
            case .fluid30: return (.fsr, .low, false, .thirty)
            case .custom: return nil
            }
        }
    }

    private let d: UserDefaults

    @Published var deviceID: String? { didSet { d.set(deviceID, forKey: "play.device") } }
    /// Định dạng đã chọn theo từng thiết bị (khoá của `CaptureCards.key`).
    @Published var formats: [String: String] { didSet { d.set(formats, forKey: "play.formats") } }
    /// Nguồn tiếng đã chọn theo từng thiết bị hình; "none" là không dùng tiếng.
    @Published var audioSources: [String: String] { didSet { d.set(audioSources, forKey: "play.audioSources") } }
    /// Loa phát tiếng game; nil là theo loa mặc định của macOS.
    @Published var outputUID: String? { didSet { d.set(outputUID, forKey: "play.output") } }
    @Published var volume: Double { didSet { d.set(volume, forKey: "play.volume") } }
    @Published var muted: Bool { didSet { d.set(muted, forKey: "play.muted") } }
    @Published var muteWhenInactive: Bool { didSet { d.set(muteWhenInactive, forKey: "play.muteInactive") } }
    @Published var onTop: Bool { didSet { d.set(onTop, forKey: "play.onTop") } }
    @Published var range: Range { didSet { d.set(range.rawValue, forKey: "play.range") } }
    @Published var matrix: Matrix { didSet { d.set(matrix.rawValue, forKey: "play.matrix") } }
    @Published var gamut: Gamut { didSet { d.set(gamut.rawValue, forKey: "play.gamut") } }
    @Published var hdr: HDR { didSet { d.set(hdr.rawValue, forKey: "play.hdr") } }
    @Published var preset: Preset {
        didSet {
            d.set(preset.rawValue, forKey: "play.preset")
            guard !applying, let v = preset.values else { return }
            applying = true
            upscaler = v.upscaler; sharpen = v.sharpen; antiAlias = v.antiAlias; frameGen = v.frameGen
            applying = false
        }
    }
    @Published var upscaler: PlayEffects.Upscaler { didSet { d.set(upscaler.rawValue, forKey: "play.upscaler"); followPreset() } }
    /// Làm nét bằng RCAS của FSR 1 sau khi phóng.
    @Published var sharpen: Sharpen { didSet { d.set(sharpen.rawValue, forKey: "play.sharpen"); followPreset() } }
    /// Khử răng cưa FXAA ở độ phân giải gốc, trước khi phóng.
    @Published var antiAlias: Bool { didSet { d.set(antiAlias, forKey: "play.aa"); followPreset() } }
    /// Tăng FPS bằng chèn khung (xem PlayInterpolator).
    @Published var frameGen: PlayInterpolator.Mode { didSet { d.set(frameGen.rawValue, forKey: "play.frameGen"); followPreset() } }
    private var applying = false

    /// Cách gọi của bản 1.1.68 (bài thử cũ vẫn dùng): bật là phóng bằng MetalFX.
    var superResolution: Bool {
        get { upscaler == .metalFX }
        set { upscaler = newValue ? .metalFX : .bilinear }
    }

    private func matches(_ v: Preset.Values) -> Bool {
        v.upscaler == upscaler && v.sharpen == sharpen && v.antiAlias == antiAlias && v.frameGen == frameGen
    }

    private func followPreset() {
        guard !applying else { return }
        let match = Preset.allCases.first { $0.values.map(matches) ?? false } ?? .custom
        guard match != preset else { return }
        applying = true
        preset = match
        applying = false
    }
    /// Lấp đầy cửa sổ (cắt phần thừa) thay vì giữ trọn hình với viền đen. Hợp với toàn màn hình trên màn 16:10 của MacBook.
    @Published var fill: Bool { didSet { d.set(fill, forKey: "play.fill") } }
    @Published var latency: Latency { didSet { d.set(latency.rawValue, forKey: "play.latency") } }
    /// Báo ở chân cửa sổ chính khi cắm capture card.
    @Published var notifyCard: Bool { didSet { d.set(notifyCard, forKey: "play.notify") } }

    private init() {
        #if DEVTOOLS
        // Bài thử ghi vào miền riêng, không đụng tuỳ chọn thật của người dùng.
        d = ProcessInfo.processInfo.environment["OVERSUB_PLAY_TEST"] != nil ? (UserDefaults(suiteName: "vn.imhillxtz.phude.playtest") ?? .standard) : .standard
        #else
        d = .standard
        #endif
        deviceID = d.string(forKey: "play.device")
        formats = d.dictionary(forKey: "play.formats") as? [String: String] ?? [:]
        audioSources = d.dictionary(forKey: "play.audioSources") as? [String: String] ?? [:]
        outputUID = d.string(forKey: "play.output")
        volume = d.object(forKey: "play.volume") as? Double ?? 1
        muted = d.bool(forKey: "play.muted")
        muteWhenInactive = d.bool(forKey: "play.muteInactive")
        onTop = d.bool(forKey: "play.onTop")
        range = Range(rawValue: d.string(forKey: "play.range") ?? "") ?? .auto
        matrix = Matrix(rawValue: d.string(forKey: "play.matrix") ?? "") ?? .auto
        gamut = Gamut(rawValue: d.string(forKey: "play.gamut") ?? "") ?? .srgb
        hdr = HDR(rawValue: d.string(forKey: "play.hdr") ?? "") ?? .off
        sharpen = Sharpen(rawValue: d.string(forKey: "play.sharpen") ?? "") ?? .off
        // Bản 1.1.68 chỉ có công tắc Siêu phân giải (MetalFX).
        upscaler = PlayEffects.Upscaler(rawValue: d.string(forKey: "play.upscaler") ?? "") ?? (d.bool(forKey: "play.superRes") ? .metalFX : .bilinear)
        antiAlias = d.bool(forKey: "play.aa")
        frameGen = PlayInterpolator.Mode(rawValue: d.string(forKey: "play.frameGen") ?? "") ?? .off
        preset = .custom
        fill = d.bool(forKey: "play.fill")
        latency = Latency(rawValue: d.string(forKey: "play.latency") ?? "") ?? .lowest
        notifyCard = d.object(forKey: "play.notify") as? Bool ?? true
        applying = true
        preset = Preset.allCases.first { $0.values.map(matches) ?? false } ?? .custom
        applying = false
    }

    #if DEVTOOLS
    /// Bài thử bắt đầu từ tuỳ chọn mặc định.
    func debugReset() {
        range = .auto; matrix = .auto; gamut = .srgb; hdr = .off; preset = .original; fill = false; latency = .lowest
        muted = false; volume = 1; onTop = false; muteWhenInactive = false
    }
    #endif
}
