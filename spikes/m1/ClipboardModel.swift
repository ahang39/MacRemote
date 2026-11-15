// M1 isolated CF_UNICODETEXT/LF and clipboard-origin model.
// No pasteboard access or keystroke injection.
// Run: swift spikes/m1/ClipboardModel.swift

import Foundation

enum ClipboardDecodeError: Error {
    case oddByteCount, missingTerminator, invalidUTF16
}

func toMacPlainText(_ value: String) -> String {
    value.replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
}

func toWindowsPlainText(_ value: String) -> String {
    toMacPlainText(value).replacingOccurrences(of: "\n", with: "\r\n")
}

func encodeCFUnicodeText(_ value: String) -> [UInt8] {
    let units = Array(toWindowsPlainText(value).utf16) + [UInt16(0)]
    return units.flatMap { [$0 & 0xFF, $0 >> 8].map(UInt8.init) }
}

func decodeCFUnicodeText(_ bytes: [UInt8]) throws -> String {
    guard bytes.count % 2 == 0 else { throw ClipboardDecodeError.oddByteCount }
    let units = stride(from: 0, to: bytes.count, by: 2).map {
        UInt16(bytes[$0]) | (UInt16(bytes[$0 + 1]) << 8)
    }
    guard units.last == 0 else { throw ClipboardDecodeError.missingTerminator }
    let textUnits = Array(units.dropLast())
    let text = String(decoding: textUnits, as: UTF16.self)
    guard Array(text.utf16) == textUnits else { throw ClipboardDecodeError.invalidUTF16 }
    return toMacPlainText(text)
}

final class ClipboardEchoModel {
    // Provisional: real implementations also need ownership, request and timeout state.
    private var ownGenerations: Set<Int> = []

    func wroteRemoteDataAsLocalGeneration(_ id: Int) {
        ownGenerations.insert(id)
    }

    func shouldAdvertiseLocalChange(generation id: Int) -> Bool {
        if ownGenerations.remove(id) != nil { return false }
        return true // Same payload newly copied is still a real event.
    }
}

func expect(_ test: Bool, _ name: String) {
    guard test else { fatalError("FAIL: \(name)") }
    print("PASS \(name)")
}

let inputs = [
    "one\ntwo", "one\n\ntwo", "\none\n", "one\r\ntwo",
    "one\r\n\r\ntwo", "one\rtwo", "one\r\r\ntwo",
    "\n\ntrailing\n\n", "中文👨‍💻\tÅ", "", "a\r\nb\nc\rd"
]

for (index, source) in inputs.enumerated() {
    let target = toMacPlainText(source)
    let decoded = try decodeCFUnicodeText(encodeCFUnicodeText(source))
    expect(decoded == target, "CRLF/LF/Unicode roundtrip fixture \(index + 1)")
    expect(toMacPlainText(target) == target, "Mac normalization idempotent \(index + 1)")
    expect(toWindowsPlainText(toWindowsPlainText(source)) == toWindowsPlainText(source),
           "Windows export idempotent \(index + 1)")
}
do {
    _ = try decodeCFUnicodeText([0x61])
    fatalError("FAIL: invalid odd-length data accepted")
} catch ClipboardDecodeError.oddByteCount {
    print("PASS rejects odd-length UTF-16LE payload")
}
do {
    _ = try decodeCFUnicodeText([0x61, 0x00])
    fatalError("FAIL: missing terminator accepted")
} catch ClipboardDecodeError.missingTerminator {
    print("PASS rejects missing NUL terminator")
}
let echo = ClipboardEchoModel()
echo.wroteRemoteDataAsLocalGeneration(100)
expect(!echo.shouldAdvertiseLocalChange(generation: 100), "Suppress own clipboard echo")
expect(echo.shouldAdvertiseLocalChange(generation: 101), "Allow subsequent local copy, even if value unchanged")
expect(echo.shouldAdvertiseLocalChange(generation: 102), "No global content-based deduplication")
print("RESULT: 38 clipboard-model assertions passed (no clipboard modifications).")
