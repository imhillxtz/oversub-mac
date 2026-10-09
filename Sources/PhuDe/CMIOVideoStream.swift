import AVFoundation
import CoreMediaIO

/// Nhận hình thẳng từ hàng đợi khung của CoreMediaIO, không qua AVCaptureSession.
///
/// Trên macOS 26 trở lên, phiên AVCaptureSession có hình luôn chạy đường hiệu ứng video của hệ thống ngay trong tiến trình
/// (dò mặt, dáng người, bàn tay cho Reactions và hiệu ứng chân dung) kể cả khi mọi hiệu ứng đều tắt; đặt sandbox, SDK cũ hay
/// các hàm `_set…Allowed:` riêng của AVCaptureDevice đều không bỏ được. Đo với card Hagibis 1080p60 `yuvs`, chỉ riêng việc
/// nhận hình qua AVCaptureSession tốn 18–21% một nhân; đọc thẳng CoreMediaIO tốn khoảng 6%, cùng 60 khung/giây, cùng khung
/// IOSurface đúng định dạng gốc. Tiếng vẫn đi qua AVCaptureSession (chỉ có tiếng thì không có đường hiệu ứng).
final class CMIOVideoStream: @unchecked Sendable {
    /// Định dạng bộ vẽ đọc thẳng được. Định dạng nén (MJPEG) thì để AVCaptureSession giải mã.
    private static let drawable: Set<OSType> = [
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
        kCVPixelFormatType_422YpCbCr8, kCVPixelFormatType_422YpCbCr8_yuvs,
    ]

    let subtype: OSType
    let fps: Double
    private let device: CMIOObjectID
    private let stream: CMIOStreamID
    private let deliver: DispatchQueue
    /// Khung mới nhất và số khung cũ hơn bị bỏ qua trong cùng lượt (gọi trên `deliver`).
    private let onFrame: (CVPixelBuffer, Int, [Double]) -> Void
    private var queue: CMSimpleQueue?   // chỉ dùng trên deliver
    private var retained: Unmanaged<CMIOVideoStream>?

    /// Tìm thiết bị CoreMediaIO cùng UID với `video`, đặt định dạng và tốc độ khung khớp `format` (nil: giữ định dạng hiện tại).
    /// Trả nil kèm lý do trong nhật ký khi không dùng được; khi đó gọi bên ngoài quay về AVCaptureSession.
    init?(video: AVCaptureDevice, format: AVCaptureDevice.Format?, deliver: DispatchQueue,
          onFrame: @escaping (CVPixelBuffer, Int, [Double]) -> Void) {
        func fail(_ why: String) { DebugLog.write("Màn hình chơi: không đọc thẳng CoreMediaIO được (\(why)), dùng AVCaptureSession") }
        guard let dev = Self.ids(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices)
            .first(where: { Self.string($0, kCMIODevicePropertyDeviceUID) == video.uniqueID }) else {
            fail("không thấy thiết bị \(video.uniqueID)"); return nil
        }
        guard let st = Self.ids(dev, kCMIODevicePropertyStreams, scope: kCMIODevicePropertyScopeInput).first else {
            fail("thiết bị không có luồng hình"); return nil
        }
        if let format {
            let want = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard Self.drawable.contains(want) else { fail("định dạng \(CaptureCards.fourCC(want)) cần giải mã"); return nil }
            guard let match = Self.formats(st).first(where: {
                CMFormatDescriptionGetMediaSubType($0) == want
                    && CMVideoFormatDescriptionGetDimensions($0).width == dims.width && CMVideoFormatDescriptionGetDimensions($0).height == dims.height
            }) else { fail("không có định dạng \(dims.width)x\(dims.height) \(CaptureCards.fourCC(want))"); return nil }
            var fd: CMFormatDescription? = match
            var a = Self.address(kCMIOStreamPropertyFormatDescription)
            let r = CMIOObjectSetPropertyData(st, &a, 0, nil, UInt32(MemoryLayout<CMFormatDescription?>.size), &fd)
            guard r == noErr else { fail("đặt định dạng lỗi \(r)"); return nil }
        }
        guard let current = Self.currentFormat(st) else { fail("không đọc được định dạng hiện tại"); return nil }
        let subtype = CMFormatDescriptionGetMediaSubType(current)
        guard Self.drawable.contains(subtype) else { fail("định dạng hiện tại \(CaptureCards.fourCC(subtype)) cần giải mã"); return nil }

        // Tốc độ khung: cao nhất trong các tốc độ của định dạng, không vượt tốc độ của định dạng đã chọn.
        let cap = format?.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? .infinity
        let rates = Self.float64s(st, kCMIOStreamPropertyFrameRates)
        if var rate = rates.filter({ $0 <= cap + 0.5 }).max() ?? rates.max() {
            var a = Self.address(kCMIOStreamPropertyFrameRate)
            let r = CMIOObjectSetPropertyData(st, &a, 0, nil, UInt32(MemoryLayout<Float64>.size), &rate)
            if r != noErr { DebugLog.write("Màn hình chơi: CoreMediaIO không đặt được \(rate) khung/giây (lỗi \(r))") }
        }
        self.fps = Self.float64s(st, kCMIOStreamPropertyFrameRate).first ?? 0
        self.subtype = subtype
        self.device = dev
        self.stream = st
        self.deliver = deliver
        self.onFrame = onFrame
    }

