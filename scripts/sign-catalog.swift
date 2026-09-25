import Foundation
import CryptoKit
import Security

// Private key never leaves the login Keychain. Only signatures and the public key are output.
let args = CommandLine.arguments
let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.juicebar.catalog-signing", kSecAttrAccount as String: "release"]
var read = query; read[kSecReturnData as String] = true; read[kSecMatchLimit as String] = kSecMatchLimitOne
var result: CFTypeRef?
let status = SecItemCopyMatching(read as CFDictionary, &result)
let signer: Curve25519.Signing.PrivateKey
if status == errSecSuccess, let data = result as? Data { signer = try Curve25519.Signing.PrivateKey(rawRepresentation: data) }
else if status == errSecItemNotFound && args.contains("--create-key") {
    signer = Curve25519.Signing.PrivateKey()
    var add = query; add[kSecValueData as String] = signer.rawRepresentation
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { fatalError("Cannot save catalog key") }
} else { fatalError("Catalog signing key unavailable; --create-key only for initial setup") }
if args.contains("--public-key") { print(signer.publicKey.rawRepresentation.base64EncodedString()) }
else {
    guard args.count == 3 else { fatalError("Usage: swift scripts/sign-catalog.swift input.json output.signed.json") }
    let payload = try Data(contentsOf: URL(fileURLWithPath: args[1]))
    guard payload.count <= 1_000_000 else { fatalError("Catalog too large") }
    let envelope = ["payload": payload.base64EncodedString(), "signature": try signer.signature(for: payload).base64EncodedString()]
    try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]).write(to: URL(fileURLWithPath: args[2]), options: .atomic)
}
