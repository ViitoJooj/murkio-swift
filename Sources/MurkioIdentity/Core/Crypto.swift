import Foundation

/// fnv1a32 is the short, non-cryptographic hash that names the storage
/// records of a publishable key. Every Murkio SDK computes the same one
/// (FNV-1a, 32 bits, lowercase hex), so the name stays the same across them.
func fnv1a32(_ value: String) -> String {
    var hash: UInt32 = 0x811c_9dc5
    for byte in value.utf8 {
        hash ^= UInt32(byte)
        hash = hash &* 0x0100_0193
    }
    let hex = String(hash, radix: 16)
    return String(repeating: "0", count: 8 - hex.count) + hex
}

private let unreserved = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

/// A random string of unreserved URL characters, from the system's secure
/// generator (PKCE verifier and OAuth state).
func randomString(_ length: Int) -> String {
    var generator = SystemRandomNumberGenerator()
    return String((0..<length).map { _ in unreserved[Int.random(in: 0..<unreserved.count, using: &generator)] })
}

/// S256 code challenge of a PKCE verifier (RFC 7636).
func codeChallenge(_ verifier: String) -> String {
    base64URLEncode(sha256(Array(verifier.utf8)))
}

func base64URLEncode(_ bytes: [UInt8]) -> String {
    Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// Decodes base64 in either alphabet, with or without padding.
func base64Decode(_ text: String) -> [UInt8]? {
    var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while standard.hasSuffix("=") { standard.removeLast() }
    guard standard.count % 4 != 1 else { return nil }
    standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
    guard let data = Data(base64Encoded: standard) else { return nil }
    return Array(data)
}

private let sha256Constants: [UInt32] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]

/// SHA-256, written out so the SDK needs no crypto library and computes the
/// same PKCE challenge on every platform.
func sha256(_ message: [UInt8]) -> [UInt8] {
    var hash: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]

    var data = message
    let bitLength = UInt64(message.count) * 8
    data.append(0x80)
    while data.count % 64 != 56 { data.append(0) }
    for shift in stride(from: 56, through: 0, by: -8) {
        data.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
    }

    func rotate(_ value: UInt32, _ by: UInt32) -> UInt32 { (value >> by) | (value << (32 - by)) }

    var words = [UInt32](repeating: 0, count: 64)
    for block in stride(from: 0, to: data.count, by: 64) {
        for index in 0..<16 {
            let at = block + index * 4
            words[index] = UInt32(data[at]) << 24 | UInt32(data[at + 1]) << 16 | UInt32(data[at + 2]) << 8 | UInt32(data[at + 3])
        }
        for index in 16..<64 {
            let s0 = rotate(words[index - 15], 7) ^ rotate(words[index - 15], 18) ^ (words[index - 15] >> 3)
            let s1 = rotate(words[index - 2], 17) ^ rotate(words[index - 2], 19) ^ (words[index - 2] >> 10)
            words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
        }

        var a = hash[0], b = hash[1], c = hash[2], d = hash[3]
        var e = hash[4], f = hash[5], g = hash[6], h = hash[7]
        for index in 0..<64 {
            let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
            let choice = (e & f) ^ (~e & g)
            let first = h &+ s1 &+ choice &+ sha256Constants[index] &+ words[index]
            let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let second = s0 &+ majority
            h = g
            g = f
            f = e
            e = d &+ first
            d = c
            c = b
            b = a
            a = first &+ second
        }
        hash[0] = hash[0] &+ a
        hash[1] = hash[1] &+ b
        hash[2] = hash[2] &+ c
        hash[3] = hash[3] &+ d
        hash[4] = hash[4] &+ e
        hash[5] = hash[5] &+ f
        hash[6] = hash[6] &+ g
        hash[7] = hash[7] &+ h
    }

    return hash.flatMap { word in [UInt8(word >> 24), UInt8((word >> 16) & 0xff), UInt8((word >> 8) & 0xff), UInt8(word & 0xff)] }
}
