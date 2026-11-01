// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Madeira contributors
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// The publishers' launchers in the library, one section each, the way Steam and GOG
// have theirs (docs/LAUNCHERS.md): the launcher itself, the games you added from its
// folders, and the games it installed that are not in the library yet, each with
// an Add button. A program belongs to a launcher's section by where it lives in
// drive_c (LauncherID.sectionFolders), so the launcher's installer, the launcher and
// the games it installs leave Other games for it.

import Foundation
import SwiftUI

extension LauncherID {
    /// Blizzard's default game folders (Battle.net puts each game in its own
    /// folder beside its own, not inside it).
    static let blizzardGames = ["World of Warcraft", "Diablo IV", "Diablo III", "Diablo II Resurrected", "Diablo Immortal",
                                "Overwatch", "StarCraft II", "StarCraft", "Hearthstone", "Heroes of the Storm",
                                "Warcraft III", "Warcraft Rumble", "Call of Duty"]

    /// drive_c folders, relative and in lower case, whose programs are listed in this
    /// launcher's library section: the launcher's own and where its games install.
    var sectionFolders: [String] {
        func both(_ path: String) -> [String] { ["program files (x86)/" + path, "program files/" + path] }
        switch self {
        case .ubisoft: return both("ubisoft/ubisoft game launcher")
        case .battleNet: return both("battle.net") + Self.blizzardGames.flatMap { both($0.lowercased()) }
        case .rockstar: return both("rockstar games")
        case .ffxiv: return both("squareenix/final fantasy xiv - a realm reborn")
        }
    }

    /// The launcher whose section lists this library entry: a program in one of its
    /// folders, or its installer in Madeira Downloads. Store games have their own sections.
    static func owner(of entry: LibraryEntry) -> LauncherID? {
        guard entry.desktop != true, entry.steamAppID == nil, entry.epicAppName == nil, entry.gogProductID == nil,
              entry.itchGameID == nil, entry.eaOfferID == nil else { return nil }
        let path = entry.relativePath.lowercased()
        for id in allCases {
            if path == LauncherSupport.downloadFolder.lowercased() + "/" + id.installerName.lowercased() { return id }
            if id.sectionFolders.contains(where: { path.hasPrefix($0 + "/") }) { return id }
        }
        return nil
    }

    /// Battle.net's product codes for its games' folders, for
    /// `Battle.net.exe --exec="launch <code>"` (the way Lutris starts Blizzard games):
    /// the games check that Battle.net is running and signed in, so a library entry
    /// starts them through it. Call of Duty and Warcraft Rumble have no single code.
    static let blizzardCodes: [String: String] = [
        "World of Warcraft": "WoW", "Diablo IV": "Fen", "Diablo III": "D3", "Diablo II Resurrected": "OSI",
        "Diablo Immortal": "ANBS", "Overwatch": "Pro", "StarCraft II": "S2", "StarCraft": "S1",
        "Hearthstone": "WTCG", "Heroes of the Storm": "Hero", "Warcraft III": "W3",
    ]

    /// The launch switch for a Blizzard game's folder ("Program Files (x86)/StarCraft"), or nil.
    static func blizzardLaunch(folder: String) -> String? {
        guard let name = folder.split(separator: "/").last.map(String.init),
              let code = blizzardCodes.first(where: { $0.key.lowercased() == name.lowercased() })?.value else { return nil }
        return "--exec=\"launch \(code)\""
    }

    /// Folders, relative to drive_c, that hold one installed game each.
    var gameFolders: [String] {
        let fm = FileManager.default
        let drive = LibraryModel.drive
        func children(_ relative: String, except: Set<String> = []) -> [String] {
            let url = drive.appendingPathComponent(relative, isDirectory: true)
            let names = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            return names.filter { !$0.hasPrefix(".") && !except.contains($0.lowercased()) }
                .filter { var dir: ObjCBool = false; return fm.fileExists(atPath: url.appendingPathComponent($0).path, isDirectory: &dir) && dir.boolValue }
                .map { relative + "/" + $0 }
        }
        func existing(_ relative: String) -> Bool { fm.fileExists(atPath: drive.appendingPathComponent(relative).path) }
        switch self {
        case .ubisoft:
            return ["Program Files (x86)", "Program Files"].flatMap { children($0 + "/Ubisoft/Ubisoft Game Launcher/games") }
        case .battleNet:
            return ["Program Files (x86)", "Program Files"].flatMap { root in Self.blizzardGames.map { root + "/" + $0 } }.filter(existing)
        case .rockstar:
            return ["Program Files", "Program Files (x86)"].flatMap {
                children($0 + "/Rockstar Games", except: ["launcher", "social club", "rockstar games launcher"])
            }
        case .ffxiv:
            return ["Program Files (x86)", "Program Files"].map { $0 + "/SquareEnix/FINAL FANTASY XIV - A Realm Reborn" }
                .filter { existing($0 + "/game/ffxiv_dx11.exe") }
        }
    }
}

/// A game a launcher installed that is not in the library yet.
struct LauncherFoundGame: Identifiable, Hashable {
    var folder: String   // relative to drive_c, "/"-separated
    var id: String { folder }
    var title: String {
        folder.hasSuffix("FINAL FANTASY XIV - A Realm Reborn") ? "Final Fantasy XIV" : (folder.split(separator: "/").last.map(String.init) ?? folder)
    }
}

