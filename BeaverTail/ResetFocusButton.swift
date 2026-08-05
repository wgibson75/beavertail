//
//  ResetFocusButton.swift
//  BeaverTail
//

import SwiftUI

/// Borderless "reset focus" control shown above the minimap when a subset of log
/// lines is focused. It shows just the counter-clockwise arrow, which brightens and
/// glows on hover to invite clicking; pressing it reveals all hidden lines again.
struct ResetFocusButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(isHovering ? Color.accentColor : Color.secondary)
                // Fill the frame supplied by the caller so the control can be sized
                // to match the minimap width and the log-tab height.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // No border or background — just the bare arrow. Layered accent
                // shadows make the arrow itself glow on hover to invite clicking.
                .shadow(color: Color.accentColor.opacity(isHovering ? 0.9 : 0),
                        radius: isHovering ? 6 : 0)
                .shadow(color: Color.accentColor.opacity(isHovering ? 0.6 : 0),
                        radius: isHovering ? 12 : 0)
                .scaleEffect(isHovering ? 1.12 : 1.0)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) { isHovering = hovering }
        }
    }
}
