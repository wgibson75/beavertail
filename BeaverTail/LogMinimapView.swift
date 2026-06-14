//
//  LogMinimapView.swift
//  BeaverTail
//
//  Created by William Gibson on 13/06/2026.
//

import SwiftUI

struct LogMinimapView: View {
    @ObservedObject var viewModel: LogViewModel

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
                if let fraction = viewModel.selectedFraction {
                    Rectangle()
                        .fill(Color.primary.opacity(0.45))
                        .frame(height: 2.0)
                        // RESTORED: Removed the inversion math wrapper properties completely
                        .offset(y: fraction * geometry.size.height - 1)
                        .allowsHitTesting(false)
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
                    // ADD THIS BLOCK: Releases the lock the instant the mouse button is lifted
                    .onEnded { _ in
                        viewModel.isScrubbingMinimap = false
                    }
            )
        }
    }
}
