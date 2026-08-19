import CommonCrypto
import CryptoKit
import Foundation

/// Native primitives exposed to trusted Nuvio scraper code. This mirrors the Apple implementation
/// used by Nuvio Mobile while keeping cryptographic data out of JavaScript wherever possible.
enum PluginCrypto {
    static func pbkdf2(
        password: Data,
        salt: Data,
        iterations: Int,
        keyLength: Int,
        algorithm: String
    ) -> Data? {
        guard iterations > 0, keyLength > 0, keyLength <= 16_384 else { return nil }
        var output = Data(repeating: 0, count: keyLength)
        let status = output.withUnsafeMutableBytes { outputBuffer in
            password.withUnsafeBytes { passwordBuffer in
                salt.withUnsafeBytes { saltBuffer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBuffer.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                        saltBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        prf(for: algorithm), UInt32(iterations),
                        outputBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self), keyLength
                    )
                }
            }
        }
        return status == kCCSuccess ? output : nil
    }

    /// AES-CBC/ECB uses CommonCrypto; AES-GCM uses CryptoKit. GCM output is ciphertext + 128-bit tag.
    static func aes(
        encrypting: Bool,
        mode: String,
        key: Data,
        iv: Data,
        input: Data
    ) -> Data? {
        let normalized = mode.uppercased()
        guard [16, 24, 32].contains(key.count) else { return nil }
        if normalized.contains("GCM") {
            return aesGCM(encrypting: encrypting, key: key, iv: iv, input: input)
        }
        let ecb = normalized.contains("ECB")
        guard ecb || !iv.isEmpty else { return nil }
        let options: CCOptions = ecb
            ? CCOptions(kCCOptionECBMode | (normalized.contains("NOPADDING") ? 0 : kCCOptionPKCS7Padding))
            : CCOptions(normalized.contains("NOPADDING") ? 0 : kCCOptionPKCS7Padding)
        return aesBlock(encrypting: encrypting, options: options, key: key, iv: ecb ? nil : iv, input: input)
    }

    private static func aesBlock(
        encrypting: Bool,
        options: CCOptions,
        key: Data,
        iv: Data?,
        input: Data
    ) -> Data? {
        let outputCapacity = input.count + kCCBlockSizeAES128
        var output = Data(repeating: 0, count: outputCapacity)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputBuffer in
            key.withUnsafeBytes { keyBuffer in
                input.withUnsafeBytes { inputBuffer in
                    if let iv {
                        return iv.withUnsafeBytes { ivBuffer in
                            CCCrypt(
                                encrypting ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt),
                                CCAlgorithm(kCCAlgorithmAES), options,
                                keyBuffer.baseAddress, key.count, ivBuffer.baseAddress,
                                inputBuffer.baseAddress, input.count,
                                outputBuffer.baseAddress, outputCapacity, &moved
                            )
                        }
                    }
                    return CCCrypt(
                        encrypting ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES), options,
                        keyBuffer.baseAddress, key.count, nil,
                        inputBuffer.baseAddress, input.count,
                        outputBuffer.baseAddress, outputCapacity, &moved
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        output.count = moved
        return output
    }

    private static func aesGCM(encrypting: Bool, key: Data, iv: Data, input: Data) -> Data? {
        guard let nonce = try? AES.GCM.Nonce(data: iv) else { return nil }
        let symmetricKey = SymmetricKey(data: key)
        do {
            if encrypting {
                let sealed = try AES.GCM.seal(input, using: symmetricKey, nonce: nonce)
                return sealed.ciphertext + sealed.tag
            }
            guard input.count >= 16 else { return nil }
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: input.dropLast(16), tag: input.suffix(16))
            return try AES.GCM.open(box, using: symmetricKey)
        } catch {
            return nil
        }
    }

    private static func prf(for algorithm: String) -> CCPseudoRandomAlgorithm {
        switch algorithm.uppercased().replacingOccurrences(of: "-", with: "") {
        case "SHA256": return CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256)
        case "SHA384": return CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA384)
        case "SHA512": return CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512)
        default: return CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)
        }
    }
}
