// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
//  Game details › Mods: mods from Nexus Mods, Thunderstore or anywhere else,
//  added from a .zip, .7z or .rar (ModArchives.swift) or an unpacked folder in
//  Files, put where the game expects them, and taken out again with Remove.
//  A mod with a FOMOD installer asks for its options first, and its plugins
//  are turned on in the game's plugins.txt (ModFomod.swift). GameHub 6.2 made mods its
//  headline; Steam Workshop (SteamWorkshop.swift) only covers Workshop games.
//
//  Where a mod goes (ModPlan.make), the way mod managers decide it:
//    - a single folder wrapping everything is opened first ("MyMod-1.2/...");
//    - BepInExPack (Thunderstore) or BepInEx itself: the game's folder;
//    - a mod with a BepInEx/ folder: the game's folder; with plugins/,
//      patchers/ or config/ at its top: the game's BepInEx folder; a Thunderstore
//      package (manifest.json) or DLLs for a game that has BepInEx:
//      BepInEx/plugins/<mod name>/;
//    - a Bethesda-style mod with Data/ at its top: the game's folder, into the
//      game's own Data folder; one made of .esp/.esm/.bsa/.ba2 files or meshes/,
//      textures/, nvse/ ... folders, for a game with a Data folder: Data;
//    - anything else: the game's folder.
//  The player can change the place before installing.
//
//  Each install is recorded (Application Support/GameMods/<game hash>.json) with
//  the files it wrote; a file it replaced is kept aside first, so Remove deletes
//  the mod's files and puts the replaced ones back. A file a later mod also wrote
//  is left for that mod.
//
//  BepInEx 5 for Unity (Mono) games is one tap: Madeira downloads BepInEx's own
//  release (pinned by SHA-256), installs it as a mod, and adds
//  winhttp=n,b to the game's DLL overrides so Wine loads BepInEx's Doorstop.
//  IL2CPP Unity games need BepInEx 6, which this does not offer yet.
//
//  Everything above "MARK: Views" is Foundation only:
//  tests/host/check-game-mods.py compiles it with a test harness.
//

import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Where a mod's files go, relative to the game's folder.
struct ModPlan: Equatable {
    enum Place: String, CaseIterable, Codable {
        case gameFolder, dataFolder, bepinex, bepinexPlugins
        var title: String {
            switch self {
            case .gameFolder: return "Game folder"
            case .dataFolder: return "Data folder"
            case .bepinex: return "BepInEx folder"
            case .bepinexPlugins: return "BepInEx plugins"
            }
        }
    }
    struct File: Equatable { let source: String; let path: String }

    var place: Place
    /// The mod's own name, for BepInEx/plugins/<name>.
    var name: String
    var files: [File]
    /// Files left out: macOS litter, readme-like files of a Thunderstore package, unsafe paths.
    var skipped: Int

    static let bethesdaExtensions: Set<String> = ["esp", "esm", "esl", "bsa", "ba2"]
    static let bethesdaFolders: Set<String> = [
        "meshes", "textures", "sound", "music", "menus", "scripts", "interface", "shaders", "strings", "video",
        "nvse", "fose", "obse", "skse", "f4se", "seq", "lodsettings", "materials", "grass", "distantlod", "fonts",
    ]
    static let bepinexFolders: Set<String> = ["plugins", "patchers", "config", "core", "monomod"]
    /// Thunderstore package files r2modman leaves out of the game.
    static let thunderstoreMeta: Set<String> = ["manifest.json", "icon.png", "readme.md", "changelog.md", "license", "license.txt", "license.md"]

    /// The source names as files: no folders, no macOS litter, nothing that leaves the folder.
    static func files(_ names: [String]) -> (files: [File], skipped: Int) {
        var out: [File] = [], skipped = 0
        for raw in names {
            let name = raw.replacingOccurrences(of: "\\", with: "/")
            if name.hasSuffix("/") { continue }
            let parts = name.split(separator: "/")
            if parts.isEmpty { continue }
            if name.hasPrefix("/") || parts.contains(where: { $0 == ".." || $0 == "." || $0.hasPrefix("__MACOSX") })
                || parts.last == ".DS_Store" || parts.last?.hasPrefix("._") == true {
                skipped += 1; continue
            }
            out.append(File(source: raw, path: parts.joined(separator: "/")))
        }
        return (out, skipped)
    }

