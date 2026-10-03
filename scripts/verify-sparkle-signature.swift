// Verifies a Sparkle EdDSA (Ed25519) signature over a whole file against a public key, the check
// Sparkle runs in the app before it applies an update. release.sh calls it with SUPublicEDKey from
// Resources/Info.plist, so a DMG signed with any other key fails the release instead of every update.
//
//   swift scripts/verify-sparkle-signature.swift <file> <base64-signature> <base64-public-key>
//
// Exit 0: valid. Exit 1: the signature does not verify. Exit 64: bad arguments or unreadable input.
import CryptoKit
import Foundation

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: verify-sparkle-signature.swift <file> <base64-signature> <base64-public-key>\n".utf8))
    exit(64)
}
let path = arguments[arguments.startIndex]
let signatureText = arguments[arguments.startIndex + 1]
let keyText = arguments[arguments.startIndex + 2]

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data("verify-sparkle-signature: \(message)\n".utf8))
    exit(code)
}

guard let signature = Data(base64Encoded: signatureText), signature.count == 64 else {
    fail("the signature is not 64 bytes of base64", 64)
}
guard let keyData = Data(base64Encoded: keyText),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
else { fail("the public key is not 32 bytes of base64", 64) }
guard let contents = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)", 64) }

guard key.isValidSignature(signature, for: contents) else {
    fail("\(path): the EdDSA signature does not verify against the public key", 1)
}
print("verify-sparkle-signature: \(path): EdDSA signature verifies")
