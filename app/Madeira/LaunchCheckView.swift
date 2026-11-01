//
//  LaunchCheckView.swift
//  Madeira
//
//  "Will it run?" on Game details (LaunchCheck.swift has the checks): a short
//  list under Play, each line with a button where Madeira can fix it, or one
//  green line when nothing was found. Play stays available; a "problem" line
//  asks "Play anyway?" once per set of problems.
//

import SwiftUI
import UIKit

struct LaunchCheckSection: View {
    let notes: [LaunchCheckNote]
    var fix: (LaunchCheckNote.Fix) -> Void
    @ObservedObject private var mono = WineMonoModel.shared
    @ObservedObject private var gecko = WineGeckoModel.shared

    var body: some View {
        Section {
            if !notes.contains(where: { $0.level >= .caution }) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No known problems").fontWeight(.semibold)
                        Text("Checked the game's files, anti-cheat, memory and free space.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            }
            ForEach(notes) { note in
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.title).fontWeight(.semibold)
                        Text(note.detail).font(.caption).foregroundStyle(.secondary)
                        if let link = note.link {
                            Link("Read the report", destination: link)
                                .font(.caption.weight(.semibold)).buttonStyle(.borderless)
                        }
                        if let action = note.fix {
                            if (action == .getWineMono && mono.busy) || (action == .getWineGecko && gecko.busy) {
                                ProgressView().controlSize(.small)
                            } else {
                                Button(action.label) { fix(action) }
                                    .font(.caption.weight(.semibold)).buttonStyle(.borderless)
                            }
                        }
                    }
                } icon: { Image(systemName: Self.symbol(note.level)).foregroundStyle(Self.color(note.level)) }
            }
        } header: { Text("Will it run?") }
    }

    static func symbol(_ level: LaunchCheckNote.Level) -> String {
        switch level {
        case .good: return "checkmark.seal.fill"
        case .info: return "info.circle.fill"
        case .caution: return "exclamationmark.triangle.fill"
        case .problem: return "xmark.octagon.fill"
        }
    }
    static func color(_ level: LaunchCheckNote.Level) -> Color {
        switch level {
        case .good: return .green
        case .info: return .blue
        case .caution: return .orange
        case .problem: return .red
        }
    }
}

extension LaunchCheck {
    /// Play's "Play anyway?" is asked once per game and set of problems.
    static func problemKey(_ notes: [LaunchCheckNote]) -> String {
        notes.filter { $0.level == .problem }.map(\.id).sorted().joined(separator: ",")
    }
    static func acknowledged(_ entry: LibraryEntry, _ notes: [LaunchCheckNote]) -> Bool {
        let key = problemKey(notes)
        return key.isEmpty || UserDefaults.standard.string(forKey: "launch-check-ack.\(entry.id.uuidString)") == key
    }
    static func acknowledge(_ entry: LibraryEntry, _ notes: [LaunchCheckNote]) {
        UserDefaults.standard.set(problemKey(notes), forKey: "launch-check-ack.\(entry.id.uuidString)")
    }

