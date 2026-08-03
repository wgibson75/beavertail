//
//  GroupNameField.swift
//  BeaverTail
//
//  A borderless, inline text field for editing a highlight-group's name. Unlike a
//  plain SwiftUI TextField, it consumes the Return key so pressing Enter commits the
//  name in place instead of falling through to the Highlight Filters dialog's default
//  ("Done") button and closing the window.
//

import AppKit
import SwiftUI

struct GroupNameField: NSViewRepresentable {
    /// The current label to display (kept in sync from the store, e.g. on undo).
    let text: String
    var placeholder: String = "Group name"
    /// Called on every keystroke with the field's latest value.
    var onChange: (String) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.isBordered = false
        field.drawsBackground = false
        field.isEditable = true
        field.isSelectable = true
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.stringValue = text
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.parent = self
        // Only push external changes when the user isn't actively editing.
        if !context.coordinator.isEditing, nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: GroupNameField
        var isEditing = false

        init(_ parent: GroupNameField) { self.parent = parent }

        func controlTextDidBeginEditing(_ obj: Notification) { isEditing = true }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.onChange(field.stringValue)
        }

        func controlTextDidEndEditing(_ obj: Notification) { isEditing = false }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                // Commit in place and consume Return so the dialog's default button
                // (Done) isn't triggered and the window stays open.
                control.window?.makeFirstResponder(nil)
                return true
            }
            return false
        }
    }
}
