//
//  LogViewModel+Minimap.swift
//  BeaverTail
//
//  Minimap highlight-strip image generation, split out of LogViewModel to keep
//  that file under the SwiftLint file-length limit and to mirror the Timeline
//  split. The view model gathers the inputs and applies the finished result; the
//  heavy Core Graphics work lives in the `MinimapImageRenderer` service.
//

import AppKit
import Combine
import Foundation

extension LogViewModel {
    func generateMinimapData(for tabID: UUID) {
        minimapTasks[tabID]?.cancel()
        guard let index = openTabs.firstIndex(where: { $0.id == tabID }) else { return }
        let activeRules = activeHighlightRules

        guard let content = openTabs[index].content,
              content.count > 0,
              !activeRules.isEmpty,
              openTabs[index].highlightMatches.count == activeRules.count else {
            minimapImageByTab[tabID] = nil
            return
        }

        let cache = openTabs[index].highlightMatches
        let colors = activeRules.map { $0.nsBackgroundColor.cgColor }

        let totalLines = content.count
        // Restrict the minimap to the visible range when lines are hidden so its
        // highlights don't reference lines the user has hidden.
        let vBounds = openTabs[index].visibleBounds(for: totalLines)
        let rangeStart = vBounds?.lower ?? 0
        let rangeEnd = vBounds.map { $0.upper + 1 } ?? totalLines

        // Package the inputs and hand the heavy Core Graphics work to the renderer
        // service; the view model only applies the finished image.
        let input = MinimapRenderInput(
            colors: colors,
            cache: cache,
            rangeStart: rangeStart,
            rangeEnd: rangeEnd,
            imageWidth: 30,
            imageHeight: minimapImageHeight
        )

        minimapTasks[tabID] = Task.detached(priority: .utility) { [weak self] in
            // A nil result means the visible range was empty, an image context
            // could not be created, or a newer render superseded this one — in all
            // cases leave the existing image untouched.
            guard let image = MinimapImageRenderer.render(input), !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.openTabs.contains(where: { $0.id == tabID }) {
                    self.minimapImageByTab[tabID] = image
                }
            }
        }
    }
}
