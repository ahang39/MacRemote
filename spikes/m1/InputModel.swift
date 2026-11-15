// M1 isolated scancode state-model probe; does not inject any macOS input.
// Run: swift spikes/m1/InputModel.swift

import Foundation

struct PhysicalKey: Hashable, CustomStringConvertible {
    let scanCode: UInt8
    let extended: Bool
    let extended1: Bool

    var description: String {
        "\(extended1 ? "E1" : extended ? "E0" : "00"):\(String(format: "%02X", scanCode))"
    }
}

enum KeyTransition: Equatable {
    case down
    case repeated
    case up
}

struct NormalizedKey: Equatable {
    let key: PhysicalKey
    let transition: KeyTransition
}

final class InputModel {
    private var held: Set<PhysicalKey> = []
    private var pressOrder: [PhysicalKey] = []

    // Extended and Extended1 must stay distinct for scancode dispatch.
    func receive(_ key: PhysicalKey, pressed: Bool) -> [NormalizedKey] {
        if pressed {
            if held.contains(key) {
                return [NormalizedKey(key: key, transition: .repeated)]
            }
            held.insert(key)
            pressOrder.append(key)
            return [NormalizedKey(key: key, transition: .down)]
        }
        guard held.remove(key) != nil else { return [] }
        pressOrder.removeAll { $0 == key }
        return [NormalizedKey(key: key, transition: .up)]
    }

    // A disconnect cannot leave modifiers or mouse buttons logically pressed.
    func releaseAll() -> [NormalizedKey] {
        let result = pressOrder.reversed().map { NormalizedKey(key: $0, transition: .up) }
        held.removeAll()
        pressOrder.removeAll()
        return result
    }

    var pressedCount: Int { held.count }
}

func expect(_ test: Bool, _ name: String) {
    guard test else { fatalError("FAIL: \(name)") }
    print("PASS \(name)")
}

let insert = PhysicalKey(scanCode: 0x52, extended: true, extended1: false)
let keypadZero = PhysicalKey(scanCode: 0x52, extended: false, extended1: false)
let printScreen = PhysicalKey(scanCode: 0x37, extended: true, extended1: false)
let keypadMultiply = PhysicalKey(scanCode: 0x37, extended: false, extended1: false)
let pauseCtrl = PhysicalKey(scanCode: 0x1D, extended: false, extended1: true)
let plainCtrl = PhysicalKey(scanCode: 0x1D, extended: false, extended1: false)
let leftShift = PhysicalKey(scanCode: 0x2A, extended: false, extended1: false)
let input = InputModel()

expect(insert != keypadZero, "Insert (E0 52) != keypad 0")
expect(printScreen != keypadMultiply, "Print Screen (E0 37) != keypad *")
expect(pauseCtrl != plainCtrl, "Pause E1 Ctrl != ordinary Ctrl")
expect(input.receive(insert, pressed: true).first?.transition == .down, "Insert down preserved")
expect(input.receive(keypadZero, pressed: true).first?.transition == .down, "Keypad zero independently held")
expect(input.pressedCount == 2, "Distinct scancode state tracking")
expect(input.receive(insert, pressed: true).first?.transition == .repeated, "Repeat not silently discarded")
expect(input.receive(insert, pressed: false).first?.transition == .up, "Insert key release")
expect(input.receive(insert, pressed: false).isEmpty, "Spurious duplicate release ignored")
expect(input.pressedCount == 1, "Other key remains held")
expect(input.receive(plainCtrl, pressed: true).first?.transition == .down, "Ctrl modifier press")
expect(input.receive(leftShift, pressed: true).first?.transition == .down, "Shift modifier press")
let cleanup = input.releaseAll()
expect(cleanup.map(\.key) == [leftShift, plainCtrl, keypadZero], "Reverse-order disconnect cleanup")
expect(input.pressedCount == 0, "No stuck pressed state after disconnect")
expect(input.releaseAll().isEmpty, "Disconnect cleanup is idempotent")
print("RESULT: 15 input-model assertions passed (no real HID injection).")
