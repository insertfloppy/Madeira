// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
//  FOMOD installers and Bethesda plugin lists, for Game details › Mods.
//
//  Many Nexus mods (lighting and texture overhauls above all) ship a
//  fomod/ModuleConfig.xml with option folders ("00 Core", "01 Optional ...")
//  instead of a ready Data folder. Mod managers read that file and ask which
//  options to install; Fomod does the same: the required files, each install
//  step with its option groups (Select exactly one / at most one / at least
//  one / all / any), option types (required, recommended, not usable, and the
//  ones that depend on flags or on plugins being there), flags set by the
//  chosen options, steps shown only for some flags, and conditional files.
//  Destinations are relative to the game's Data folder for Bethesda games
//  (as in Vortex and Mod Organizer), else to the game's folder.
//
//  A plugin (.esp/.esm/.esl) in Data does nothing until the game's
//  plugins.txt (%LOCALAPPDATA%\<game>\plugins.txt) lists it. BethesdaPlugins
//  adds a mod's plugins there on install and takes them out on Remove; for
//  Fallout 3 and New Vegas it also turns on loose files
//  (bInvalidateOlderFiles in Fallout.ini) so loose meshes and textures win
//  over the game's archives.
//
//  Foundation only (XMLParser): tests/host/check-mod-fomod.py compiles this
//  file with a test harness.
//

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// MARK: XML

final class FomodNode {
    let name: String
    let attributes: [String: String]
    var children: [FomodNode] = []
    var text = ""
    init(name: String, attributes: [String: String]) { self.name = name; self.attributes = attributes }

