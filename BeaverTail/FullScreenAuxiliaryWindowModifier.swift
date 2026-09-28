//
//  FullScreenAuxiliaryWindowModifier.swift
//  BeaverTail
//

import AppKit
import SwiftUI

/// A helper that reaches the underlying `NSWindow` backing a SwiftUI scene and
/// configures its `collectionBehavior` so the window can appear *over* another
/// window that is in native macOS full-screen mode.
///
/// Without this, opening a standalone SwiftUI `Window` while the main window is
/// full-screen (and therefore occupying its own Space) makes macOS switch away
/// from the full-screen Space to display the new window on the desktop Space.
/// To the user this looks like the main window has "disappeared" and left only
/// the auxiliary dialogue behind.
///
/// `.fullScreenAuxiliary` lets the window join a full-screen Space as an
/// auxiliary panel, while `.moveToActiveSpace` ensures it is brought to whatever
/// Space is currently active (i.e. the full-screen main window) rather than
/// forcing a Space switch.
struct FullScreenAuxiliaryWindowConfigurator: NSViewRepresentable {

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The view isn't attached to a window yet inside `makeNSView`, so defer
        // the configuration until it has been added to the window hierarchy.
        DispatchQueue.main.async { [weak view] in
            Self.configure(view?.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Re-apply on updates in case SwiftUI recreates the backing window.
        DispatchQueue.main.async { [weak nsView] in
            Self.configure(nsView?.window)
        }
    }

    private static func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.collectionBehavior.insert(.moveToActiveSpace)
    }
}

extension View {
    /// Attaches the full-screen auxiliary configuration to this view's window so
    /// it can float over a full-screen window instead of triggering a Space switch.
    @ViewBuilder
    func fullScreenAuxiliaryWindow() -> some View {
        background(FullScreenAuxiliaryWindowConfigurator())
    }
}