    /// The plan for a mod: `names` are the zip's entries (or the folder's files);
    /// `dataFolder` is the game's Data folder as it is spelled ("Data"), nil for none;
    /// `hasBepInEx`: the game's folder has BepInEx.
    static func make(names: [String], modName: String, dataFolder: String?, hasBepInEx: Bool) -> ModPlan {
        var (list, skipped) = files(names)
        func top(_ file: File) -> String { String(file.path.split(separator: "/").first ?? "").lowercased() }
        func atTop(_ file: File) -> Bool { !file.path.contains("/") }
        func lower(_ file: File) -> String { file.path.lowercased() }
        func strip(_ file: File, _ count: Int) -> File { File(source: file.source, path: String(file.path.dropFirst(count))) }
        // One folder wrapping everything (twice at most): open it, unless it is a folder a mod is made of.
        for _ in 0..<2 {
            guard let first = list.first?.path.split(separator: "/").first, list.allSatisfy({ !atTop($0) }) else { break }
            let name = first.lowercased()
            guard name != "data", name != "bepinex", name != "bepinexpack", !bepinexFolders.contains(name), !bethesdaFolders.contains(name),
                  list.allSatisfy({ $0.path.split(separator: "/").first == first }) else { break }
            list = list.map { strip($0, first.count + 1) }
        }
        let thunderstore = list.contains { lower($0) == "manifest.json" }
        var place = Place.gameFolder
        if let pack = list.first(where: { top($0) == "bepinexpack" && !atTop($0) }) {
            // BepInExPack (Thunderstore): its folder's contents into the game's folder.
            let prefix = String(pack.path.split(separator: "/")[0]).count + 1
            let before = list.count
            list = list.filter { top($0) == "bepinexpack" && !atTop($0) }.map { strip($0, prefix) }
            skipped += before - list.count
        } else if list.contains(where: { (top($0) == "bepinex" && !atTop($0)) || lower($0) == "winhttp.dll" || lower($0) == "doorstop_config.ini" }) {
            place = .gameFolder
        } else if list.contains(where: { bepinexFolders.contains(top($0)) && !atTop($0) }) {
            place = .bepinex
        } else if thunderstore || (hasBepInEx && !list.contains(where: { top($0) == "data" && !atTop($0) })
                                    && list.contains(where: { lower($0).hasSuffix(".dll") })
                                    && !list.contains(where: { lower($0).hasSuffix(".exe") })) {
            place = .bepinexPlugins
        } else if list.contains(where: { top($0) == "data" && !atTop($0) }) {
            place = .gameFolder
        } else if dataFolder != nil, list.contains(where: { f in
            (atTop(f) && bethesdaExtensions.contains((f.path as NSString).pathExtension.lowercased()))
                || (!atTop(f) && bethesdaFolders.contains(top(f)))
        }) {
            place = .dataFolder
        }
        if thunderstore && (place == .bepinexPlugins || place == .bepinex) {
            let before = list.count
            list = list.filter { !(atTop($0) && thunderstoreMeta.contains(lower($0))) }
            skipped += before - list.count
        }
        // The game's own Data folder spelling for a mod's "data/...".
        if let dataFolder {
            list = list.map { f in
                guard top(f) == "data", !atTop(f) else { return f }
                return File(source: f.source, path: dataFolder + "/" + f.path.split(separator: "/").dropFirst().joined(separator: "/"))
            }
        }
        return ModPlan(place: place, name: cleanName(modName), files: list, skipped: skipped)
    }

    /// The plan puts a Doorstop loader (BepInEx's winhttp.dll) in the game's folder.
    func loadsDoorstop(at place: Place) -> Bool {
        place == .gameFolder && files.contains { $0.path.lowercased() == "winhttp.dll" }
    }

    /// A mod name for a folder: no path characters.
    static func cleanName(_ name: String) -> String {
        var base = name
        for ext in [".zip", ".7z", ".rar"] where base.lowercased().hasSuffix(ext) { base = String(base.dropLast(ext.count)) }
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines).union(.controlCharacters)
        let clean = base.unicodeScalars.map { bad.contains($0) ? "-" : String($0) }.joined().trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? "Mod" : String(clean.prefix(80))
    }

    /// The folder `place` stands for, under the game's folder.
    static func base(_ place: Place, name: String, dataFolder: String?) -> String {
        switch place {
        case .gameFolder: return ""
        case .dataFolder: return dataFolder ?? "Data"
        case .bepinex: return "BepInEx"
        case .bepinexPlugins: return "BepInEx/plugins/" + name
        }
    }

    /// Each file's path under the game's folder for `place` (the plan's own, or the one the player chose).
    func targets(_ place: Place, dataFolder: String?) -> [File] {
        let base = Self.base(place, name: name, dataFolder: dataFolder)
        return files.map { File(source: $0.source, path: base.isEmpty ? $0.path : base + "/" + $0.path) }
    }
}

/// One installed mod, as GameMods records it.
struct InstalledMod: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var installed: Date
    /// Paths under drive_c the mod wrote, in install order.
    var files: [String]
    /// Of those, the ones that replaced a file (kept aside in the mod's backup folder).
    var replaced: [String]
    /// A DLL override the mod needed (BepInEx: "winhttp"), removed with it.
    var dllOverride: String?
    /// Plugins (.esp/.esm/.esl) it turned on in the game's plugins.txt, turned off with it.
    var plugins: [String]? = nil
}

enum GameModRecords {
    /// The files `mod` may delete on Remove: none a later mod also wrote.
    static func removable(_ mod: InstalledMod, in mods: [InstalledMod]) -> [String] {
        guard let index = mods.firstIndex(where: { $0.id == mod.id }) else { return mod.files }
        let later = Set(mods[(index + 1)...].flatMap { $0.files.map { $0.lowercased() } })
        return mod.files.filter { !later.contains($0.lowercased()) }
    }

    /// Unity's kind for a game folder's entries: "mono", "il2cpp" or nil (not Unity).
    static func unityKind(topNames: [String], hasManaged: Bool) -> String? {
        let lower = Set(topNames.map { $0.lowercased() })
        if lower.contains("gameassembly.dll") { return "il2cpp" }
        if lower.contains("unityplayer.dll") || hasManaged { return "mono" }
        return nil
    }
}

