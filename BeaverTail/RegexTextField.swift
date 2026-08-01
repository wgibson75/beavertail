//
//  RegexTextField.swift
//  BeaverTail
//
//  AppKit-backed text field used for the regex Filter input. Wraps a custom
//  NSTextField subclass to provide reliable focus / click / blur / change
//  callbacks inside AppKit-backed containers such as VSplitView.
//

import AppKit
import SwiftUI

// becomeFirstResponder fires when the field gains focus; mouseDown fires on
// every click on the field itself, unlike controlTextDidBeginEditing which
// only fires once per editing session.
final class FocusableTextField: NSTextField {
    var onBecomeFirstResponder: (() -> Void)?
    var onMouseDown: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onBecomeFirstResponder?() }
        return accepted
    }

    // Fires on every click on the field itself (i.e. when it is not already being
    // edited by the shared field editor). This re-shows the history dropdown even
    // when the field never lost first-responder status — e.g. after the view is
    // reused across a tab switch — where `becomeFirstResponder` would not fire.
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onMouseDown?()
    }
}

struct RegexTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onFocus: () -> Void
    let onTextChange: () -> Void
    let onBlur: () -> Void
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> FocusableTextField {
        let field = FocusableTextField()
        field.placeholderString = placeholder
        field.bezelStyle = .roundedBezel
        field.isBordered = true
        field.isEditable = true
        field.isSelectable = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        field.stringValue = text
        field.delegate = context.coordinator
        let coordinator = context.coordinator
        field.onBecomeFirstResponder = {
            coordinator.parent.onFocus()
        }
        field.onMouseDown = {
            coordinator.parent.onFocus()
        }
        return field
    }

    func updateNSView(_ nsView: FocusableTextField, context: Context) {
        context.coordinator.parent = self
        // Re-wire the callbacks so they always use the latest closures
        let coordinator = context.coordinator
        nsView.onBecomeFirstResponder = {
            coordinator.parent.onFocus()
        }
        nsView.onMouseDown = {
            coordinator.parent.onFocus()
        }
        // Only push programmatic text changes when the user isn't mid-edit
        if !context.coordinator.isEditing, nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RegexTextField
        var isEditing = false

        init(_ parent: RegexTextField) { self.parent = parent }

        func controlTextDidBeginEditing(_ obj: Notification) {
            isEditing = true
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
            parent.onTextChange()
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            isEditing = false
            parent.onBlur()
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}
