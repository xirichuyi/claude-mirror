import CryptoKit
import Foundation

let plist = try Data(contentsOf: URL(fileURLWithPath: "macos/Resources/Info.plist"))
let settings = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
guard let key = settings?["SUPublicEDKey"] as? String, let bytes = Data(base64Encoded: key) else {
    fatalError("Missing product update public key")
}
let manifest = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let encoded = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: bytes)
guard let signature = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
      publicKey.isValidSignature(signature, for: manifest) else {
    fatalError("Windows manifest signature does not match the embedded update key")
}