/// BepInEx 5 for Windows, from BepInEx's GitHub releases.
struct BepInExPin {
    static let version = "5.4.23.5"
    let arch: String
    let sha256: String
    var url: URL {
        URL(string: "https://github.com/BepInEx/BepInEx/releases/download/v\(Self.version)/BepInEx_win_\(arch)_\(Self.version).zip")!
    }
    static let x64 = BepInExPin(arch: "x64", sha256: "82f9878551030f54657792c0740d9d51a09500eeae1fba21106b0c441e6732c4")
    static let x86 = BepInExPin(arch: "x86", sha256: "37651c79e40d6f909572a4f461ac25350bb3ef8fe7fbd29f1aa8791a33b84c82")
    static func pin(bits: Int) -> BepInExPin { bits == 32 ? x86 : x64 }
}

// MARK: Views

/// A mod's files, from a zip or from an unpacked folder.
private enum ModSource {
    case zip(SaveZipReader, [String: SaveZipReader.Entry])
    case folder(URL)

    static func open(_ url: URL) throws -> (ModSource, [String]) {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            var names: [String] = []
            let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
            let base = url.resolvingSymlinksInPath().path
            while let item = walker?.nextObject() as? URL {
                guard (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let path = item.resolvingSymlinksInPath().path
                if path.hasPrefix(base + "/") { names.append(String(path.dropFirst(base.count + 1))) }
            }
            return (.folder(url), names)
        }
        let reader = try SaveZipReader(url: url)
        var byName: [String: SaveZipReader.Entry] = [:]
        for entry in reader.entries { byName[entry.name.replacingOccurrences(of: "\\", with: "/")] = entry }
        return (.zip(reader, byName), reader.entries.map(\.name))
    }

    func data(_ name: String) throws -> Data {
        switch self {
        case .zip(let reader, let byName):
            guard let entry = byName[name.replacingOccurrences(of: "\\", with: "/")] else { throw LibraryError.message("\(name) is missing from the zip.") }
            return try reader.extract(entry)
        case .folder(let url):
            return try Data(contentsOf: url.appendingPathComponent(name))
        }
    }
}

/// A game's mods: the record, install and Remove.
enum GameMods {
    static var root: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("GameMods", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static func key(_ windowsPath: String) -> String { String(format: "%016llx", LibraryPrefs.stableHash(windowsPath.lowercased())) }
    static func recordURL(_ windowsPath: String) -> URL? { root?.appendingPathComponent(key(windowsPath) + ".json") }
    static func backupFolder(_ windowsPath: String, _ mod: UUID) -> URL? {
        root?.appendingPathComponent(key(windowsPath), isDirectory: true).appendingPathComponent(mod.uuidString, isDirectory: true)
    }

    static func mods(_ windowsPath: String) -> [InstalledMod] {
        guard let url = recordURL(windowsPath), let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([InstalledMod].self, from: data)) ?? []
    }
    static func save(_ mods: [InstalledMod], _ windowsPath: String) throws {
        guard let url = recordURL(windowsPath) else { return }
        if mods.isEmpty { try? FileManager.default.removeItem(at: url); return }
        try JSONEncoder().encode(mods).write(to: url, options: .atomic)
    }

