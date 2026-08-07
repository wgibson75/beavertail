//
//  ContentView+TabStrip.swift
//  BeaverTail
//
//  Tab-strip helpers extracted from ContentView to keep that (very large) file
//  within SwiftLint's file-length limit.
//

import SwiftUI
import UniformTypeIdentifiers

extension ContentView {

    /// A single tab "chip" in the tab strip. Extracted from `body` so the very large
    /// main view expression stays within the Swift type-checker's reach.
    func tabView(for tab: LogTab) -> some View {
        let isSelected = viewModel.selectedTabID == tab.id
        let isDragging = draggingTabID == tab.id
        let isHovered = hoveredTabID == tab.id
        // The selected tab is highlighted on its own and must not react to hover;
        // only unselected tabs glow (subtly) under the pointer.
        let showHoverGlow = isHovered && !isSelected && !isDragging
        return HStack(spacing: 5) {
            Text(tab.name)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.secondary))
                .lineLimit(1)
                .brightness(showHoverGlow ? 0.16 : 0)
                .shadow(color: Color.accentColor.opacity(showHoverGlow ? 0.4 : 0), radius: showHoverGlow ? 5 : 0)
                .animation(.easeOut(duration: 0.16), value: isHovered)

            Button {
                viewModel.closeTab(id: tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .opacity(isDragging ? 0 : 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            ZStack {
                // Subtle neutral hover wash for unselected tabs (Apple-style light
                // highlight). The selected tab never shows this.
                if showHoverGlow {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                }
                // Selected tab: a softly raised, neutral card with a gentle shadow —
                // the standard macOS selected-tab appearance. Hidden while dragging so
                // the origin reads as a gap.
                if isSelected && !isDragging {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(NSColor.controlBackgroundColor))
                        .shadow(color: .black.opacity(0.16), radius: 2.5, y: 1)
                }
                // Good/Bad/unique colour tint, layered over the raised card (selected)
                // or shown as a flat wash (unselected), so tabs stay colour-coded while
                // keeping the standard look.
                if tab.isUniqueLinesTab && !isDragging {
                    // Unsaved unique-lines results tab: a yellow tint to signal it
                    // hasn't been saved yet. Once saved it becomes a normal tab.
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.yellow.opacity(isSelected ? 0.30 : 0.18))
                        .help("Unique lines — not yet saved")
                } else if let mark = tab.mark, !isDragging {
                    let markColor = mark == .good ? Color.green : Color.red
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(markColor.opacity(isSelected ? 0.26 : 0.15))
                        .help(mark == .good ? "Marked as Good Log" : "Marked as Bad Log")
                }
                // Crisp hairline border on top of the selected card so the active tab
                // is cleanly outlined regardless of any colour tint beneath.
                if isSelected && !isDragging {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color(NSColor.separatorColor), lineWidth: 0.5)
                }
                // Placeholder "slot" shown at the dragged tab's current position: a
                // soft, dashed outline that clearly marks where the tab will land.
                if isDragging {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(
                                    Color.accentColor.opacity(0.55),
                                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                                )
                        )
                }
            }
            .animation(.easeOut(duration: 0.16), value: isHovered)
        }
        .contentShape(Rectangle())
        // Collapse the dragged tab into a slim placeholder so the surrounding tabs
        // visibly open up a gap for it.
        .opacity(isDragging ? 0.5 : 1.0)
        .scaleEffect(isDragging ? 0.92 : 1.0, anchor: .center)
        .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isDragging)
        .onHover { hovering in
            if hovering {
                hoveredTabID = tab.id
            } else if hoveredTabID == tab.id {
                hoveredTabID = nil
            }
        }
        .onTapGesture {
            viewModel.selectedTabID = tab.id
            viewModel.triggerLazyLoadForTab(id: tab.id)
        }
        .onDrag {
            draggingTabID = tab.id
            return NSItemProvider(object: tab.id.uuidString as NSString)
        } preview: {
            // A floating "lifted" card that follows the pointer, so the user can
            // clearly see the tab being moved.
            TabDragPreview(name: tab.name)
        }
        .onDrop(
            of: [UTType.plainText],
            delegate: TabDropDelegate(
                targetTab: tab,
                tabs: $viewModel.openTabs,
                draggingTabID: $draggingTabID
            )
        )
        .modifier(ConditionalTabContextMenu(
            isEnabled: !tab.isUniqueLinesTab,
            menu: { tabContextMenu(for: tab) }
        ))
        .accessibilityIdentifier("logTab-\(tab.name)")
    }

    /// Horizontally scrolls the tab strip so the tab to reveal (a pending
    /// restore target, else the current selection) is brought into view. Deferred
    /// to the next run-loop tick so the strip has been laid out before scrolling.
    func revealSelectedTab(using proxy: ScrollViewProxy, animated: Bool) {
        guard let id = viewModel.tabToRevealID ?? viewModel.selectedTabID else { return }
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            } else {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }
}
