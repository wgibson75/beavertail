//
//  TimestampBubbleView.swift
//  BeaverTail
//
//  The timestamp label shown in the upper pane for the active line. Its accent
//  background covers the whole label and softly feathers at the edges.
//

import SwiftUI
import AppKit

struct TimestampBubbleView: View {
    let text: String
    /// Base opacity of the accent fill (dimmer when the pane is filtered).
    let baseOpacity: Double

    private var accent: Color { Color(NSColor.controlAccentColor) }

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundColor(.white)
            .shadow(color: .black.opacity(0.4), radius: 1, y: 0.5)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(background)
    }

    private var background: some View {
        GeometryReader { geo in
            let corner = min(geo.size.height * 0.5, 11)
            ZStack {
                // Accent fill that covers the whole label (full height right to the
                // left and right ends), just a touch brighter through the centre so it
                // still reads as blooming from the middle.
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: accent.opacity(baseOpacity * 0.85), location: 0.0),
                        .init(color: accent.opacity(baseOpacity), location: 0.5),
                        .init(color: accent.opacity(baseOpacity * 0.85), location: 1.0)
                    ]),
                    startPoint: .leading,
                    endPoint: .trailing
                )

                // A soft glossy bloom in the upper-centre for a rounded, glassy feel.
                RadialGradient(
                    gradient: Gradient(colors: [.white.opacity(0.20), .white.opacity(0.0)]),
                    center: UnitPoint(x: 0.5, y: 0.3),
                    startRadius: 0,
                    endRadius: geo.size.height
                )
                .blendMode(.plusLighter)
            }
            // Feather every edge uniformly so there is no hard border, while keeping
            // the label full-height all the way to its left and right ends.
            .mask(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(.white)
                    .padding(3)
                    .blur(radius: 4)
            )
        }
    }
}
