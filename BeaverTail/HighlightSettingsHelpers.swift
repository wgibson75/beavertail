//
//  HighlightSettingsHelpers.swift
//  BeaverTail
//
//  Small helper views used by HighlightSettingsView.
//

import SwiftUI
import AppKit

// Drag-handle affordance: a subtle grip glyph shown at the leading edge of each
// draggable row (filter or group header) to signal that rows can be dragged to
// reorder / move between groups. Shows a grab cursor on hover.
struct DragHandle: View {
    var help: String
    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(Color(NSColor.tertiaryLabelColor))
            .frame(width: 14)
            .contentShape(Rectangle())
            .help(help)
            .onHover { hovering in
                if hovering { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
    }
}

// Lightweight stand-in used when the list is empty
struct ContentUnavailableLabel: View {
    let text: String
    let systemImage: String
    var body: some View {
        HStack {
            Spacer()
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 22))
                    .foregroundStyle(.tertiary)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 20)
            Spacer()
        }
    }
}