    /// The game's Data folder as it is spelled, nil for none.
    static func dataFolder(gameFolder: String) -> String? {
        let folder = LibraryModel.drive.appendingPathComponent(gameFolder, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.first { name in
            var isDirectory: ObjCBool = false
            return name.lowercased() == "data" && FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path,
                                                                                 isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }
    static func hasBepInEx(gameFolder: String) -> Bool {
        let folder = LibraryModel.drive.appendingPathComponent(gameFolder, isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).contains { $0.lowercased() == "bepinex" }
    }
    /// "mono", "il2cpp" or nil.
    static func unityKind(gameFolder: String) -> String? {
        let folder = LibraryModel.drive.appendingPathComponent(gameFolder, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let managed = names.contains { name in
            name.hasSuffix("_Data") && FileManager.default.fileExists(atPath: folder.appendingPathComponent(name)
                .appendingPathComponent("Managed/Assembly-CSharp.dll").path)
        }
        return GameModRecords.unityKind(topNames: names, hasManaged: managed)
    }

    /// A picked mod made ready to install: unpacked when it is a .7z or .rar, its FOMOD installer read.
    struct Prepared {
        /// The zip or folder the files come from.
        var source: URL
        /// The name the player knows it by (the picked file's).
        var name: String
        var plan: ModPlan
        var fomod: Fomod?
        /// The folder holding fomod/ ("" for the top) and the file names under it, for the installer.
        var fomodRoot = ""
        var fomodNames: [String] = []
        /// Copies and unpacked folders to delete when done.
        var cleanup: [URL] = []
    }

    static func prepare(_ picked: URL, gameFolder: String, progress: @escaping (Double) -> Void = { _ in }) throws -> Prepared {
        let fm = FileManager.default
        var cleanup: [URL] = []
        // The picker hands over a copy (in tmp, or an -Inbox folder): it goes once installed.
        if picked.path.contains("-Inbox/") || picked.path.contains("/tmp/") {
            cleanup.append(picked)
        }
        var source = picked
        if let kind = ModArchive.kind(of: picked) {
            let folder = fm.temporaryDirectory.appendingPathComponent("ModUnpack/" + UUID().uuidString, isDirectory: true)
            cleanup.append(folder)
            do {
                let files = try ModArchive.unpack(picked, to: folder, progress: progress)
                LogStore.shared.log("[mods] unpacked \(picked.lastPathComponent) (\(kind == .rar ? "rar" : "7z")): \(files.count) files")
            } catch {
                for url in cleanup { try? fm.removeItem(at: url) }
                LogStore.shared.log("[mods] could not unpack \(picked.lastPathComponent): \(error.localizedDescription)")
                throw error
            }
            source = folder
        }
        do {
            let (reader, names) = try ModSource.open(source)
            var prepared = Prepared(source: source, name: ModPlan.cleanName(picked.lastPathComponent),
                                    plan: ModPlan.make(names: names, modName: picked.lastPathComponent,
                                                       dataFolder: dataFolder(gameFolder: gameFolder), hasBepInEx: hasBepInEx(gameFolder: gameFolder)),
                                    cleanup: cleanup)
            if let found = Fomod.root(in: names) {
                do {
                    let fomod = try Fomod(xml: reader.data(found.config))
                    let prefix = found.root.isEmpty ? "" : found.root.lowercased() + "/"
                    prepared.fomod = fomod
                    prepared.fomodRoot = found.root
                    prepared.fomodNames = names.compactMap { name in
                        let clean = Fomod.clean(name)
                        guard clean.lowercased().hasPrefix(prefix) else { return nil }
                        return String(clean.dropFirst(prefix.count))
                    }
                    if !fomod.name.isEmpty { prepared.name = ModPlan.cleanName(fomod.name) }
                    LogStore.shared.log("[mods] \(picked.lastPathComponent): FOMOD installer \"\(fomod.name)\", \(fomod.steps.count) steps")
                } catch {
                    LogStore.shared.log("[mods] \(picked.lastPathComponent): FOMOD installer unreadable, installing as files")
                }
            }
            guard prepared.fomod != nil || !prepared.plan.files.isEmpty else { throw LibraryError.message("This mod has no files Madeira can install.") }
            return prepared
        } catch {
            for url in cleanup { try? fm.removeItem(at: url) }
            throw error
        }
    }

    /// The Bethesda game in `gameFolder`, nil for any other game.
    static func bethesdaGame(gameFolder: String) -> BethesdaPlugins.Game? {
        let folder = LibraryModel.drive.appendingPathComponent(gameFolder, isDirectory: true)
        return BethesdaPlugins.game(topNames: (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
    }

    static func pluginsFile(_ game: BethesdaPlugins.Game) -> URL? {
        SteamCloudPaths.userFolder(drive: LibraryModel.drive).map {
            $0.url.appendingPathComponent("AppData/Local/\(game.folder)/plugins.txt")
        }
    }

    /// A plugin's state for FOMOD conditions: "Active" (listed in plugins.txt), "Inactive" (only in Data) or "Missing".
    static func pluginState(gameFolder: String) -> (String) -> String {
        let data = dataFolder(gameFolder: gameFolder).map {
            LibraryModel.drive.appendingPathComponent(gameFolder, isDirectory: true).appendingPathComponent($0, isDirectory: true)
        }
        let present = Set(((data.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.path) }) ?? []).map { $0.lowercased() })
        let listed: Set<String> = {
            guard let game = bethesdaGame(gameFolder: gameFolder), let url = pluginsFile(game),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return Set(text.split(whereSeparator: \.isNewline).map {
                $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "*")).lowercased()
            })
        }()
        return { name in
            let lower = name.lowercased()
            guard present.contains(lower) else { return "Missing" }
            return listed.contains(lower) ? "Active" : "Inactive"
        }
    }

    /// Turns on `plugins` in the game's plugins.txt (and loose files for Fallout 3 / New Vegas). Returns the plugins turned on.
    static func activate(_ plugins: [String], looseFiles: Bool, gameFolder: String) -> [String] {
        guard let game = bethesdaGame(gameFolder: gameFolder), let user = SteamCloudPaths.userFolder(drive: LibraryModel.drive)?.url else { return [] }
        let fm = FileManager.default
        if !plugins.isEmpty {
            let url = user.appendingPathComponent("AppData/Local/\(game.folder)/plugins.txt")
            let old = try? String(contentsOf: url, encoding: .utf8)
            let masters: [String] = {
                guard old == nil, let data = dataFolder(gameFolder: gameFolder) else { return [] }
                let folder = LibraryModel.drive.appendingPathComponent(gameFolder, isDirectory: true).appendingPathComponent(data)
                let names = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                    .filter { $0.pathExtension.lowercased() == "esm" }
                func date(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
                return names.sorted { date($0) < date($1) }.map(\.lastPathComponent).filter { name in !plugins.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
            }()
            let text = BethesdaPlugins.activate(plugins, in: old, starred: game.starred, masters: masters)
            do {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: url, atomically: true, encoding: .utf8)
                LogStore.shared.log("[mods] plugins.txt (\(game.folder)): turned on \(plugins.joined(separator: ", "))")
            } catch {
                LogStore.shared.log("[mods] plugins.txt (\(game.folder)) could not be written: \(error.localizedDescription)")
                return []
            }
        }
        if looseFiles, let ini = game.looseFilesIni {
            let url = user.appendingPathComponent("Documents/My Games/\(game.folder)/\(ini)")
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                var changed = BethesdaPlugins.setIni(text, section: "Archive", key: "bInvalidateOlderFiles", value: "1")
                changed = BethesdaPlugins.setIni(changed, section: "Archive", key: "SInvalidationFile", value: "")
                if changed != text, (try? changed.write(to: url, atomically: true, encoding: .utf8)) != nil {
                    LogStore.shared.log("[mods] \(ini): loose files turned on (bInvalidateOlderFiles=1)")
                }
            }
        }
        return plugins
    }

    /// Reads a mod (a zip or a folder, security-scoped from Files) and plans it.
    static func plan(_ url: URL, gameFolder: String) throws -> ModPlan {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let (_, names) = try ModSource.open(url)
        let plan = ModPlan.make(names: names, modName: url.lastPathComponent, dataFolder: dataFolder(gameFolder: gameFolder),
                                hasBepInEx: hasBepInEx(gameFolder: gameFolder))
        guard !plan.files.isEmpty else { throw LibraryError.message("This mod has no files Madeira can install.") }
        return plan
    }

    /// Installs the planned files from `url` at `place` and records them.
    @discardableResult
    static func install(_ url: URL, plan: ModPlan, place: ModPlan.Place, name: String, windowsPath: String,
                        gameFolder: String, dllOverride: String? = nil) throws -> InstalledMod {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let (source, _) = try ModSource.open(url)
        let fm = FileManager.default
        let id = UUID()
        let dllOverride = dllOverride ?? (plan.loadsDoorstop(at: place) ? "winhttp" : nil)
        guard let backups = backupFolder(windowsPath, id) else { throw LibraryError.message("Madeira's mod records could not be opened.") }
        let drive = LibraryModel.drive
        let base = gameFolder.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var mod = InstalledMod(id: id, name: name, installed: Date(), files: [], replaced: [], dllOverride: dllOverride)
        var mods = self.mods(windowsPath)
        do {
            for file in plan.targets(place, dataFolder: dataFolder(gameFolder: gameFolder)) {
                let relative = base.isEmpty ? file.path : base + "/" + file.path
                let target = drive.appendingPathComponent(relative)
                guard target.standardizedFileURL.path.hasPrefix(drive.standardizedFileURL.path + "/") else { continue }
                let bytes = try source.data(file.source)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) {
                    let kept = backups.appendingPathComponent(relative)
                    try fm.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? fm.removeItem(at: kept)
                    try fm.copyItem(at: target, to: kept)
                    mod.replaced.append(relative)
                }
                try bytes.write(to: target, options: .atomic)
                mod.files.append(relative)
            }
            // Plugins straight in Data are turned on, as a mod manager would.
            if let data = dataFolder(gameFolder: gameFolder) {
                let inData = plan.targets(place, dataFolder: data).map(\.path).filter { $0.lowercased().hasPrefix(data.lowercased() + "/") }
                let plugins = inData.filter { $0.split(separator: "/").count == 2 && BethesdaPlugins.isPlugin($0) }
                    .compactMap { $0.split(separator: "/").last.map(String.init) }
                let loose = inData.contains { $0.split(separator: "/").count > 2 }
                let activated = activate(plugins, looseFiles: loose, gameFolder: gameFolder)
                if !activated.isEmpty { mod.plugins = activated }
            }
        } catch {
            // Half an install is taken back out.
            mods.append(mod)
            try? save(mods, windowsPath)
            try? remove(mod, windowsPath: windowsPath, gameFolder: gameFolder)
            throw error
        }
        mods.append(mod)
        try save(mods, windowsPath)
        if let dllOverride { setOverride(dllOverride, on: true, windowsPath: windowsPath) }
        LogStore.shared.log("[mods] \(name): \(mod.files.count) files at \(place.rawValue), \(mod.replaced.count) replaced")
        return mod
    }

