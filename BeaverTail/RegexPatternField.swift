//
//  RegexPatternField.swift
//  BeaverTail
//
//  AppKit-backed single-line field for the Highlight Filters "Regex pattern"
//  input. Unlike SwiftUI's TextField, it lets us control the text-selection
//  highlight colours, so dragging to select text stays high-contrast for any
//  combination of the rule's foreground/background colours and in both light
//  and dark mode.
//

import AppKit
import SwiftUI

struct RegexPatternField: NSViewRepresentable {
    @Binding var text: String
    var foreground: Color
    var background: Color
    var placeholder: String
    /// Change this value to programmatically move focus to the field.
    var focusToken: Int
    /// Change this value to programmatically blur the field.
    var blurToken: Int
    var onSubmit: () -> Void
    /// Called when the field resigns first responder (e.g. the user clicks away).
    var onEndEditing: () -> Void = {}

    func makeNSView(context: Context) -> SelectionStyledTextField {
        let field = SelectionStyledTextField()
        field.isBordered = false
        field.drawsBackground = false          // SwiftUI draws the rounded background
        field.focusRingType = .none
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.lineBreakMode = .byClipping
        field.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.stringValue = text
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: SelectionStyledTextField, context: Context) {
        context.coordinator.parent = self

        let fg = NSColor(foreground)
        nsView.textColor = fg
        nsView.fieldBackground = NSColor(background)
        nsView.refreshSelectionColours()

        nsView.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: SelectionStyledTextField.placeholderColour(fieldBackground: NSColor(background)),
                .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            ]
        )

        if !context.coordinator.isEditing, nsView.stringValue != text {
            nsView.stringValue = text
        }

        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async {
                guard let window = nsView.window else { return }
                window.makeFirstResponder(nsView)
                nsView.currentEditor()?.selectedRange = NSRange(location: nsView.stringValue.count, length: 0)
            }
        }
        if context.coordinator.lastBlurToken != blurToken {
            context.coordinator.lastBlurToken = blurToken
            DispatchQueue.main.async {
                if let window = nsView.window, window.firstResponder == nsView.currentEditor() {
                    window.makeFirstResponder(nil)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RegexPatternField
        var isEditing = false
        var lastFocusToken = 0
        var lastBlurToken = 0

        init(_ parent: RegexPatternField) { self.parent = parent }

        func controlTextDidBeginEditing(_ obj: Notification) { isEditing = true }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            isEditing = false
            parent.onEndEditing()
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

/// An NSTextField that styles its text-selection highlight for high contrast,
/// derived from the field's own background colour and the current appearance.
final class SelectionStyledTextField: NSTextField {
    /// The colour drawn behind the field (used to pick a contrasting highlight).
    var fieldBackground: NSColor = .textBackgroundColor

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { applySelectionColours() }
        return accepted
    }

    /// Re-apply the selection colours if the field is currently being edited
    /// (e.g. after the rule's colours change via the colour wells).
    func refreshSelectionColours() {
        if window?.firstResponder == currentEditor() { applySelectionColours() }
    }

    private func applySelectionColours() {
        guard let editor = currentEditor() as? NSTextView else { return }
        let colours = Self.selectionColours(fieldBackground: fieldBackground)
        editor.selectedTextAttributes = [
            .backgroundColor: colours.background,
            .foregroundColor: colours.foreground
        ]
    }

    /// Choose a selection highlight that contrasts with the field background,
    /// plus a selected-text colour that contrasts with that highlight. Works for
    /// arbitrary rule colours and in both light and dark mode.
    static func selectionColours(fieldBackground: NSColor) -> (background: NSColor, foreground: NSColor) {
        let bgLum = luminance(fieldBackground)
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? NSColor.systemBlue

        var selectionBackground = accent
        // If the accent is too close to the field background, fall back to a
        // deep/light blue chosen to contrast with the background instead.
        if abs(luminance(accent) - bgLum) < 0.30 {
            selectionBackground = bgLum > 0.5
                ? NSColor(red: 0.15, green: 0.22, blue: 0.48, alpha: 1)   // deep blue on light bg
                : NSColor(red: 0.60, green: 0.76, blue: 1.0, alpha: 1)    // light blue on dark bg
        }

        let selectionForeground: NSColor = luminance(selectionBackground) > 0.55 ? .black : .white
        return (selectionBackground, selectionForeground)
    }

    /// A medium-contrast placeholder colour for the given field background:
    /// a darker grey on light backgrounds, a lighter grey on dark backgrounds
    /// so the prompt stays clearly visible in both light and dark mode.
    static func placeholderColour(fieldBackground: NSColor) -> NSColor {
        if luminance(fieldBackground) > 0.5 {
            return NSColor(red: 0.35, green: 0.35, blue: 0.35, alpha: 1)   // dark grey on light bg
        } else {
            return NSColor(red: 0.68, green: 0.68, blue: 0.68, alpha: 1)   // light grey on dark bg
        }
    }

    private static func luminance(_ color: NSColor) -> CGFloat {
        let c = color.usingColorSpace(.sRGB) ?? color
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
    }
}
