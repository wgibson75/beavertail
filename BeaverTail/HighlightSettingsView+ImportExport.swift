//
//  HighlightSettingsView+ImportExport.swift
//  BeaverTail
//
//  JSON import/export for the Highlight Filters window. Split out of
//  HighlightSettingsView.swift to keep that file focused on the view/editing UI.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension HighlightSettingsView {
    // MARK: - Import / export

    func exportRules() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "HighlightFilters.json"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(makeExportDocument())
                try data.write(to: url)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Export Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .critical
                alert.runModal()
            }
        }
    }

    /// Builds the nested export document from the current flat rules + groups, emitting
    /// each group (with its members nested) at the position of its first member, and
    /// any empty groups up front — mirroring how the list is displayed.
    private func makeExportDocument() -> HighlightFiltersDocument {
        let rules = rulesStore.rules
        let groups = rulesStore.groups
        let groupedIDs = Set(rules.compactMap { $0.groupID })

        func dto(_ rule: HighlightRule) -> HighlightFilterRuleDTO {
            .init(pattern: rule.pattern,
                  foregroundColorHex: rule.foregroundColorHex,
                  backgroundColorHex: rule.backgroundColorHex,
                  isCaseSensitive: rule.isCaseSensitive,
                  isEnabled: rule.isEnabled)
        }

        var items: [HighlightFilterItem] = []
        // Empty groups (no members) are preserved at the top.
        for group in groups where !groupedIDs.contains(group.id) {
            items.append(.group(.init(groupName: group.label, isEnabled: group.isEnabled, rules: [])))
        }
        var emitted = Set<UUID>()
        for rule in rules {
            guard let gid = rule.groupID else {
                items.append(.rule(dto(rule)))
                continue
            }
            if emitted.contains(gid) { continue }
            emitted.insert(gid)
            let group = groups.first(where: { $0.id == gid })
            let members = rules.filter { $0.groupID == gid }.map(dto)
            items.append(.group(.init(groupName: group?.label ?? "",
                                      isEnabled: group?.isEnabled ?? true,
                                      rules: members)))
        }
        return HighlightFiltersDocument(rules: items)
    }

    func importRules() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                // Prefer the nested grouped format; fall back to a bare rules array so
                // files saved by earlier (pre-grouping) versions still import correctly.
                if let doc = try? decoder.decode(HighlightFiltersDocument.self, from: data) {
                    applyImportedDocument(doc)
                } else {
                    let rules = try decoder.decode([HighlightRule].self, from: data)
                    rulesStore.groups = []
                    rulesStore.rules = rules
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Import Failed"
                alert.informativeText = "Could not read highlight rules. \(error.localizedDescription)"
                alert.alertStyle = .critical
                alert.runModal()
            }
        }
    }

    /// Flattens the nested import document into the store's `rules` (each tagged with its
    /// group's freshly-minted `id`) and `groups`, preserving order.
    private func applyImportedDocument(_ doc: HighlightFiltersDocument) {
        func rule(_ dto: HighlightFilterRuleDTO, groupID: UUID?) -> HighlightRule {
            HighlightRule(pattern: dto.pattern,
                          foregroundColorHex: dto.foregroundColorHex,
                          backgroundColorHex: dto.backgroundColorHex,
                          isCaseSensitive: dto.isCaseSensitive,
                          isEnabled: dto.isEnabled,
                          groupID: groupID)
        }

        var newRules: [HighlightRule] = []
        var newGroups: [HighlightGroup] = []
        for item in doc.rules {
            switch item {
            case .rule(let dto):
                newRules.append(rule(dto, groupID: nil))
            case .group(let groupDTO):
                let group = HighlightGroup(label: groupDTO.groupName, isEnabled: groupDTO.isEnabled)
                newGroups.append(group)
                newRules.append(contentsOf: groupDTO.rules.map { rule($0, groupID: group.id) })
            }
        }
        rulesStore.groups = newGroups
        rulesStore.rules = newRules
    }
}