    /// Deletes the mod's files (none a later mod also wrote), puts back the files it replaced.
    static func remove(_ mod: InstalledMod, windowsPath: String, gameFolder: String = "") throws {
        let fm = FileManager.default
        let drive = LibraryModel.drive
        var mods = self.mods(windowsPath)
        let removable = Set(GameModRecords.removable(mod, in: mods).map { $0.lowercased() })
        let replaced = Set(mod.replaced.map { $0.lowercased() })
        let backups = backupFolder(windowsPath, mod.id)
        var folders = Set<String>()
        for relative in mod.files.reversed() where removable.contains(relative.lowercased()) {
            let target = drive.appendingPathComponent(relative)
            try? fm.removeItem(at: target)
            if replaced.contains(relative.lowercased()), let kept = backups?.appendingPathComponent(relative) {
                try? fm.moveItem(at: kept, to: target)
            }
            var folder = (relative as NSString).deletingLastPathComponent
            while !folder.isEmpty { folders.insert(folder); folder = (folder as NSString).deletingLastPathComponent }
        }
        // Folders the mod made and left empty go too (deepest first).
        for folder in folders.sorted(by: { $0.count > $1.count }) {
            let url = drive.appendingPathComponent(folder)
            if (try? fm.contentsOfDirectory(atPath: url.path))?.isEmpty == true { try? fm.removeItem(at: url) }
        }
        if let backups { try? fm.removeItem(at: backups) }
        if let plugins = mod.plugins, !plugins.isEmpty, !gameFolder.isEmpty, let game = bethesdaGame(gameFolder: gameFolder),
           let url = pluginsFile(game), let text = try? String(contentsOf: url, encoding: .utf8) {
            // Only plugins whose file is gone now (a later mod may have written the same one).
            let gone = plugins.filter { plugin in !mod.files.contains { $0.lowercased().hasSuffix("/" + plugin.lowercased()) && fm.fileExists(atPath: drive.appendingPathComponent($0).path) } }
            try? BethesdaPlugins.deactivate(gone, in: text).write(to: url, atomically: true, encoding: .utf8)
            LogStore.shared.log("[mods] plugins.txt (\(game.folder)): turned off \(gone.joined(separator: ", "))")
        }
        mods.removeAll { $0.id == mod.id }
        try save(mods, windowsPath)
        if let dll = mod.dllOverride, !mods.contains(where: { $0.dllOverride == dll }) {
            setOverride(dll, on: false, windowsPath: windowsPath)
        }
        LogStore.shared.log("[mods] removed \(mod.name)")
    }

