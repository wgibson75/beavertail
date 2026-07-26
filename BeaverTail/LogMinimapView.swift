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

    // Click-drag-release range selection. While the pointer is dragged far enough
    // to count as marking out a time period, these track the drag so a live
    // selection rectangle can be drawn; on release the range is applied.
    @State private var dragStartY: CGFloat?
    @State private var dragCurrentY: CGFloat?
    @State private var isSelectingRange = false

    /// Minimum vertical drag (in points) before a gesture is treated as marking
    /// out a time period rather than a click-to-navigate.
    private let rangeSelectThreshold: CGFloat = 5

    /// Plays the momentary glow/shimmer of the current-position indicator: flash to
    /// full glow immediately, then let it gently fade back out. Shared by the mouse
    /// hover and the programmatic position-change triggers.
    private func playShimmer() {
        withAnimation(.easeOut(duration: 0.12)) {
            glowIntensity = 1.0
        }
        withAnimation(.easeIn(duration: 0.9).delay(0.12)) {
            glowIntensity = 0.0
        }
    }

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

                // LAYER 3: LIVE TIME-PERIOD SELECTION RECTANGLE
                // Shown only while the user is actively dragging out a range.
                if isSelectingRange, let startY = dragStartY, let currentY = dragCurrentY {
                    let minY = max(0, min(startY, currentY))
                    let maxY = min(geometry.size.height, max(startY, currentY))
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.22))
                        .overlay(
                            Rectangle().stroke(Color.accentColor.opacity(0.85), lineWidth: 1)
                        )
                        .frame(width: geometry.size.width, height: max(0, maxY - minY))
                        .offset(y: minY)
                        .allowsHitTesting(false)
                }

                // LAYER 4: CELEBRATORY COLOUR BURST played when a focused subset of
                // lines is reset (Reset button / Show All Lines).
                MinimapBurstView(trigger: viewModel.minimapBurstTrigger)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onHover { isInside in
                guard isInside else { return }
                playShimmer()
            }
            // Also shimmer when the position changes programmatically — mark-block
            // navigation (up/down arrows) and left-click jumps on the minimap both
            // bump this trigger so the new current position momentarily glows.
            .onChange(of: viewModel.minimapShimmerTrigger) { _, _ in
                playShimmer()
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let totalHeight = geometry.size.height
                        guard totalHeight > 0 else { return }
                        if dragStartY == nil { dragStartY = value.startLocation.y }
                        dragCurrentY = value.location.y
                        // Once the drag moves beyond the threshold, switch from a
                        // potential click into marking out a time period; the live
                        // selection rectangle is drawn instead of scrubbing.
                        if abs(value.location.y - value.startLocation.y) >= rangeSelectThreshold {
                            isSelectingRange = true
                        }
                    }
                    // On release: a meaningful drag marks out a time period and hides
                    // lines outside it; a click (below the threshold) uses the same
                    // direct jump path as bottom-pane and timeline selections so the
                    // target line is selected, highlighted and shimmered.
                    .onEnded { value in
                        let totalHeight = geometry.size.height
                        let wasSelecting = isSelectingRange
                        dragStartY = nil
                        dragCurrentY = nil
                        isSelectingRange = false
                        guard totalHeight > 0 else { return }

                        let startY = value.startLocation.y
                        let endY = value.location.y

                        if wasSelecting || abs(endY - startY) >= rangeSelectThreshold {
                            viewModel.selectTimePeriod(
                                fromFraction: min(startY, endY) / totalHeight,
                                toFraction: max(startY, endY) / totalHeight
                            )
                        } else {
                            viewModel.jumpFromMinimap(fraction: endY / totalHeight)
                        }
                    }
            )
            // Right-click anywhere on the minimap to step back one zoom level:
            // restores the previously-defined time period (or reveals all lines once
            // the history is exhausted). Only intercepts right-clicks, so left-click
            // navigation and drag selection are unaffected.
            .overlay(
                MinimapRightClickCatcher {
                    viewModel.stepBackTimePeriod()
                }
            )
        }
    }
}

// MARK: - Colour Burst

/// One soft, glowing mote in the minimap reset cloud. Scattered across the minimap
/// (`x`/`y`, offsets from centre), it gently drifts and expands as it fades, so the
/// whole thing reads as a colourful glowing cloud dissipating rather than particles
/// rushing to a point.
private struct BurstParticle: Identifiable {
    let id = UUID()
    let x: CGFloat
    let y: CGFloat
    let driftX: CGFloat
    let driftY: CGFloat
    let size: CGFloat
    let blur: CGFloat
    let color: Color
    let baseOpacity: Double
    let delay: Double
    let duration: Double
}

