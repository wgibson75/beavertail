//
//  WindowCloseInterceptor.swift
//  BeaverTail
//
//  Created by William Gibson on 16/06/2026.
//
//  Embeds as a zero-size background view and intercepts the window's close action
//  (⌘W / File ▸ Close / red traffic-light button).
//  When a log tab is open it closes the tab and keeps the window alive;
//  when no tabs remain it lets the window close normally.
//

import AppKit
import SwiftUI

struct WindowCloseInterceptor: NSViewRepresentable {

    /// Return `true` if a tab was consumed (window should stay open),
    /// `false` to let the window close as normal.
    var shouldConsumeClose: () -> Bool

    func makeNSView(context: Context) -> InterceptorView {
        let view = InterceptorView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: InterceptorView, context: Context) {
        context.coordinator.shouldConsumeClose = shouldConsumeClose
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(shouldConsumeClose: shouldConsumeClose)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSWindowDelegate {
        var shouldConsumeClose: () -> Bool
        private weak var managedWindow: NSWindow?
        private weak var previousDelegate: NSWindowDelegate?

        init(shouldConsumeClose: @escaping () -> Bool) {
            self.shouldConsumeClose = shouldConsumeClose
        }

        func attach(to window: NSWindow) {
            guard managedWindow !== window else { return }
            // Chain any pre-existing delegate so we don't break SwiftUI internals
            previousDelegate = window.delegate
            managedWindow = window
            window.delegate = self
        }

        // MARK: NSWindowDelegate

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            // If the close was triggered by a mouse event the user clicked the
            // red traffic-light button — terminate the application.
            if NSApp.currentEvent?.type == .leftMouseUp {
                NSApp.terminate(nil)
                return false
            }
            // Otherwise this is ⌘W (a key event) — consume it to close a tab
            // or do nothing if no tabs are open.
            _ = shouldConsumeClose()
            return false // Never close the window via ⌘W
        }

        // Forward all other delegate messages to the previous delegate
        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (previousDelegate?.responds(to: aSelector) ?? false)
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if previousDelegate?.responds(to: aSelector) == true { return previousDelegate }
            return super.forwardingTarget(for: aSelector)
        }
    }

    // MARK: - NSView subclass

    final class InterceptorView: NSView {
        weak var coordinator: Coordinator?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let win = window {
                coordinator?.attach(to: win)
            }
        }
    }
}