    /// Adds or removes "<dll>=n,b" in the game's DLL overrides.
    static func setOverride(_ dll: String, on: Bool, windowsPath: String) {
        let profile = GameProfile(windowsPath: windowsPath)
        var overrides = DllOverrides.read(config: profile.text)
        if on { overrides.set(dll, "n,b") } else { overrides.remove(dll) }
        profile.text = DllOverrides.write(overrides, into: profile.text)
    }

    /// Downloads BepInEx 5 for the game and installs it as a mod.
    static func installBepInEx(bits: Int, windowsPath: String, gameFolder: String) async throws {
        let pin = BepInExPin.pin(bits: bits)
        let (temp, response) = try await URLSession.shared.download(from: pin.url)
        defer { try? FileManager.default.removeItem(at: temp) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw LibraryError.message("GitHub answered \(http.statusCode) for BepInEx.")
        }
        guard try WineMonoInstaller.sha256(of: temp) == pin.sha256 else {
            throw LibraryError.message("The download does not match BepInEx \(BepInExPin.version) (\(pin.arch)).")
        }
        let zip = FileManager.default.temporaryDirectory.appendingPathComponent("BepInEx_\(pin.arch).zip")
        try? FileManager.default.removeItem(at: zip)
        try FileManager.default.moveItem(at: temp, to: zip)
        defer { try? FileManager.default.removeItem(at: zip) }
        let plan = try self.plan(zip, gameFolder: gameFolder)
        try install(zip, plan: plan, place: .gameFolder, name: "BepInEx \(BepInExPin.version) (\(pin.arch))",
                    windowsPath: windowsPath, gameFolder: gameFolder, dllOverride: "winhttp")
    }
}

/// Game details › Mods.
struct GameModsSection: View {
    let entry: LibraryEntry
    /// The game's config changed (BepInEx's DLL override): Game details reads it again.
    var changed: () -> Void = {}
    @State private var mods: [InstalledMod] = []
    @State private var pending: GameMods.Prepared?
    @State private var installer: GameMods.Prepared?
    @State private var place: ModPlan.Place = .gameFolder
    @State private var working: String?
    @State private var error: String?
    @State private var unity: String?
    @State private var confirmRemove: InstalledMod?

    private var gameFolder: String { GameSetup.gameFolder(entry) }
    private var hasBepInEx: Bool { mods.contains { $0.dllOverride == "winhttp" } || GameMods.hasBepInEx(gameFolder: gameFolder) }

