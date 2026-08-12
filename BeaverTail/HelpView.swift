//
//  HelpView.swift
//  BeaverTail
//

import SwiftUI

struct HelpView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var viewModel: LogViewModel

    /// The in-window search term used to filter Help sections.
    @State private var searchText: String = ""

    init(viewModel: LogViewModel) {
        self.viewModel = viewModel
    }

    /// Sections filtered by the in-window search field. When the search text is
    /// empty, every section is shown.
    private var filteredSections: [HelpSection] {
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return HelpContent.sections }
        let terms = needle.split(separator: " ").map(String.init)

        return HelpContent.sections.compactMap { section in
            let titleHay = section.title.lowercased()
            // Whole-section match: keep every item when the title matches all terms.
            if terms.allSatisfy({ titleHay.contains($0) }) { return section }

            let matchingItems = section.items.filter { item in
                let hay = "\(section.title) \(item.shortcut ?? "") \(item.description)".lowercased()
                return terms.allSatisfy { hay.contains($0) }
            }
            guard !matchingItems.isEmpty else { return nil }
            return HelpSection(title: section.title, items: matchingItems)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Title ──
            Text("BeaverTail Help")
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 8)

            Divider()

            // ── Search bar ──
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search Help", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.12))
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // ── Content ──
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if filteredSections.isEmpty {
                            Text("No help topics match “\(searchText)”.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 40)
                        } else {
                            ForEach(filteredSections) { section in
                                sectionView(section)
                                    .id(section.title)

                                Divider()
                            }
                        }
                    }
                    .padding(20)
                }
                .onAppear {
                    scrollToRequestedSection(using: proxy)
                }
                .onChange(of: viewModel.helpNavigationToken) { _, _ in
                    scrollToRequestedSection(using: proxy)
                }
            }

            Divider()

            // ── Footer ──
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 420, idealWidth: 540, maxWidth: .infinity,
               minHeight: 360, idealHeight: 520, maxHeight: .infinity)
    }

    /// Scrolls to the section the Help window was asked to open at (if any). Clearing
    /// the in-window search first ensures the target section is present in the list.
    private func scrollToRequestedSection(using proxy: ScrollViewProxy) {
        guard let title = viewModel.helpRequestedSection else { return }
        if !searchText.isEmpty { searchText = "" }
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(title, anchor: .top) }
        }
    }

    @ViewBuilder
    private func sectionView(_ section: HelpSection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(section.title)
                .font(.system(.body, weight: .semibold))
                .foregroundStyle(.primary)

            ForEach(section.items) { item in
                HStack(alignment: .top, spacing: 8) {
                    if let shortcut = item.shortcut {
                        Text(shortcut)
                            .font(.system(.body, design: .monospaced, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(minWidth: 22)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color.secondary.opacity(0.15))
                            )
                            .frame(width: 60, alignment: .trailing)
                    } else {
                        Color.clear.frame(width: 60)
                    }
                    Text(item.description)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
