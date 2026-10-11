import AppKit
import AudioToolbox
import CoreAudio

/// Danh sách loa, tai nghe để chọn đầu ra riêng cho giọng lồng tiếng.
enum AudioDevices {
    struct Device: Identifiable, Hashable { let id: AudioObjectID; let uid: String; let name: String }

    private static func property<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ value: inout T) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr
    }

    private static func string(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var value: Unmanaged<CFString>?
        guard property(obj, selector, &value), let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    static func outputs() -> [Device] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streamAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput,
                                                        mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streamAddr, 0, nil, &streamSize) == noErr, streamSize > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName),
                  !uid.hasPrefix("OverSub"),
                  // Thiết bị gộp tạm macOS tạo cho app đang phát tiếng (màn hình chơi), không phải loa thật.
                  !uid.hasPrefix("CADefaultDeviceAggregate"), !name.hasPrefix("CADefaultDeviceAggregate") else { return nil }
            return Device(id: id, uid: uid, name: name)
        }
    }

    static func defaultOutput() -> AudioObjectID? {
        var id = AudioObjectID(0)
        return property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &id) && id != 0 ? id : nil
    }

    static func id(forUID uid: String) -> AudioObjectID? { outputs().first { $0.uid == uid }?.id }

    /// Loa, tai nghe nối qua Bluetooth (tiếng trễ hơn loa có dây, đáng báo khi chơi game).
    static func isBluetooth(_ id: AudioObjectID) -> Bool {
        var t: UInt32 = 0
        guard property(id, kAudioDevicePropertyTransportType, &t) else { return false }
        return t == kAudioDeviceTransportTypeBluetooth || t == kAudioDeviceTransportTypeBluetoothLE
    }
    static func uid(of id: AudioObjectID) -> String? { string(id, kAudioDevicePropertyDeviceUID) }

    /// Đối tượng âm thanh của một tiến trình; 0 nếu tiến trình đó chưa từng phát tiếng.
    static func processObject(pid: pid_t) -> AudioObjectID {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = pid
        var obj = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return st == noErr ? obj : 0
    }

    struct AudioProcess: Hashable { let id: AudioObjectID; let pid: pid_t; let name: String; let playing: Bool }

    /// Mọi tiến trình có tiếng của một app: tiến trình chính và các tiến trình con phát tiếng thay nó. Trình duyệt nhân Chromium
    /// (Comet, Chrome, Edge) phát tiếng từ tiến trình "Helper" chứ không phải tiến trình chính, nên chỉ tap tiến trình chính thì
    /// không chặn được gì. Tiến trình con nhận ra qua mã định danh bắt đầu bằng mã của app, hoặc tiến trình cha là app.
    static func processes(of app: NSRunningApplication) -> [AudioProcess] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        let main = app.processIdentifier
        let prefix = app.bundleIdentifier.map { $0 + "." }
        return ids.compactMap { obj in
            var pid: pid_t = 0
            guard property(obj, kAudioProcessPropertyPID, &pid) else { return nil }
            let bundle = string(obj, kAudioProcessPropertyBundleID) ?? ""
            guard pid == main || (prefix.map { bundle.hasPrefix($0) } ?? false) || parentPID(pid) == main else { return nil }
            var running: UInt32 = 0
            _ = property(obj, kAudioProcessPropertyIsRunningOutput, &running)
            return AudioProcess(id: obj, pid: pid, name: processName(pid), playing: running != 0)
        }
    }

    static func parentPID(_ pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
        return info.kp_eproc.e_ppid
    }

    static func processName(_ pid: pid_t) -> String {
        if let n = NSRunningApplication(processIdentifier: pid)?.localizedName { return n }
        var buf = [CChar](repeating: 0, count: 256)
        return proc_name(pid, &buf, 256) > 0 ? String(cString: buf) : "pid \(pid)"
    }
}

/// Giảm tiếng riêng của game khi giọng lồng tiếng đang đọc.
/// macOS không có chỉnh âm lượng theo app, nên dùng "process tap" (macOS 14.2+): chặn tiếng game, rồi phát lại qua app với mức to nhỏ tuỳ ý.
/// App thoát hoặc tắt tính năng thì tap bị huỷ và tiếng game trở lại bình thường ngay.
final class AudioDucker: @unchecked Sendable {
    private var tapID = AudioObjectID(0)
    private var aggregateID = AudioObjectID(0)
    private var procID: AudioDeviceIOProcID?
    private var tappedPID: pid_t = 0
    private var tappedObjects: Set<AudioObjectID> = []
    private let queue = DispatchQueue(label: "oversub.duck", qos: .userInteractive)

    // Đọc trong luồng âm thanh, ghi từ luồng chính; một số Float, sai lệch một khung cũng không sao.
    nonisolated(unsafe) private var target: Float = 1
    nonisolated(unsafe) private var gain: Float = 1
    // Tổng bình phương mẫu đã phát ra (sau khi giảm) để bài thử đo mức tiếng thật; luồng âm thanh cộng, luồng chính đọc rồi đặt lại.
    nonisolated(unsafe) private var outSquares: Double = 0
    nonisolated(unsafe) private var outSamples: Int = 0

    private(set) var lastError: String?
    private(set) var tappedName: String?
    var isActive: Bool { procID != nil }
    /// Mức đang áp cho tiếng game (đã làm mượt), 1 là bình thường.
    var currentGain: Float { gain }