    var body: some View {
        Section {
            if mods.isEmpty {
                Text("No mods added yet.").foregroundStyle(.secondary)
            }
            ForEach(mods) { mod in
                LabeledContent {
                    Button("Remove", role: .destructive) { confirmRemove = mod }.buttonStyle(.borderless)
                } label: {
                    VStack(alignment: .leading) {
                        Text(mod.name)
                        Text(mod.files.count == 1 ? "1 file" : "\(mod.files.count) files")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            // Files and folders have their own pickers: one that offers both
            // opens a zip like a folder instead of choosing it.
            Menu {
                Button("Choose a File", systemImage: "doc.zipper") { pick(folder: false) }
                Button("Choose a Folder", systemImage: "folder") { pick(folder: true) }
            } label: {
                Label("Add Mod", systemImage: "plus")
            }
            .disabled(working != nil)
            if let working { HStack { ProgressView(); Text(working).foregroundStyle(.secondary) } }
            if let error { Text(error).foregroundStyle(.red) }
        } header: {
            Text("Mods")
        } footer: {
            Text("Choose a mod's .zip, .7z or .rar, or its unpacked folder, from Files (Nexus Mods, Thunderstore and other sites). Madeira puts the files where the game expects them, asks for the options of a mod with an installer, turns on its plugins, and Remove puts the game back as it was.")
        }
        .sheet(isPresented: Binding(get: { pending != nil }, set: { if !$0 { finish(pending); pending = nil } })) {
            if let pending { confirmSheet(pending) }
        }
        .sheet(isPresented: Binding(get: { installer != nil }, set: { if !$0 { finish(installer); installer = nil } })) {
            if let installer, let fomod = installer.fomod {
                FomodInstallerSheet(prepared: installer, fomod: fomod, gameFolder: gameFolder) { plan, place in
                    let chosen = installer
                    self.installer = nil
                    install(chosen, plan: plan, place: place)
                }
            }
        }
        .confirmationDialog(confirmRemove.map { "Remove \($0.name)?" } ?? "",
                            isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                guard let mod = confirmRemove else { return }
                do { try GameMods.remove(mod, windowsPath: entry.windowsPath, gameFolder: gameFolder) } catch { self.error = error.localizedDescription }
                reload(); changed()
            }
        } message: { Text("Its files are deleted and the game's files it replaced are put back.") }
        .onAppear { reload() }

        if let unity {
            Section {
                if unity == "il2cpp" {
                    Text("This is an IL2CPP Unity game. Its mods need BepInEx 6, which Madeira doesn't install yet.")
                        .foregroundStyle(.secondary)
                } else if hasBepInEx {
                    Label("BepInEx is installed. Add BepInEx mods with Add Mod.", systemImage: "checkmark.circle")
                } else {
                    Button("Install BepInEx", systemImage: "arrow.down.circle") { installBepInEx() }.disabled(working != nil)
                }
            } header: {
                Text("Unity mod loader")
            } footer: {
                if unity == "mono" && !hasBepInEx {
                    Text("Most Unity mods need BepInEx \(BepInExPin.version). Madeira downloads it from BepInEx's GitHub and sets the DLL override it needs.")
                }
            }
        }
    }

    private func reload() {
        mods = GameMods.mods(entry.windowsPath)
        unity = entry.desktop == true ? nil : GameMods.unityKind(gameFolder: gameFolder)
    }

    private func pick(folder: Bool) {
        error = nil
        ModPicker.shared.present(folder: folder) { url in
            guard let url else { return }
            read(url)
        }
    }

    /// Unpacks and reads the picked mod off the main thread, then asks where (or which options).
    private func read(_ url: URL) {
        let isArchive = ModArchive.kind(of: url) != nil
        working = isArchive ? "Unpacking \(url.lastPathComponent)…" : "Reading \(url.lastPathComponent)…"
        let folder = gameFolder
        Task {
            do {
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try GameMods.prepare(url, gameFolder: folder)
                }.value
                if prepared.fomod != nil { installer = prepared } else { place = prepared.plan.place; pending = prepared }
            } catch {
                self.error = error.localizedDescription
                LogStore.shared.log("[mods] \(url.lastPathComponent): \(error.localizedDescription)")
            }
            working = nil
        }
    }

    private func finish(_ prepared: GameMods.Prepared?) {
        guard let prepared, working == nil else { return }
        for url in prepared.cleanup { try? FileManager.default.removeItem(at: url) }
    }

    private func install(_ prepared: GameMods.Prepared, plan: ModPlan, place chosen: ModPlan.Place) {
        working = "Installing \(prepared.name)…"; error = nil
        let windowsPath = entry.windowsPath, folder = gameFolder
        Task {
            do {
                _ = try await Task.detached {
                    try GameMods.install(prepared.source, plan: plan, place: chosen, name: prepared.name, windowsPath: windowsPath, gameFolder: folder)
                }.value
            } catch { self.error = "The mod could not be installed: \(error.localizedDescription)" }
            for url in prepared.cleanup { try? FileManager.default.removeItem(at: url) }
            working = nil; reload()
        }
    }

    private func installBepInEx() {
        working = "Downloading BepInEx…"; error = nil
        Task {
            do {
                try await GameMods.installBepInEx(bits: entry.bits, windowsPath: entry.windowsPath, gameFolder: gameFolder)
            } catch { self.error = "BepInEx could not be installed: \(error.localizedDescription)" }
            working = nil; reload(); changed()
        }
    }

    @ViewBuilder private func confirmSheet(_ prepared: GameMods.Prepared) -> some View {
        let plan = prepared.plan
        NavigationStack {
            Form {
                Section {
                    Picker("Put it in", selection: $place) {
                        ForEach(ModPlan.Place.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    let targets = plan.targets(place, dataFolder: GameMods.dataFolder(gameFolder: gameFolder))
                    ForEach(targets.prefix(8), id: \.path) { Text($0.path.replacingOccurrences(of: "/", with: "\\")).font(.caption.monospaced()) }
                    if targets.count > 8 { Text("and \(targets.count - 8) more").font(.caption).foregroundStyle(.secondary) }
                } header: {
                    Text(plan.name)
                } footer: {
                    Text(place == plan.place ? "Madeira picked this place from the mod's files." : "You changed the place. Madeira suggested \(plan.place.title).")
                }
                Section {
                    Button("Install", systemImage: "square.and.arrow.down") {
                        let chosen = place
                        pending = nil
                        install(prepared, plan: plan, place: chosen)
                    }
                }
            }
            .navigationTitle("Add Mod").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { finish(pending); pending = nil } } }
        }
    }
}

/// The Files picker for a mod, as a copy: in-place picks do nothing when Madeira
/// is signed with an App ID other than its bundle ID (see ExternalDrives.swift),
/// and a copy is what an install reads once anyway.
@MainActor final class ModPicker: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    static let shared = ModPicker()
    private var done: ((URL?) -> Void)?

    func present(folder: Bool, _ done: @escaping (URL?) -> Void) {
        guard var top = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else { return }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        let types: [UTType] = folder ? [.folder] : [.zip, .archive, .data]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        self.done = done
        LogStore.shared.log("[mods] picker shown (\(folder ? "folder" : "file"))")
        top.present(picker, animated: true) { picker.presentationController?.delegate = self }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        LogStore.shared.log("[mods] picked \(urls.first?.lastPathComponent ?? "nothing")")
        done?(urls.first)
        done = nil
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        LogStore.shared.log("[mods] picker cancelled")
        done?(nil)
        done = nil
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        LogStore.shared.log("[mods] picker swiped away")
        done?(nil)
        done = nil
    }
}

