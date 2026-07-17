//
//  LogMinimapView.swift
//  BeaverTail
//

import SwiftUI

struct LogMinimapView: View {
    @ObservedObject var viewModel: LogViewModel

    // Drives the momentary "glow" of the current-position indicator whenever the
    // mouse pointer moves into the minimap region. 0 = resting, 1 = fully glowing.
    @State private var glowIntensity: Double = 0

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                // Background Frame Layout Panel
                Color(NSColor.windowBackgroundColor)

                // LAYER 1: THE FLAT STATIC IMAGE BITMAP
                if let image = viewModel.minimapImage {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none) // Keeps color boundaries crisp and un-blurred
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }

                // LAYER 2: LIGHTWEIGHT OVERLAY INDICATOR
                // Fall back to the top of the log (fraction 0) before the user has
                // navigated anywhere, so the current-position line still exists and
                // can shimmer on hover immediately after a log first loads.
                if viewModel.minimapImage != nil {
                    let fraction = viewModel.selectedFraction ?? 0
                    ZStack {
                        // GLOW HALO: a thicker, blurred, tinted line that swells and
                        // fades in as the pointer enters, giving the line its glow.
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(height: 2.0 + glowIntensity * 5.0)
                            .blur(radius: 1.0 + glowIntensity * 3.5)
                            .opacity(glowIntensity * 0.9)
                            .shadow(color: Color.accentColor.opacity(glowIntensity * 0.9),
                                    radius: glowIntensity * 6.0)

                        // CORE LINE: always-visible position indicator that brightens
                        // momentarily along with the glow.
                        Rectangle()
                            .fill(Color.primary.opacity(0.45 + glowIntensity * 0.55))
                            .frame(height: 2.0)
                    }
                    // RESTORED: Removed the inversion math wrapper properties completely
                    .offset(y: fraction * geometry.size.height - 1)
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onHover { isInside in
                guard isInside else { return }
                // Flash to full glow immediately, then let it gently fade back out.
                withAnimation(.easeOut(duration: 0.12)) {
                    glowIntensity = 1.0
                }
                withAnimation(.easeIn(duration: 0.9).delay(0.12)) {
                    glowIntensity = 0.0
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let clickHeight = value.location.y
                        let totalHeight = geometry.size.height
                        guard totalHeight > 0 else { return }

                        let fraction = clickHeight / totalHeight
                        viewModel.jumpToFraction(fraction)
                    }
                    // On release/click, use the same direct jump path as bottom-pane
                    // and timeline selections so the target line is selected,
                    // highlighted and shimmered in the top pane.
                    .onEnded { value in
                        let clickHeight = value.location.y
                        let totalHeight = geometry.size.height
                        guard totalHeight > 0 else { return }

                        viewModel.jumpFromMinimap(fraction: clickHeight / totalHeight)
                    }
            )
        }
    }
}