    func child(_ name: String) -> FomodNode? { children.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
    func all(_ name: String) -> [FomodNode] { children.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
    func attribute(_ name: String) -> String? {
        attributes.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

private final class FomodTreeBuilder: NSObject, XMLParserDelegate {
    var stack: [FomodNode] = [FomodNode(name: "#document", attributes: [:])]
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        let node = FomodNode(name: elementName, attributes: attributes)
        stack.last?.children.append(node)
        stack.append(node)
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if stack.count > 1 { stack.removeLast() }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { stack.last?.text += String(decoding: CDATABlock, as: UTF8.self) }
}

// MARK: Model

struct Fomod {
    struct FileItem: Equatable {
        var source: String
        var destination: String
        var isFolder: Bool
        var priority: Int
    }
    enum OptionType: String {
        case required = "Required", optional = "Optional", recommended = "Recommended"
        case notUsable = "NotUsable", couldBeUsable = "CouldBeUsable"
    }
    indirect enum Condition {
        case flag(String, String)
        case file(String, String)     // plugin name, "Active" / "Inactive" / "Missing"
        case all([Condition]), any([Condition])
        case always                   // game / mod manager version checks
    }
    struct Option {
        var name: String
        var description: String
        var image: String?
        var files: [FileItem]
        var flags: [(name: String, value: String)]
        var type: OptionType
        var patterns: [(condition: Condition, type: OptionType)]
    }
    enum GroupType: String {
        case exactlyOne = "SelectExactlyOne", atMostOne = "SelectAtMostOne", atLeastOne = "SelectAtLeastOne"
        case all = "SelectAll", any = "SelectAny"
    }
    struct Group { var name: String; var type: GroupType; var options: [Option] }
    struct Step { var name: String; var visible: Condition?; var groups: [Group] }

    var name: String
    var image: String?
    var required: [FileItem]
    var steps: [Step]
    var conditional: [(condition: Condition, files: [FileItem])]

    /// Selected option indexes, per step and group.
    typealias Selection = [[Set<Int>]]

    enum Failure: LocalizedError {
        case unreadable
        var errorDescription: String? { "This mod's installer (fomod/ModuleConfig.xml) could not be read." }
    }

    init(xml data: Data) throws {
        let parser = XMLParser(data: Self.utf8(data))
        let builder = FomodTreeBuilder()
        parser.delegate = builder
        guard parser.parse(), let root = builder.stack.first?.child("config") else { throw Failure.unreadable }
        name = root.child("moduleName")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        image = root.child("moduleImage")?.attribute("path")
        required = Self.files(root.child("requiredInstallFiles"))
        steps = Self.ordered(root.child("installSteps")?.all("installStep") ?? [], order: root.child("installSteps")?.attribute("order"))
            .map { step in
                let groups = step.child("optionalFileGroups")
                return Step(name: step.attribute("name") ?? "",
                            visible: step.child("visible").map { Self.condition($0) },
                            groups: Self.ordered(groups?.all("group") ?? [], order: groups?.attribute("order")).map(Self.group))
            }
        conditional = root.child("conditionalFileInstalls")?.child("patterns")?.all("pattern").map {
            (Self.condition($0.child("dependencies")), Self.files($0.child("files")))
        } ?? []
    }

    /// Mod authors save ModuleConfig.xml as UTF-16 or with a wrong declared encoding often enough.
    private static func utf8(_ data: Data) -> Data {
        var text: String?
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { text = String(data: data, encoding: .utf16) }
        else if data.count > 1, data[data.startIndex + 1] == 0 { text = String(data: data, encoding: .utf16LittleEndian) }
        else { text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) }
        guard var xml = text else { return data }
        if xml.hasPrefix("\u{FEFF}") { xml.removeFirst() }
        // The declaration may name the encoding the bytes no longer have.
        if xml.hasPrefix("<?xml"), let end = xml.range(of: "?>") { xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"" + xml[end.lowerBound...] }
        return Data(xml.utf8)
    }

    private static func ordered(_ nodes: [FomodNode], order: String?) -> [FomodNode] {
        switch order?.lowercased() {
        case "explicit": return nodes
        case "descending": return nodes.sorted { ($0.attribute("name") ?? "").localizedStandardCompare($1.attribute("name") ?? "") == .orderedDescending }
        default: return nodes.sorted { ($0.attribute("name") ?? "").localizedStandardCompare($1.attribute("name") ?? "") == .orderedAscending }
        }
    }

    private static func files(_ node: FomodNode?) -> [FileItem] {
        (node?.children ?? []).compactMap { item in
            let folder = item.name.caseInsensitiveCompare("folder") == .orderedSame
            guard folder || item.name.caseInsensitiveCompare("file") == .orderedSame, let source = item.attribute("source") else { return nil }
            let destination = item.attribute("destination") ?? (folder ? "" : source)
            return FileItem(source: clean(source), destination: clean(destination), isFolder: folder,
                            priority: Int(item.attribute("priority") ?? "") ?? 0)
        }
    }

    static func clean(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").filter { !$0.isEmpty && $0 != "." }.joined(separator: "/")
    }

    private static func condition(_ node: FomodNode?) -> Condition {
        guard let node else { return .always }
        var parts: [Condition] = []
        for child in node.children {
            switch child.name.lowercased() {
            case "flagdependency": parts.append(.flag(child.attribute("flag") ?? "", child.attribute("value") ?? ""))
            case "filedependency": parts.append(.file(child.attribute("file") ?? "", child.attribute("state") ?? "Active"))
            case "dependencies": parts.append(condition(child))
            default: parts.append(.always)
            }
        }
        return node.attribute("operator")?.lowercased() == "or" ? .any(parts) : .all(parts)
    }

    private static func group(_ node: FomodNode) -> Group {
        let plugins = node.child("plugins")
        let options = ordered(plugins?.all("plugin") ?? [], order: plugins?.attribute("order")).map { plugin -> Option in
            let descriptor = plugin.child("typeDescriptor")
            var type = OptionType.optional
            var patterns: [(Condition, OptionType)] = []
            if let plain = descriptor?.child("type")?.attribute("name") {
                type = OptionType(rawValue: plain) ?? .optional
            } else if let dependency = descriptor?.child("dependencyType") {
                type = OptionType(rawValue: dependency.child("defaultType")?.attribute("name") ?? "") ?? .optional
                patterns = dependency.child("patterns")?.all("pattern").map {
                    (condition($0.child("dependencies")), OptionType(rawValue: $0.child("type")?.attribute("name") ?? "") ?? .optional)
                } ?? []
            }
            return Option(name: plugin.attribute("name") ?? "",
                          description: plugin.child("description")?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                          image: plugin.child("image")?.attribute("path").map(clean),
                          files: files(plugin.child("files")),
                          flags: plugin.child("conditionFlags")?.all("flag").map { ($0.attribute("name") ?? "", $0.text) } ?? [],
                          type: type, patterns: patterns)
        }
        return Group(name: node.attribute("name") ?? "", type: GroupType(rawValue: node.attribute("type") ?? "") ?? .any, options: options)
    }

    // MARK: Choices

    /// `plugin`: a plugin's state in the game's Data folder ("Active", "Inactive", "Missing").
    func holds(_ condition: Condition, flags: [String: String], plugin: (String) -> String) -> Bool {
        switch condition {
        case .always: return true
        case .flag(let name, let value): return (flags[name] ?? "") == value
        case .file(let name, let state): return plugin(name).caseInsensitiveCompare(state) == .orderedSame
        case .all(let parts): return parts.allSatisfy { holds($0, flags: flags, plugin: plugin) }
        case .any(let parts): return parts.isEmpty || parts.contains { holds($0, flags: flags, plugin: plugin) }
        }
    }

    func type(of option: Option, flags: [String: String], plugin: (String) -> String) -> OptionType {
        option.patterns.first { holds($0.condition, flags: flags, plugin: plugin) }?.type ?? option.type
    }

    /// The flags the chosen options set, through the visible steps in order.
    func flags(_ selection: Selection, plugin: (String) -> String) -> [String: String] {
        var flags: [String: String] = [:]
        for (s, step) in steps.enumerated() where step.visible.map({ holds($0, flags: flags, plugin: plugin) }) ?? true {
            for (g, group) in step.groups.enumerated() {
                for o in selection[s][g].sorted() where o < group.options.count {
                    for flag in group.options[o].flags { flags[flag.name] = flag.value }
                }
            }
        }
        return flags
    }

    func isVisible(step index: Int, _ selection: Selection, plugin: (String) -> String) -> Bool {
        guard let visible = steps[index].visible else { return true }
        let earlier = Selection(selection.prefix(index)) + steps[index...].map { $0.groups.map { _ in Set<Int>() } }
        return holds(visible, flags: flags(earlier, plugin: plugin), plugin: plugin)
    }

    /// What the installer starts with: required and recommended options, the first usable one where a group needs one.
    func defaultSelection(plugin: (String) -> String) -> Selection {
        var selection: Selection = steps.map { $0.groups.map { _ in Set<Int>() } }
        for (s, step) in steps.enumerated() {
            let flags = self.flags(selection, plugin: plugin)
            for (g, group) in step.groups.enumerated() {
                let types = group.options.map { type(of: $0, flags: flags, plugin: plugin) }
                var chosen = Set(types.indices.filter { types[$0] == .required || (group.type != .atMostOne && group.type != .exactlyOne && types[$0] == .recommended) })
                switch group.type {
                case .all: chosen = Set(group.options.indices)
                case .exactlyOne, .atMostOne:
                    let pick = types.firstIndex(of: .required) ?? types.firstIndex(of: .recommended)
                        ?? (group.type == .exactlyOne ? types.firstIndex { $0 != .notUsable } : nil)
                    chosen = pick.map { [$0] } ?? []
                case .atLeastOne:
                    if chosen.isEmpty, let first = types.firstIndex(where: { $0 != .notUsable }) { chosen = [first] }
                case .any: break
                }
                selection[s][g] = chosen
            }
        }
        return selection
    }

    /// The selection after tapping option `o` of group `g` in step `s`, following the group's rule.
    func toggle(_ selection: Selection, step s: Int, group g: Int, option o: Int, flags: [String: String], plugin: (String) -> String) -> Selection {
        var selection = selection
        let group = steps[s].groups[g]
        let kind = type(of: group.options[o], flags: flags, plugin: plugin)
        guard kind != .notUsable, kind != .required, group.type != .all else { return selection }
        var chosen = selection[s][g]
        switch group.type {
        case .exactlyOne: chosen = [o]
        case .atMostOne: chosen = chosen == [o] ? [] : [o]
        case .atLeastOne: if chosen.contains(o) { if chosen.count > 1 { chosen.remove(o) } } else { chosen.insert(o) }
        case .any: if chosen.contains(o) { chosen.remove(o) } else { chosen.insert(o) }
        case .all: break
        }
        selection[s][g] = chosen
        return selection
    }

    /// The files to install: `names` are the mod's files under its root (the folder holding fomod/).
    /// Returns (source name, destination path); a later or higher-priority file wins a destination.
    func install(_ selection: Selection, names: [String], plugin: (String) -> String) -> [(source: String, destination: String)] {
        var items = required.enumerated().map { ($1, $0) }
        var order = required.count
        let flags = self.flags(selection, plugin: plugin)
        for (s, step) in steps.enumerated() where isVisible(step: s, selection, plugin: plugin) {
            for (g, group) in step.groups.enumerated() {
                for o in selection[s][g].sorted() where o < group.options.count {
                    for file in group.options[o].files { items.append((file, order)); order += 1 }
                }
            }
        }
        for pattern in conditional where holds(pattern.condition, flags: flags, plugin: plugin) {
            for file in pattern.files { items.append((file, order)); order += 1 }
        }
        let byLower = Dictionary(names.map { (Self.clean($0).lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var chosen: [String: (source: String, destination: String, rank: (Int, Int))] = [:]
        for (item, position) in items {
            let source = item.source.lowercased()
            var pairs: [(String, String)] = []
            if item.isFolder {
                for (lower, name) in byLower.sorted(by: { $0.key < $1.key }) where source.isEmpty || lower.hasPrefix(source + "/") {
                    let rest = Self.clean(name).dropFirst(source.isEmpty ? 0 : source.count + 1)
                    pairs.append((name, Self.clean(item.destination + "/" + rest)))
                }
            } else if let name = byLower[source] {
                pairs.append((name, item.destination.isEmpty ? Self.clean(name).split(separator: "/").last.map(String.init) ?? "" : item.destination))
            }
            for (name, destination) in pairs where !destination.isEmpty && !destination.split(separator: "/").contains("..") {
                let key = destination.lowercased()
                let rank = (item.priority, position)
                if let old = chosen[key], old.rank > rank { continue }
                chosen[key] = (name, destination, rank)
            }
        }
        return chosen.values.sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.destination < $1.destination }.map { ($0.source, $0.destination) }
    }

    /// The folder holding fomod/ModuleConfig.xml among a mod's file names ("" for the top), nil for none.
    static func root(in names: [String]) -> (root: String, config: String)? {
        names.compactMap { name -> (String, String)? in
            let parts = clean(name).split(separator: "/").map(String.init)
            guard parts.count >= 2, parts[parts.count - 1].lowercased() == "moduleconfig.xml",
                  parts[parts.count - 2].lowercased() == "fomod" else { return nil }
            return (parts.dropLast(2).joined(separator: "/"), name)
        }.min { $0.0.count < $1.0.count }
    }
}

// MARK: Plugins

enum BethesdaPlugins {
    struct Game: Equatable {
        /// The folder under %LOCALAPPDATA% (and My Games).
        var folder: String
        /// plugins.txt marks active plugins with "*" (Skyrim SE, Fallout 4) rather than listing only them.
        var starred: Bool
        /// The ini that turns on loose files (Fallout 3 / New Vegas), under Documents/My Games/<folder>.
        var looseFilesIni: String?
    }

    /// The game from the programs in its folder.
    static func game(topNames: [String]) -> Game? {
        let lower = Set(topNames.map { $0.lowercased() })
        if lower.contains("falloutnv.exe") { return Game(folder: "FalloutNV", starred: false, looseFilesIni: "Fallout.ini") }
        if lower.contains("fallout3.exe") { return Game(folder: "Fallout3", starred: false, looseFilesIni: "Fallout.ini") }
        if lower.contains("oblivion.exe") { return Game(folder: "Oblivion", starred: false, looseFilesIni: nil) }
        if lower.contains("skyrimse.exe") { return Game(folder: "Skyrim Special Edition", starred: true, looseFilesIni: nil) }
        if lower.contains("tesv.exe") { return Game(folder: "Skyrim", starred: false, looseFilesIni: nil) }
        if lower.contains("fallout4.exe") { return Game(folder: "Fallout4", starred: true, looseFilesIni: nil) }
        return nil
    }

    static func isPlugin(_ name: String) -> Bool { ["esp", "esm", "esl"].contains((name as NSString).pathExtension.lowercased()) }

    /// `text` (plugins.txt, or nil when the game has none yet) with `plugins` active.
    /// `masters`: the .esm files in Data, listed first when the file is new.
    static func activate(_ plugins: [String], in text: String?, starred: Bool, masters: [String]) -> String {
        var lines = (text ?? "").replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last?.isEmpty == true { lines.removeLast() }
        func bare(_ line: String) -> String { line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "*")).lowercased() }
        let wanted = (text == nil ? masters : []) + plugins
        for plugin in wanted {
            if let i = lines.firstIndex(where: { bare($0) == plugin.lowercased() && !$0.hasPrefix("#") }) {
                if starred && !lines[i].hasPrefix("*") { lines[i] = "*" + lines[i] }
                continue
            }
            let entry = starred ? "*" + plugin : plugin
            // A master goes after the last master, so it loads before the plugins that need it.
            if plugin.lowercased().hasSuffix(".esm"), let last = lines.lastIndex(where: { bare($0).hasSuffix(".esm") }) {
                lines.insert(entry, at: last + 1)
            } else {
                lines.append(entry)
            }
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// `text` without `plugins`.
    static func deactivate(_ plugins: [String], in text: String) -> String {
        let gone = Set(plugins.map { $0.lowercased() })
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n").map(String.init).filter {
            !gone.contains($0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "*")).lowercased())
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\r\n") + "\r\n"
    }

    /// An ini's text with `key=value` in `[section]` (added where missing).
    static func setIni(_ text: String, section: String, key: String, value: String) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last?.isEmpty == true { lines.removeLast() }
        let header = "[" + section.lowercased() + "]"
        if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == header }) {
            var end = start + 1
            while end < lines.count && !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") { end += 1 }
            if let i = (start + 1..<end).first(where: {
                lines[$0].split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased() == key.lowercased()
            }) {
                lines[i] = key + "=" + value
            } else {
                var at = end
                while at > start + 1 && lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 }
                lines.insert(key + "=" + value, at: at)
            }
        } else {
            lines += ["[" + section + "]", key + "=" + value]
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }
}
