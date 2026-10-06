// Ký file cài (.dmg) để app tự cập nhật nhận ra bản chính chủ: in ra chữ ký Ed25519 (base64) của toàn bộ file.
// Khoá bí mật nằm ngoài kho mã, chỉ trên máy tác giả: ~/Library/Application Support/OverSub Release/update-signing.key
// Dùng: swiftc -O -o /tmp/sign Tools/sign_update.swift && /tmp/sign dist/OverSub-x.y.z.dmg > dist/OverSub-x.y.z.dmg.sig
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 2 else { FileHandle.standardError.write("Dùng: sign_update <file.dmg>\n".data(using: .utf8)!); exit(2) }
let keyURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/OverSub Release/update-signing.key")
guard let keyText = try? String(contentsOf: keyURL, encoding: .utf8),
      let keyData = Data(base64Encoded: keyText.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData) else {
    FileHandle.standardError.write("Không đọc được khoá ký ở \(keyURL.path)\n".data(using: .utf8)!); exit(1)
}
let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
let signature = try key.signature(for: data)
guard key.publicKey.isValidSignature(signature, for: data) else { exit(1) }
print(signature.base64EncodedString())