/// Plays a momentary, cloud-like glow: a colourful haze of soft motes blooms across
/// the minimap and gently drifts + expands as it fades out, whenever `trigger`
/// changes. Used to celebrate resetting a focused subset of lines back to the full
/// log.
private struct MinimapBurstView: View {
    let trigger: Int

    @State private var particles: [BurstParticle] = []
    @State private var appeared = false
    @State private var dissipated = false

    private static let palette: [Color] = [
        .red, .orange, .yellow, .green, .blue, .purple, .pink, .cyan, .mint, .indigo, .teal
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(particles) { particle in
                    Circle()
                        .fill(particle.color)
                        .frame(width: particle.size, height: particle.size)
                        // Soft edges + a coloured halo make each mote read as glowing haze.
                        // The blur grows as it dissipates so the mote melts away softly.
                        .blur(radius: dissipated ? particle.blur * 1.7 : particle.blur)
                        .shadow(color: particle.color.opacity(dissipated ? 0 : (appeared ? 0.7 : 0)),
                                radius: particle.size * 0.7)
                        // Step 1: fade/scale in gently. Step 2: bloom outward, drift and fade.
                        .scaleEffect(dissipated ? 1.6 : (appeared ? 1.0 : 0.5))
                        .opacity(dissipated ? 0 : (appeared ? particle.baseOpacity : 0))
                        .offset(
                            x: dissipated ? particle.x + particle.driftX : particle.x,
                            y: dissipated ? particle.y + particle.driftY : particle.y
                        )
                        // A soft fade-in, then a long, gently easing-out drift so the
                        // cloud tails off slowly and subtly — staggered by each mote's delay.
                        .animation(.easeOut(duration: 0.17).delay(particle.delay), value: appeared)
                        .animation(.easeOut(duration: particle.duration).delay(particle.delay),
                                   value: dissipated)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
            .onChange(of: trigger) { _, _ in
                bloom(in: geo.size)
            }
        }
    }

    private func bloom(in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let count = 320
        let halfW = size.width / 2
        let halfH = size.height / 2
        // Fresh identities each burst so replacing the array cleanly resets the cloud
        // to its scattered state (no reverse animation) before it dissipates again.
        particles = (0..<count).map { _ in
            // Scatter motes across the whole minimap; a little horizontal overspill
            // lets the glow bleed softly past the narrow strip's edges.
            let size = CGFloat.random(in: 2.5 ... 18)
            return BurstParticle(
                x: CGFloat.random(in: -halfW * 1.3 ... halfW * 1.3),
                y: CGFloat.random(in: -halfH ... halfH),
                driftX: CGFloat.random(in: -9 ... 9),
                driftY: CGFloat.random(in: -13 ... 13),
                size: size,
                // Bigger motes are softer/blurrier, reading as glowing cloud puffs.
                blur: size * CGFloat.random(in: 0.35 ... 0.6) + 0.5,
                color: Self.palette.randomElement() ?? .accentColor,
                baseOpacity: Double.random(in: 0.12 ... 0.38),
                delay: Double.random(in: 0 ... 0.15),
                duration: Double.random(in: 1.0 ... 1.8)
            )
        }
        // Reset both phases so the fresh cloud starts invisible and gathered.
        appeared = false
        dissipated = false
        // Step 1: let the cloud gently fade/scale in on the next tick.
        DispatchQueue.main.async {
            appeared = true
        }
        // Step 2: after it has bloomed in, let it drift, expand and fade away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            dissipated = true
        }
    }
}

/// A transparent AppKit overlay that reports right-clicks (secondary mouse button)
/// without consuming any other events, so SwiftUI gestures beneath it continue to
/// receive left-clicks and drags normally.
private struct MinimapRightClickCatcher: NSViewRepresentable {
    var onRightClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        CatcherView(onRightClick: onRightClick)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.onRightClick = onRightClick
    }

    private final class CatcherView: NSView {
        var onRightClick: () -> Void

        init(onRightClick: @escaping () -> Void) {
            self.onRightClick = onRightClick
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        // Claim the point only for secondary-button events; return nil for
        // everything else so left-clicks/drags fall through to the SwiftUI view.
        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
                return super.hitTest(point)
            default:
                return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            onRightClick()
        }
    }
}