@MainActor
enum LauncherGames {
    static func found(_ id: LauncherID, entries: [LibraryEntry]) -> [LauncherFoundGame] {
        let added = entries.map { $0.relativePath.lowercased() }
        let launches = Set(entries.map { $0.arguments.trimmingCharacters(in: .whitespaces) })
        return id.gameFolders.filter { folder in
            // A Blizzard game added to start through Battle.net (add) has Battle.net's path.
            if id == .battleNet, let launch = LauncherID.blizzardLaunch(folder: folder), launches.contains(launch) { return false }
            // FFXIV's launcher (boot\ffxivboot.exe) shares the game's folder: only the game counts.
            let prefix = folder.lowercased() + (id == .ffxiv ? "/game/ffxiv_dx11.exe" : "/")
            return !added.contains(where: { $0.hasPrefix(prefix) })
        }.map(LauncherFoundGame.init(folder:))
    }

    /// Adds a found game with its program: FFXIV's game, else the folder's one program
    /// (helpers aside) or the one named like the folder. Returns an error to show.
    static func add(_ game: LauncherFoundGame) -> String? {
        // A Blizzard game starts through Battle.net (--exec="launch <code>"): the games
        // check that Battle.net is running and signed in. The entry is Battle.net's
        // launcher with that switch, so it also gets Battle.net's settings list.
        if let launch = LauncherID.blizzardLaunch(folder: game.folder) {
            let launcher = ["Program Files (x86)", "Program Files"]
                .map { LibraryModel.drive.appendingPathComponent($0 + "/Battle.net/Battle.net Launcher.exe") }
                .first { FileManager.default.fileExists(atPath: $0.path) }
            if let launcher {
                do {
                    var entry = try LibraryModel.inspect(launcher)
                    entry.title = game.title
                    entry.arguments = launch
                    LibraryModel.shared.save(entry)
                    LogStore.shared.log("[launcher] added found game through Battle.net title=\(game.title) args=\(launch)")
                    return nil
                } catch { return error.localizedDescription }
            }
        }
        let folder = LibraryModel.drive.appendingPathComponent(game.folder, isDirectory: true)
        let program = game.folder.hasSuffix("FINAL FANTASY XIV - A Realm Reborn") ? "game/ffxiv_dx11.exe"
            : ItchProgram.find(in: folder, title: game.title)
        guard let program else {
            return "Madeira could not tell which program starts \(game.title). Add it with + and choose its .exe."
        }
        do {
            var entry = try LibraryModel.inspect(folder.appendingPathComponent(program))
            entry.title = game.title
            LibraryModel.shared.save(entry)
            LogStore.shared.log("[launcher] added found game path=\(entry.relativePath)")
            return nil
        } catch { return error.localizedDescription }
    }
}

/// One launcher's library section.
struct LauncherGamesSection<Cell: View>: View {
    let id: LauncherID
    let entries: [LibraryEntry]
    var layout = "cards"
    var width: CGFloat = 390
    @ViewBuilder let cell: (_ entry: LibraryEntry, _ list: Bool, _ dense: Bool) -> Cell
    @ObservedObject private var launchers = LauncherSupportModel.shared
    @ObservedObject private var library = LibraryModel.shared
    @AppStorage private var hidden: Bool
    @State private var found: [LauncherFoundGame] = []
    @State private var problem: String?

    init(id: LauncherID, entries: [LibraryEntry], layout: String = "cards", width: CGFloat = 390,
         @ViewBuilder cell: @escaping (_ entry: LibraryEntry, _ list: Bool, _ dense: Bool) -> Cell) {
        self.id = id; self.entries = entries; self.layout = layout; self.width = width; self.cell = cell
        _hidden = AppStorage(wrappedValue: false, "madeiraLibraryHideLauncher." + id.rawValue)
    }

    /// The launcher's own program is in the library.
    private var launcherAdded: Bool {
        guard let program = launchers.installed[id] else { return true }
        let path = program.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        let drive = LibraryModel.drive.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        guard path.hasPrefix(drive + "/") else { return true }
        let relative = String(path.dropFirst(drive.count + 1))
        return library.entries.contains { $0.relativePath.lowercased() == relative }
    }

    var body: some View {
        let installed = launchers.installed[id] != nil
        VStack(alignment: .leading, spacing: 14) {
            if installed || !entries.isEmpty {
                let collapsible = SteamGamesSection.collapsible
                LibrarySectionHeader(title: id.title, count: entries.count, collapsed: collapsible ? $hidden : nil) { EmptyView() }
                if !(hidden && collapsible) {
                    if installed && !launcherAdded {
                        Button { launchers.add(id); refresh() } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "plus.app").font(.system(size: 30)).foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Add \(id.title) to the library").font(.headline)
                                    Text("It is installed. Add it here to open it and sign in.")
                                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                }
                                Spacer(minLength: 0)
                            }.padding(14)
                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                        }.buttonStyle(.plain)
                    }
                    if !entries.isEmpty {
                        LibraryCells(items: entries, layout: layout, width: width) { entry, list, dense in cell(entry, list, dense) }
                    }
                    ForEach(found) { game in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(game.title).font(.headline)
                                Text("Installed by \(id.title), not in the library").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Add") { problem = LauncherGames.add(game); refresh() }.buttonStyle(.bordered)
                        }.padding(12)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                    }
                    if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
                }
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: library.entries.count) { _, _ in refresh() }
    }

    private func refresh() {
        launchers.refresh()
        found = launchers.installed[id] == nil && entries.isEmpty ? [] : LauncherGames.found(id, entries: library.entries)
    }
}