    /// Bắt đầu chặn tiếng của app đang hiện game (nếu chưa), gồm cả tiến trình con phát tiếng thay nó. Gắn lại khi app có thêm
    /// tiến trình phát tiếng. Trả về false nếu chưa làm được (app chưa phát tiếng, chưa có quyền...).
    @discardableResult
    func attach(to app: NSRunningApplication) -> Bool {
        let name = app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)"
        let procs = AudioDevices.processes(of: app)
        let ids = Set(procs.map(\.id))
        if isActive, tappedPID == app.processIdentifier, ids == tappedObjects { return true }
        detach()
        guard !procs.isEmpty else { lastError = L("\(name) chưa phát âm thanh", "\(name) isn't playing audio yet"); return false }
        guard let out = AudioDevices.defaultOutput(), let outUID = AudioDevices.uid(of: out) else { lastError = L("Không thấy loa", "No audio output found"); return false }

        let desc = CATapDescription(stereoMixdownOfProcesses: procs.map(\.id))
        desc.uuid = UUID()
        desc.muteBehavior = .mutedWhenTapped     // tiếng gốc của game tắt khi app đang đọc tap, app tự phát lại
        desc.isPrivate = true
        desc.name = "OverSub duck"
        var tap = AudioObjectID(0)
        var st = AudioHardwareCreateProcessTap(desc, &tap)
        guard st == noErr else { lastError = L("Không tạo được tap (mã \(st)); có thể chưa cấp quyền ghi âm thanh", "Couldn't create the audio tap (code \(st)); audio recording permission may not be granted"); return false }
        tapID = tap

        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OverSub Duck",
            kAudioAggregateDeviceUIDKey: "OverSub-Duck-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        var aggID = AudioObjectID(0)
        st = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID)
        guard st == noErr else { lastError = L("Không tạo được thiết bị trộn (mã \(st))", "Couldn't create the mixing device (code \(st))"); detach(); return false }
        aggregateID = aggID

        var proc2: AudioDeviceIOProcID?
        st = AudioDeviceCreateIOProcIDWithBlock(&proc2, aggID, queue) { [weak self] _, input, _, output, _ in
            self?.render(input: input, output: output)
        }
        guard st == noErr, let proc2 else { lastError = L("Không mở được luồng âm thanh (mã \(st))", "Couldn't open the audio stream (code \(st))"); detach(); return false }
        procID = proc2
        st = AudioDeviceStart(aggID, proc2)
        guard st == noErr else { lastError = L("Không chạy được luồng âm thanh (mã \(st))", "Couldn't start the audio stream (code \(st))"); detach(); return false }
        tappedPID = app.processIdentifier
        tappedObjects = ids
        tappedName = name
        lastError = nil
        let list = procs.map { $0.name + ($0.playing ? " (đang phát)" : "") }.joined(separator: ", ")
        DebugLog.write("Giảm tiếng game: đã gắn vào \(name), \(procs.count) tiến trình có tiếng: \(list)")
        return true
    }

    func detach() {
        if let procID, aggregateID != 0 {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = 0 }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID); tapID = 0 }
        tappedPID = 0
        tappedObjects = []
        tappedName = nil
        target = 1; gain = 1
    }

    /// Mức tiếng game: 1 = bình thường, nhỏ hơn khi đang đọc thoại. Chuyển mượt trong khoảng 0,1 giây.
    func setLevel(_ level: Double) { target = Float(max(0, min(1, level))) }

    private func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outs = UnsafeMutableAudioBufferListPointer(output)
        guard let src = ins.first, let srcData = src.mData?.assumingMemoryBound(to: Float.self) else {
            for b in outs { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
            return
        }
        let srcCh = max(1, Int(src.mNumberChannels))
        let srcFrames = Int(src.mDataByteSize) / (4 * srcCh)
        let k: Float = 1.0 / 4800   // làm mượt theo từng mẫu, khoảng 0,1 giây ở 48 kHz
        let t = target
        var g = gain
        var sq = 0.0, count = 0
        for (bi, b) in outs.enumerated() {
            guard let d = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let ch = max(1, Int(b.mNumberChannels))
            let frames = min(Int(b.mDataByteSize) / (4 * ch), srcFrames)
            g = gain
            for f in 0..<frames {
                g += (t - g) * k
                for c in 0..<ch {
                    // Đầu ra nhiều buffer một kênh (không xen kẽ): buffer thứ bi ứng với kênh bi.
                    let sc = outs.count > 1 ? min(bi, srcCh - 1) : min(c, srcCh - 1)
                    let v = srcData[f * srcCh + sc] * g
                    d[f * ch + c] = v
                    sq += Double(v * v)
                }
            }
            count += frames * ch
            if frames * ch * 4 < Int(b.mDataByteSize) {
                memset(d.advanced(by: frames * ch), 0, Int(b.mDataByteSize) - frames * ch * 4)
            }
        }
        gain = g
        outSquares += sq
        outSamples += count
    }

    /// Mức tiếng game đã phát ra từ lần gọi trước (dBFS, sau khi giảm); nil nếu chưa phát mẫu nào. Cho bài thử đo.
    func takeOutputLevel() -> Double? {
        let sq = outSquares, n = outSamples
        outSquares = 0; outSamples = 0
        guard n > 0 else { return nil }
        return 10 * log10(max(sq / Double(n), 1e-12))
    }

    deinit { detach() }
}