    /// Bắt đầu nhận khung. Gọi một lần.
    func start() -> Bool {
        let me = Unmanaged.passRetained(self)
        var q: Unmanaged<CMSimpleQueue>?
        var r = CMIOStreamCopyBufferQueue(stream, Self.altered, me.toOpaque(), &q)
        guard r == noErr, let q else {
            me.release()
            DebugLog.write("Màn hình chơi: CoreMediaIO không cấp hàng đợi khung (lỗi \(r))")
            return false
        }
        let simple = q.takeRetainedValue()
        deliver.sync { queue = simple }
        r = CMIODeviceStartStream(device, stream)
        guard r == noErr else {
            unregister()
            me.release()
            DebugLog.write("Màn hình chơi: CoreMediaIO không mở được luồng hình (lỗi \(r))")
            return false
        }
        retained = me
        return true
    }

    func stop() {
        guard let me = retained else { return }
        retained = nil
        let r = CMIODeviceStopStream(device, stream)
        if r != noErr { DebugLog.write("Màn hình chơi: CoreMediaIO dừng luồng hình báo lỗi \(r) (thường do card vừa rút)") }
        unregister()
        // Lệnh gọi lại có thể còn đang chạy trên luồng của CoreMediaIO: giữ đối tượng thêm một giây rồi mới thả.
        deliver.asyncAfter(deadline: .now() + 1) { me.release() }
    }

    private func unregister() {
        var none: Unmanaged<CMSimpleQueue>?
        _ = CMIOStreamCopyBufferQueue(stream, nil, nil, &none)
        none?.release()
        deliver.sync { queue = nil }
    }

    /// CoreMediaIO gọi mỗi khi đưa một khung vào hàng đợi (trên luồng của nó): chuyển sang `deliver`, lấy hết, vẽ khung mới nhất.
    private static let altered: CMIODeviceStreamQueueAlteredProc = { _, _, refCon in
        guard let refCon else { return }
        let me = Unmanaged<CMIOVideoStream>.fromOpaque(refCon).takeUnretainedValue()
        me.deliver.async { me.drain() }
    }

    private func drain() {
        guard let queue else { return }
        var latest: CVPixelBuffer?
        var skipped = 0
        var times: [Double] = []
        while let p = CMSimpleQueueDequeue(queue) {
            let sample = Unmanaged<CMSampleBuffer>.fromOpaque(p).takeRetainedValue()
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            if latest != nil { skipped += 1 }
            latest = pb
            let t = CMSampleBufferGetPresentationTimeStamp(sample)
            if t.isValid { times.append(t.seconds) }
        }
        if let latest { onFrame(latest, skipped, times) }
    }

    // MARK: Thuộc tính CoreMediaIO

    private static func address(_ selector: Int, scope: Int = kCMIOObjectPropertyScopeGlobal) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector), mScope: CMIOObjectPropertyScope(scope),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func ids(_ object: CMIOObjectID, _ selector: Int, scope: Int = kCMIOObjectPropertyScopeGlobal) -> [CMIOObjectID] {
        var a = address(selector, scope: scope)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &a, 0, nil, size, &used, &list) == noErr else { return [] }
        return Array(list.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    private static func float64s(_ object: CMIOObjectID, _ selector: Int) -> [Float64] {
        var a = address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [Float64](repeating: 0, count: Int(size) / MemoryLayout<Float64>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &a, 0, nil, size, &used, &list) == noErr else { return [] }
        return Array(list.prefix(Int(used) / MemoryLayout<Float64>.size))
    }

    private static func string(_ object: CMIOObjectID, _ selector: Int) -> String? {
        var a = address(selector)
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &a, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &used, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func formats(_ stream: CMIOStreamID) -> [CMFormatDescription] {
        var a = address(kCMIOStreamPropertyFormatDescriptions)
        var value: Unmanaged<CFArray>?
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(stream, &a, 0, nil, UInt32(MemoryLayout<Unmanaged<CFArray>?>.size), &used, &value) == noErr else { return [] }
        return value?.takeRetainedValue() as? [CMFormatDescription] ?? []
    }

    private static func currentFormat(_ stream: CMIOStreamID) -> CMFormatDescription? {
        var a = address(kCMIOStreamPropertyFormatDescription)
        var value: Unmanaged<CMFormatDescription>?
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(stream, &a, 0, nil, UInt32(MemoryLayout<Unmanaged<CMFormatDescription>?>.size), &used, &value) == noErr else { return nil }
        return value?.takeRetainedValue()
    }
}
