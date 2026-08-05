//
//  ResetFocusButton.swift
//  BeaverTail
//

import SwiftUI

/// Square "reset focus" control shown above the minimap when a subset of log lines
/// is focused. It has a soft, rounded-square look that brightens and glows on hover
/// to invite clicking; pressing it reveals all hidden lines again.
struct ResetFocusButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isHovering ? Color.accentColor : Color.secondary)
                // Fill the frame supplied by the caller so the control can be sized
                // to match the minimap width and the log-tab height.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovering
                              ? Color.accentColor.opacity(0.24)
                              : Color.secondary.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(isHovering
                                ? Color.accentColor.opacity(0.72)
                                : Color.secondary.opacity(0.20),
                                lineWidth: isHovering ? 1.4 : 1)
                )
                // Layered shadows for a fuller, softer glow on hover.
                .shadow(color: Color.accentColor.opacity(isHovering ? 0.65 : 0),
                        radius: isHovering ? 7 : 0)
                .shadow(color: Color.accentColor.opacity(isHovering ? 0.4 : 0),
                        radius: isHovering ? 13 : 0)
                .scaleEffect(isHovering ? 1.10 : 1.0)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) { isHovering = hovering }
        }
    }
}
