import AppKit
import SwiftUI

struct EditableResolutionComboBox: NSViewRepresentable {
    @Binding var value: String
    let options: [String]
    let commit: (String) -> Void

    final class Coordinator: NSObject, NSComboBoxDelegate, NSTextFieldDelegate {
        var parent: EditableResolutionComboBox
        init(_ parent: EditableResolutionComboBox) { self.parent = parent }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let combo = notification.object as? NSComboBox else { return }
            let selection = combo.stringValue
            parent.value = selection
            parent.commit(selection)
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let combo = notification.object as? NSComboBox else { return }
            parent.value = combo.stringValue
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let combo = notification.object as? NSComboBox else { return }
            parent.value = combo.stringValue
            parent.commit(combo.stringValue)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSComboBox {
        let combo = NSComboBox(frame: .zero)
        combo.isEditable = true
        combo.completes = true
        combo.numberOfVisibleItems = 10
        combo.delegate = context.coordinator
        combo.addItems(withObjectValues: options)
        combo.stringValue = value
        return combo
    }
    func updateNSView(_ combo: NSComboBox, context: Context) {
        context.coordinator.parent = self
        if combo.objectValues.map({ "\($0)" }) != options {
            combo.removeAllItems()
            combo.addItems(withObjectValues: options)
        }
        if combo.stringValue != value && combo.currentEditor() == nil {
            combo.stringValue = value
        }
    }
}
