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
                  !uid.hasPrefix("OverSub") else { return nil }
            return Device(id: id, uid: uid, name: name)
        }
    }

    static func defaultOutput() -> AudioObjectID? {
        var id = AudioObjectID(0)
        return property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, &id) && id != 0 ? id : nil
    }

    static func id(forUID uid: String) -> AudioObjectID? { outputs().first { $0.uid == uid }?.id }
    static func uid(of id: AudioObjectID) -> String? { string(id, kAudioDevicePropertyDeviceUID) }

    /// Đối tượng âm thanh của một tiến trình (game); 0 nếu tiến trình đó chưa phát tiếng.
    static func processObject(pid: pid_t) -> AudioObjectID {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = pid
        var obj = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return st == noErr ? obj : 0
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
    private let queue = DispatchQueue(label: "oversub.duck", qos: .userInteractive)

    // Đọc trong luồng âm thanh, ghi từ luồng chính; một số Float, sai lệch một khung cũng không sao.
    nonisolated(unsafe) private var target: Float = 1
    nonisolated(unsafe) private var gain: Float = 1

    private(set) var lastError: String?
    var isActive: Bool { procID != nil }

    /// Bắt đầu chặn tiếng của game (nếu chưa). Trả về false nếu chưa làm được (game chưa phát tiếng, chưa có quyền...).
    @discardableResult
    func attach(bundleID: String?) -> Bool {
        guard let bundleID, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            lastError = L("Chưa nhận diện được game", "Game not detected yet"); return false
        }
        if isActive, tappedPID == app.processIdentifier { return true }
        detach()
        let proc = AudioDevices.processObject(pid: app.processIdentifier)
        guard proc != 0 else { lastError = L("Game chưa phát âm thanh", "The game isn't playing audio yet"); return false }
        guard let out = AudioDevices.defaultOutput(), let outUID = AudioDevices.uid(of: out) else { lastError = L("Không thấy loa", "No audio output found"); return false }

        let desc = CATapDescription(stereoMixdownOfProcesses: [proc])
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
        lastError = nil
        DebugLog.write("Giảm tiếng game: đã gắn vào \(app.localizedName ?? bundleID)")
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
                    d[f * ch + c] = srcData[f * srcCh + sc] * g
                }
            }
            if frames * ch * 4 < Int(b.mDataByteSize) {
                memset(d.advanced(by: frames * ch), 0, Int(b.mDataByteSize) - frames * ch * 4)
            }
        }
        gain = g
    }

    deinit { detach() }
}