    /// Gathers what the checks read for `entry` (its files off the main thread) and
    /// returns the notes; nil for the Desktop entry.
    @MainActor
    static func run(_ entry: LibraryEntry) async -> [LaunchCheckNote]? {
        guard entry.desktop != true else { return nil }
        let drive = LibraryEntry.hostDrive
        var input = Input()
        input.monoAvailable = WineMonoModel.available
        input.geckoAvailable = WineGeckoModel.available
        input.deviceName = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        input.physicalMemory = ProcessInfo.processInfo.physicalMemory
        input.tested = KnownGames.find(windowsPath: entry.windowsPath, steamAppID: entry.steamAppID)
        input.knownIssues = KnownIssues.find(windowsPath: entry.windowsPath, steamAppID: entry.steamAppID)
        input.freeBytes = (try? drive.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        let arguments = entry.programArguments.lowercased()
        input.antiCheatSkipped = arguments.contains("-nobattleye") || arguments.contains("-noeac")
            || (entry.epicAppName.map { LibraryEntry.epicAntiCheatOffProgram[$0] != nil } == true && entry.epicAntiCheatOff != false)

        // The game's files are read only once the store has them all.
        var filesReady = true
        if let appID = entry.steamAppID {
            filesReady = SteamOwnedLibrary.shared.downloads[appID] == nil
                && SteamGamesModel.shared.games.first { $0.id == appID }?.installed == true
        }
        if let product = entry.gogProductID { filesReady = GOGLibrary.shared.downloads[product] == nil && GOGLibrary.shared.installed[product] != nil }
        if let game = entry.itchGameID { filesReady = ItchLibrary.shared.downloads[game] == nil && ItchLibrary.shared.installed[game] != nil }
        if let app = entry.epicAppName { filesReady = EpicLibrary.shared.downloads[app] == nil && EpicLibrary.shared.installed[app] != nil }
        if let offer = entry.eaOfferID { filesReady = EALibrary.shared.downloads[offer] == nil && EALibrary.shared.installed[offer] != nil }

        let dockSteam = entry.steamAppID != nil && !entry.startsSteamGameDirectly
        let launches = entry.steamAppID.flatMap { SteamOwnedLibrary.shared.game($0)?.launches }
        let picked = entry.steamProgram
        let relativeProgram = entry.launchRelativePath
        let relativeFolder = entry.relativePath
        let workingFolder = LibraryEntry.hostURL(ofWindowsPath: entry.launchDirectory)
        let batch = entry.isBatch
        let bits = entry.bits
        let steam = entry.steamAppID != nil
        input.programIsSteam = steam
        input.programRequired = !dockSteam
        input.bits = bits
        let storeAppID = entry.steamAppID ?? entry.steamID

        let prepared = input
        let gathered = await Task.detached(priority: .utility) { () -> Input in
            var input = prepared
            guard filesReady else { return input }
            if dockSteam {
                // Valve's client picks the program: read the one "The game" would start, when known.
                let root = drive.appendingPathComponent(relativeFolder, isDirectory: true)
                input.gameFolder = root
                input.program = SteamDirectStart.program(picked: picked, options: launches, installFolder: root)
                    .map { root.appendingPathComponent($0) }
            } else {
                input.program = drive.appendingPathComponent(relativeProgram)
                input.gameFolder = steam ? drive.appendingPathComponent(relativeFolder, isDirectory: true)
                    : LaunchCheck.gameFolder(drive: drive, relativeProgram: relativeProgram)
            }
            if let folder = input.gameFolder { input.antiCheat = LaunchCheck.antiCheat(in: folder) }
            if let program = input.program, !batch, FileManager.default.fileExists(atPath: program.path) {
                input.imports = LibraryModel.importNames(program)
                if input.bits == 0, let inspected = try? LibraryModel.inspect(program) { input.bits = inspected.bits }
                let windows = drive.appendingPathComponent("windows", isDirectory: true)
                let bundle = Bundle.main.bundleURL
                let system: [URL] = input.bits == 32
                    ? [windows.appendingPathComponent("syswow64"), bundle.appendingPathComponent("i386-windows")]
                    : input.bits == 64
                    ? [windows.appendingPathComponent("system32"), bundle.appendingPathComponent("arm64ec-windows"), bundle.appendingPathComponent("aarch64-windows")]
                    : ["system32", "syswow64"].map { windows.appendingPathComponent($0) }
                        + ["i386-windows", "arm64ec-windows", "aarch64-windows"].map { bundle.appendingPathComponent($0) }
                input.available = LaunchCheck.fileNames(in: [program.deletingLastPathComponent()] + (workingFolder.map { [$0] } ?? []) + system)
            }
            return input
        }.value
        input = gathered
        if let storeAppID { input.steamMinimumMemory = await steamMinimumMemory(appID: storeAppID) }
        let found = notes(input)
        LogStore.shared.log(logLine(title: entry.title, notes: found))
        return found
    }
}
