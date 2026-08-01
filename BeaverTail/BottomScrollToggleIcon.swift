//
//  BottomScrollToggleIcon.swift
//  BeaverTail
//
import SwiftUI

/// Toolbar icon for the "scroll long lines when clicking twice in the bottom pane"
/// toggle: a mouse-click pointer drawn *above* a dashed, double-ended horizontal arrow
/// (small arrowheads at each end), conveying "click → horizontal scroll".
struct BottomScrollToggleIcon: View {
    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "cursorarrow.click")
                .font(.system(size: 11))
            HStack(spacing: 1) {
                Image(systemName: "arrowtriangle.left.fill")
                    .font(.system(size: 4))
                DashedLine()
                    .stroke(style: StrokeStyle(lineWidth: 1, lineCap: .butt, dash: [2, 1.5]))
                    .frame(width: 5, height: 1)
                Image(systemName: "arrowtriangle.right.fill")
                    .font(.system(size: 4))
            }
        }
        // Square footprint keeps the toggle button perfectly round (matching the
        // neighbouring icons); the extra width leaves a margin so the arrow tips
        // never touch the circular border.
        .frame(width: 16, height: 16)
        .offset(y: -1)
    }
}

/// A simple horizontal line through the vertical centre of its frame, used with a
/// dashed stroke style to draw the double-ended arrow's shaft.
private struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
