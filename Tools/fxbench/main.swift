import AppKit
import Metal

// Kiểm các bộ lọc hình và chèn khung ngoài app: dựng hình thử, chạy từng bộ lọc trên GPU, đo PSNR so với hình chuẩn, đo thời
// gian GPU, lưu PNG. Dùng: ./fxtest <thư mục ảnh>
let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."   // Kiểm bộ chỉnh hình ngoài app, xem Docs/DEVELOPMENT.md
let device = MTLCreateSystemDefaultDevice()!
let queue = device.makeCommandQueue()!
let fx = PlayEffects(device: device) { print("log:", $0) }
let interp = PlayInterpolator(device: device) { print("log:", $0) }

// MARK: Hình thử

func drawScene(_ w: Int, _ h: Int, antialias: Bool = true, square: CGPoint? = nil, hud: Bool = false, noise: Bool = true) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(antialias)
    let s = CGFloat(w) / 1920
    ctx.setFillColor(CGColor(red: 0.35, green: 0.4, blue: 0.45, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    if noise {
        // Nền có vân để dò chuyển động có điểm bám (như cảnh game), cố định theo toạ độ.
        for i in 0..<1600 {
            let x = CGFloat((i * 7919) % 1920) * s, y = CGFloat((i * 104729) % 1080) * s
            ctx.setFillColor(CGColor(red: 0.2 + CGFloat(i % 7) * 0.08, green: 0.3 + CGFloat(i % 5) * 0.09, blue: 0.4, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: x, y: y, width: (6 + CGFloat(i % 11)) * s, height: (6 + CGFloat(i % 13)) * s))
        }
    }
    // Đường mảnh nghiêng, vòng tròn, ô bàn cờ, chữ nhiều cỡ: những chỗ phóng to và khử răng cưa thể hiện rõ.
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
    for i in 0..<12 {
        ctx.setLineWidth((1 + CGFloat(i % 3)) * s)
        ctx.move(to: CGPoint(x: (100 + CGFloat(i) * 40) * s, y: 100 * s))
        ctx.addLine(to: CGPoint(x: (300 + CGFloat(i) * 55) * s, y: 520 * s))
        ctx.strokePath()
    }
    for r in stride(from: 20, to: 200, by: 18) {
        ctx.setLineWidth(2 * s)
        ctx.strokeEllipse(in: CGRect(x: (1500 - CGFloat(r)) * s, y: (300 - CGFloat(r)) * s, width: CGFloat(r) * 2 * s, height: CGFloat(r) * 2 * s))
    }
    for i in 0..<16 { for j in 0..<8 where (i + j) % 2 == 0 {
        ctx.setFillColor(CGColor(gray: 0.95, alpha: 1))
        ctx.fill(CGRect(x: (1100 + CGFloat(i) * 6) * s, y: (650 + CGFloat(j) * 6) * s, width: 6 * s, height: 6 * s))
    } }
    let g = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = g
    for (k, size) in [18.0, 26.0, 40.0, 64.0].enumerated() {
        NSAttributedString(string: "Where did you find this sword? 0123", attributes: [.font: NSFont.systemFont(ofSize: size * s, weight: .semibold), .foregroundColor: NSColor.white])
            .draw(at: NSPoint(x: 120 * s, y: (640 + CGFloat(k) * 90) * s))
    }
    if hud {
        NSAttributedString(string: "HP 120/120", attributes: [.font: NSFont.systemFont(ofSize: 36 * s, weight: .bold), .foregroundColor: NSColor.yellow])
            .draw(at: NSPoint(x: 40 * s, y: 1000 * s))
    }
    NSGraphicsContext.restoreGraphicsState()
    if let p = square {
        // Hình vuông đỏ có vân, gốc trên trái ở `p` (toạ độ ảnh, y xuống).
        let r = CGRect(x: p.x * s, y: (1080 - p.y - 160) * s, width: 160 * s, height: 160 * s)
        ctx.setFillColor(CGColor(red: 0.95, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fill(r)
        ctx.setFillColor(CGColor(red: 0.6, green: 0.05, blue: 0.05, alpha: 1))
        for k in 0..<8 { ctx.fill(CGRect(x: r.minX + CGFloat(k) * 20 * s, y: r.minY + CGFloat(k) * 20 * s, width: 10 * s, height: 10 * s)) }
    }
    return ctx.makeImage()!
}

func scaled(_ img: CGImage, _ w: Int, _ h: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}

func rgba(_ img: CGImage) -> [UInt8] {
    var px = [UInt8](repeating: 0, count: img.width * img.height * 4)
    let ctx = CGContext(data: &px, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    return px
}

/// Hình rgba16Float (như bước đổi màu của bộ vẽ ghi ra).
func upload(_ img: CGImage) -> MTLTexture {
    let px = rgba(img)
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: img.width, height: img.height, mipmapped: false)
    d.usage = [.shaderRead, .shaderWrite]
    let t = device.makeTexture(descriptor: d)!
    let f = px.map { Float16(Float($0) / 255) }
    f.withUnsafeBytes { t.replace(region: MTLRegionMake2D(0, 0, img.width, img.height), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: img.width * 8) }
    return t
}

func target(_ w: Int, _ h: Int) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]
    d.storageMode = .shared
    return device.makeTexture(descriptor: d)!
}

func read(_ t: MTLTexture) -> [UInt8] {
    var px = [UInt8](repeating: 0, count: t.width * t.height * 4)
    px.withUnsafeMutableBytes { t.getBytes($0.baseAddress!, bytesPerRow: t.width * 4, from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0) }
    return px
}

/// Đọc texture rgba16Float về 8 bit (chép sang texture chia sẻ bằng blit không đổi được kiểu, nên vẽ qua bộ lọc "song tuyến").
func readFloat(_ t: MTLTexture) -> [UInt8] {
    let out = target(t.width, t.height)
    let cb = queue.makeCommandBuffer()!
    fx.encode(cb, source: t, target: out, vp: .init(x: 0, y: 0, w: t.width, h: t.height), options: .init())
    cb.commit(); cb.waitUntilCompleted()
    return read(out)
}

func save(_ px: [UInt8], _ w: Int, _ h: Int, bgra: Bool, _ name: String) {
    var p = px
    if bgra { for i in stride(from: 0, to: p.count, by: 4) { p.swapAt(i, i + 2) } }
    let ctx = CGContext(data: &p, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
}

/// PSNR độ sáng giữa ảnh BGRA (đầu ra) và ảnh RGBA (chuẩn), bỏ 8 điểm viền.
func psnr(_ out: [UInt8], _ ref: [UInt8], _ w: Int, _ h: Int) -> Double {
    var mse = 0.0, n = 0
    for y in 8..<(h - 8) { for x in 8..<(w - 8) {
        let i = (y * w + x) * 4
        let lo = 0.299 * Double(out[i + 2]) + 0.587 * Double(out[i + 1]) + 0.114 * Double(out[i])
        let lr = 0.299 * Double(ref[i]) + 0.587 * Double(ref[i + 1]) + 0.114 * Double(ref[i + 2])
        mse += (lo - lr) * (lo - lr); n += 1
    } }
    return 10 * log10(255 * 255 / (mse / Double(n)))
}

func gpuTime(_ runs: Int, _ body: (MTLCommandBuffer) -> Void) -> Double {
    var total = 0.0
    for i in 0..<(runs + 2) {
        let cb = queue.makeCommandBuffer()!
        body(cb)
        cb.commit(); cb.waitUntilCompleted()
        if let e = cb.error { print("lỗi GPU:", e) }
        if i >= 2 { total += cb.gpuEndTime - cb.gpuStartTime }
    }
    return total / Double(runs) * 1000
}

// MARK: 1. Phóng to và làm nét

print("== Phóng 1920x1080 lên 3840x2160, so với hình vẽ thẳng ở 3840x2160")
let ref4k = drawScene(3840, 2160)
let src = upload(scaled(ref4k, 1920, 1080))
let refPx = rgba(ref4k)
let cases: [(String, PlayEffects.Options)] = [
    ("song tuyến", .init(upscaler: .bilinear)),
    ("MetalFX", .init(upscaler: .metalFX)),
    ("FSR EASU", .init(upscaler: .fsr)),
    ("FSR EASU + RCAS 0,5", .init(upscaler: .fsr, sharpenStops: 0.5)),
    ("Anime4K 3D", .init(upscaler: .anime3D)),
    ("Anime4K hoạt hình", .init(upscaler: .animeCel)),
    ("song tuyến + RCAS 0,5", .init(upscaler: .bilinear, sharpenStops: 0.5)),
]
for (i, c) in cases.enumerated() {
    let t = target(3840, 2160)
    let ms4k = gpuTime(20) { cb in fx.encode(cb, source: src, target: t, vp: .init(x: 0, y: 0, w: 3840, h: 2160), options: c.1) }
    let px = read(t)
    let t2 = target(3024, 1964)   // MacBook Pro 14 toàn màn hình, khung 16:9 là 3024x1701
    let msMac = gpuTime(20) { cb in fx.encode(cb, source: src, target: t2, vp: .init(x: 0, y: 131, w: 3024, h: 1701), options: c.1) }
    print(String(format: "  %-24@ PSNR %.2f dB; GPU %.2f ms (lên 4K), %.2f ms (lên 3024x1701); các bước: %@", c.0 as NSString,
                 psnr(px, refPx, 3840, 2160), ms4k, msMac, fx.lastStages.joined(separator: " → ")))
    save(px, 3840, 2160, bgra: true, "up-\(i)")
}

// MARK: 2. Khử răng cưa

print("\n== FXAA ở 1920x1080: hình vẽ không khử răng cưa, so với hình vẽ có khử răng cưa")
let jaggy = drawScene(1920, 1080, antialias: false)
let smoothRef = rgba(scaled(drawScene(3840, 2160), 1920, 1080))
let jsrc = upload(jaggy)
for (name, aa) in [("không FXAA", false), ("FXAA", true)] {
    let t = target(1920, 1080)
    let ms = gpuTime(20) { cb in fx.encode(cb, source: jsrc, target: t, vp: .init(x: 0, y: 0, w: 1920, h: 1080), options: .init(antiAlias: aa)) }
    let px = read(t)
    print(String(format: "  %-12@ PSNR %.2f dB so với hình khử răng cưa chuẩn; GPU %.2f ms", name as NSString, psnr(px, smoothRef, 1920, 1080), ms))
    save(px, 1920, 1080, bgra: true, "aa-\(aa ? 1 : 0)")
}

// MARK: 3. Chèn khung

func redCentroid(_ px: [UInt8], _ w: Int, _ h: Int, bgra: Bool) -> (Double, Double, Int) {
    var sx = 0.0, sy = 0.0, n = 0
    for y in 0..<h { for x in 0..<w {
        let i = (y * w + x) * 4
        let r = Double(px[i + (bgra ? 2 : 0)]), g = Double(px[i + 1]), b = Double(px[i + (bgra ? 0 : 2)])
        if r > 200, g < 60, b < 60 { sx += Double(x); sy += Double(y); n += 1 }
    } }
    return n > 0 ? (sx / Double(n), sy / Double(n), n) : (-1, -1, 0)
}

func frame(_ x: CGFloat, _ y: CGFloat) -> MTLTexture { upload(drawScene(1920, 1080, square: CGPoint(x: x, y: y), hud: true)) }

func feed(_ src: MTLTexture, mode: PlayInterpolator.Mode, duplicate: Bool) -> [PlayInterpolator.Output] {
    let cb = queue.makeCommandBuffer()!
    let slot = interp.nextSlot(width: src.width, height: src.height)!
    let blit = cb.makeBlitCommandEncoder()!
    blit.copy(from: src, to: slot)
    blit.endEncoding()
    let outs = interp.push(cb, mode: mode, interval: 1.0 / 60, duplicate: duplicate)
    cb.commit(); cb.waitUntilCompleted()
    if let e = cb.error { print("lỗi GPU:", e) }
    return outs
}

print("\n== Chèn khung x2: hình vuông đi từ (600,400) tới (680,440), khung giữa đúng phải ở (640,420); chữ HUD đứng yên")
let fP = frame(600, 400), fC = frame(680, 440)
_ = feed(fP, mode: .double, duplicate: false)
let outs = feed(fC, mode: .double, duplicate: false)
print("  số khung ra: \(outs.count), khung chèn trước: \(outs.first?.synthetic ?? false), khung thật sau \(String(format: "%.1f", (outs.last?.after ?? 0) * 1000)) ms")
if let mid = outs.first?.texture {
    let px = readFloat(mid)
    let c = redCentroid(px, 1920, 1080, bgra: true)
    let pPx = readFloat(fP), cPx = readFloat(fC)
    let p0 = redCentroid(pPx, 1920, 1080, bgra: true), c0 = redCentroid(cPx, 1920, 1080, bgra: true)
    print(String(format: "  tâm vuông đỏ: khung trước (%.1f, %.1f), khung sau (%.1f, %.1f), khung chèn (%.1f, %.1f) với %d điểm (khung thật %d điểm)", p0.0, p0.1, c0.0, c0.1, c.0, c.1, c.2, p0.2))
    // HUD ở góc trên trái (y ảnh 40..80): so khung chèn với khung trước.
    var diff = 0, cnt = 0
    for y in 30..<90 { for x in 30..<300 { let i = (y * 1920 + x) * 4; diff += abs(Int(px[i]) - Int(pPx[i])) + abs(Int(px[i + 1]) - Int(pPx[i + 1])); cnt += 1 } }
    print(String(format: "  chữ HUD: sai khác trung bình %.2f trên thang 255 (0 là giữ nguyên nét)", Double(diff) / Double(cnt) / 2))
    let truth = rgba(drawScene(1920, 1080, square: CGPoint(x: 640, y: 420), hud: true))
    var blend = [UInt8](repeating: 0, count: px.count)
    for i in 0..<px.count { blend[i] = UInt8((Int(pPx[i]) + Int(cPx[i])) / 2) }
    print(String(format: "  PSNR so với khung giữa đúng: khung chèn %.2f dB, trộn đơn giản hai khung %.2f dB, lặp khung trước %.2f dB",
                 psnr(px, truth, 1920, 1080), psnr(blend, truth, 1920, 1080), psnr(pPx, truth, 1920, 1080)))
    save(px, 1920, 1080, bgra: true, "interp-mid")
    save(pPx, 1920, 1080, bgra: true, "interp-prev")
    save(cPx, 1920, 1080, bgra: true, "interp-cur")
}
let msInterp = gpuTime(30) { cb in
    let slot = interp.nextSlot(width: 1920, height: 1080)!
    let b = cb.makeBlitCommandEncoder()!; b.copy(from: fC, to: slot); b.endEncoding()
    _ = interp.push(cb, mode: .double, interval: 1.0 / 60, duplicate: false)
}
print(String(format: "  GPU mỗi lần chèn (gồm chép khung): %.2f ms", msInterp))

print("\n== Máy quay lia ngang: cả cảnh dời 48 điểm sang trái mỗi khung (HUD đứng yên)")
func pan(_ dx: CGFloat) -> CGImage {
    let base = drawScene(2400, 1350, square: CGPoint(x: 900, y: 500))   // cảnh rộng hơn khung, cắt theo dx
    let ctx = CGContext(data: nil, width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(base.cropping(to: CGRect(x: 100 + dx, y: 0, width: 1920, height: 1080))!, in: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    return ctx.makeImage()!
}
let a0 = upload(pan(0)), a1 = upload(pan(48))
_ = feed(a0, mode: .double, duplicate: false)
if let mid = feed(a1, mode: .double, duplicate: false).first?.texture {
    let px = readFloat(mid), truth = rgba(pan(24))
    let p0 = readFloat(a0), p1 = readFloat(a1)
    var blend = [UInt8](repeating: 0, count: px.count)
    for i in 0..<px.count { blend[i] = UInt8((Int(p0[i]) + Int(p1[i])) / 2) }
    print(String(format: "  PSNR so với khung giữa đúng: khung chèn %.2f dB, trộn đơn giản %.2f dB, lặp khung trước %.2f dB",
                 psnr(px, truth, 1920, 1080), psnr(blend, truth, 1920, 1080), psnr(p0, truth, 1920, 1080)))
    save(px, 1920, 1080, bgra: true, "pan-mid")
}

print("\n== Game 30 khung/giây qua card 60: A A B B C C (vuông dời 80 điểm mỗi khung game)")
let seq: [(CGFloat, Bool)] = [(600, false), (600, true), (680, false), (680, true), (760, false), (760, true), (840, false), (840, true)]
var xs: [String] = []
let frames = Dictionary(uniqueKeysWithValues: Set(seq.map(\.0)).map { ($0, frame($0, 400)) })
for (x, dup) in seq {
    let o = feed(frames[x]!, mode: .thirty, duplicate: dup)
    for out in o {
        let c = redCentroid(readFloat(out.texture), 1920, 1080, bgra: true)
        xs.append(String(format: "%.0f%@", c.0, out.synthetic ? "*" : ""))
    }
}
print("  tâm vuông theo từng nhịp 60 Hz (* là khung chèn): \(xs.joined(separator: " "))")