/// A FOMOD installer: its steps one page at a time, each option group with its rule.
struct FomodInstallerSheet: View {
    let prepared: GameMods.Prepared
    let fomod: Fomod
    let gameFolder: String
    let install: (ModPlan, ModPlan.Place) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Fomod.Selection = []
    @State private var page = 0
    @State private var images: [String: UIImage] = [:]
    @State private var plugin: (String) -> String = { _ in "Missing" }

    private var visible: [Int] {
        guard selection.count == fomod.steps.count else { return [] }
        return fomod.steps.indices.filter { fomod.isVisible(step: $0, selection, plugin: plugin) && !fomod.steps[$0].groups.isEmpty }
    }
    private var flags: [String: String] { fomod.flags(selection, plugin: plugin) }

    var body: some View {
        NavigationStack {
            Form {
                if selection.count == fomod.steps.count, page < visible.count {
                    let s = visible[page]
                    ForEach(fomod.steps[s].groups.indices, id: \.self) { g in groupSection(step: s, group: g) }
                } else {
                    Section {
                        Text("This mod's installer has no options to choose. Install puts in its required files.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(page < visible.count && !fomod.steps[visible[page]].name.isEmpty ? fomod.steps[visible[page]].name : prepared.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if page + 1 < visible.count {
                        Button("Next") { page += 1 }.disabled(!complete(visible[page]))
                    } else {
                        Button("Install") { finish() }.disabled(page < visible.count && !complete(visible[page]))
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    if page > 0 { Button("Back") { page -= 1 } }
                }
            }
        }
        .onAppear {
            plugin = GameMods.pluginState(gameFolder: gameFolder)
            selection = fomod.defaultSelection(plugin: plugin)
            loadImages()
        }
    }

    @ViewBuilder private func groupSection(step s: Int, group g: Int) -> some View {
        let group = fomod.steps[s].groups[g]
        Section {
            ForEach(group.options.indices, id: \.self) { o in
                let option = group.options[o]
                let kind = fomod.type(of: option, flags: flags, plugin: plugin)
                let chosen = selection[s][g].contains(o)
                Button {
                    selection = fomod.toggle(selection, step: s, group: g, option: o, flags: flags, plugin: plugin)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: single(group.type) ? (chosen ? "largecircle.fill.circle" : "circle")
                                                             : (chosen ? "checkmark.square.fill" : "square"))
                            .foregroundStyle(chosen ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(option.name).foregroundStyle(.primary)
                            if kind == .recommended { Text("Recommended").font(.caption).foregroundStyle(.green) }
                            if kind == .notUsable { Text("Not usable with your game").font(.caption).foregroundStyle(.orange) }
                            if !option.description.isEmpty {
                                Text(option.description).font(.caption).foregroundStyle(.secondary).lineLimit(6)
                            }
                            if let path = option.image, let image = images[path.lowercased()] {
                                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 140)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }
                .disabled(kind == .notUsable || kind == .required || group.type == .all)
            }
        } header: {
            Text(group.name)
        } footer: {
            rule(group.type)
        }
    }

    private func single(_ type: Fomod.GroupType) -> Bool { type == .exactlyOne || type == .atMostOne }

    @ViewBuilder private func rule(_ type: Fomod.GroupType) -> some View {
        switch type {
        case .exactlyOne: Text("Choose one.")
        case .atMostOne: Text("Choose one or none.")
        case .atLeastOne: Text("Choose at least one.")
        case .all: Text("All of these are installed.")
        case .any: Text("Choose any.")
        }
    }

    private func complete(_ s: Int) -> Bool {
        fomod.steps[s].groups.indices.allSatisfy { g in
            let count = selection[s][g].count
            switch fomod.steps[s].groups[g].type {
            case .exactlyOne: return count == 1
            case .atLeastOne: return count >= 1
            default: return true
            }
        }
    }

    private func finish() {
        let pairs = fomod.install(selection, names: prepared.fomodNames, plugin: plugin)
        let root = prepared.fomodRoot
        let files = pairs.map { ModPlan.File(source: root.isEmpty ? $0.source : root + "/" + $0.source, path: $0.destination) }
        let data = GameMods.dataFolder(gameFolder: gameFolder)
        let place: ModPlan.Place = data != nil ? .dataFolder : .gameFolder
        LogStore.shared.log("[mods] FOMOD \(prepared.name): \(files.count) files chosen into \(place.title)")
        install(ModPlan(place: place, name: prepared.name, files: files, skipped: 0), place)
    }

    /// The options' pictures (fomod/images/...), read once.
    private func loadImages() {
        let paths = Set(fomod.steps.flatMap { $0.groups.flatMap { $0.options.compactMap(\.image) } })
        guard !paths.isEmpty else { return }
        let source = prepared.source, root = prepared.fomodRoot, names = prepared.fomodNames
        Task.detached(priority: .utility) {
            guard let reader = (try? ModSource.open(source))?.0 else { return }
            let byLower = Dictionary(names.map { (Fomod.clean($0).lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
            var loaded: [String: UIImage] = [:]
            for path in paths.prefix(40) {
                guard let name = byLower[path.lowercased()], let data = try? reader.data(root.isEmpty ? name : root + "/" + name),
                      data.count < 8 << 20, let image = UIImage(data: data) else { continue }
                loaded[path.lowercased()] = image.preparingThumbnail(of: CGSize(width: 480, height: 480)) ?? image
            }
            await MainActor.run { images = loaded }
        }
    }
}
