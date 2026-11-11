// SwiftMD - DES/3DES helpers for the NetMD secure session.
// Replaces crypto-js as used by netmd-js src/netmd-interface.ts and src/encrypt-generator.ts.

import CommonCrypto
import Foundation

enum CryptoError: Error {
    case failed(CCCryptorStatus)
}

enum DESMode {
    case ecb
    case cbc(iv: [UInt8])
}

/// Single DES without padding. `data` must be a multiple of 8 bytes.
func des(_ operation: CCOperation, key: [UInt8], _ mode: DESMode, _ data: [UInt8]) throws -> [UInt8] {
    precondition(key.count == kCCKeySizeDES)
    return try crypt(operation, algorithm: CCAlgorithm(kCCAlgorithmDES), key: key, mode, data)
}

/// Two-key triple DES (K1, K2, K1) without padding, as crypto-js does with a 16-byte key.
func tripleDES(_ operation: CCOperation, key: [UInt8], _ mode: DESMode, _ data: [UInt8]) throws -> [UInt8] {
    precondition(key.count == 16)
    return try crypt(operation, algorithm: CCAlgorithm(kCCAlgorithm3DES), key: key + key[0..<8], mode, data)
}

private func crypt(_ operation: CCOperation, algorithm: CCAlgorithm, key: [UInt8], _ mode: DESMode, _ data: [UInt8]) throws -> [UInt8] {
    precondition(data.count % kCCBlockSizeDES == 0)
    var options = CCOptions(0)
    var iv: [UInt8]?
    switch mode {
    case .ecb: options |= CCOptions(kCCOptionECBMode)
    case .cbc(let v): iv = v
    }
    var out = [UInt8](repeating: 0, count: data.count)
    var moved = 0
    let status = CCCrypt(operation, algorithm, options, key, key.count, iv, data, data.count, &out, out.count, &moved)
    guard status == kCCSuccess else { throw CryptoError.failed(status) }
    return Array(out[0..<moved])
}

/// ISO 9797-1 MAC algorithm 3 ("retail MAC") over a 16-byte value, used to derive the session key.
/// Port of netmd-js `retailmac`.
func retailMAC(key: [UInt8], value: [UInt8], iv: [UInt8] = [UInt8](repeating: 0, count: 8)) throws -> [UInt8] {
    precondition(key.count == 16 && value.count >= 8 && value.count % 8 == 0)
    let beginning = Array(value[..<(value.count - 8)])
    let end = Array(value[(value.count - 8)...])
    let step1 = try des(CCOperation(kCCEncrypt), key: Array(key[0..<8]), .cbc(iv: iv), beginning)
    let iv2 = Array(step1.suffix(8))
    let step2 = try tripleDES(CCOperation(kCCEncrypt), key: key, .cbc(iv: iv2), end)
    return Array(step2.prefix(8))
}

func randomBytes(_ count: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    return bytes
}
