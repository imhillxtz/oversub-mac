// Nén các tấm khung hình của Ove (PNG xuất từ Tools/Ove/export.html) sang HEIC giữ kênh trong suốt, chép vào Resources/Ove.
// Dùng: swift Tools/Ove/ove_pack.swift <thư mục có ove-*.png và ove.json> [chất lượng 0..1, mặc định 0.78]
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count > 1 else {
    print("Dùng: swift Tools/Ove/ove_pack.swift <thư mục xuất> [chất lượng]")
    exit(1)
}
let src = URL(fileURLWithPath: args[1], isDirectory: true)
let quality = args.count > 2 ? Double(args[2]) ?? 0.78 : 0.78
let dst = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/Ove", isDirectory: true)
try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)

var total = 0
let names = try FileManager.default.contentsOfDirectory(atPath: src.path).filter { $0.hasPrefix("ove-") && $0.hasSuffix(".png") }.sorted()
for name in names {
    let inURL = src.appendingPathComponent(name)
    guard let source = CGImageSourceCreateWithURL(inURL as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        print("Không đọc được \(name)")
        exit(2)
    }
    let base = String(name.dropFirst(4).dropLast(4))
    let outURL = dst.appendingPathComponent(base + ".heic")
    guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
        print("Không tạo được \(outURL.lastPathComponent)")
        exit(3)
    }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
        print("Không ghi được \(outURL.lastPathComponent)")
        exit(4)
    }
    let size = (try FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
    total += size
    print(String(format: "%-12@ %4d×%-5d %6.0f KB", base, image.width, image.height, Double(size) / 1024))
}
let meta = src.appendingPathComponent("ove.json")
let metaOut = dst.appendingPathComponent("ove.json")
try? FileManager.default.removeItem(at: metaOut)
try FileManager.default.copyItem(at: meta, to: metaOut)
print(String(format: "Tổng: %.1f MB vào %@", Double(total) / 1_048_576, dst.path))
