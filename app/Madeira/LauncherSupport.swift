// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Madeira contributors
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Publishers' own Windows launchers: Ubisoft Connect, Battle.net, the Rockstar
// Games Launcher and Final Fantasy XIV's, run inside the Wine desktop (docs/LAUNCHERS.md). None of them has
// a client Madeira could speak for, as it does for Steam, Epic and GOG: their games
// check their licence through the running launcher. So the launchers stay the
// publishers' programs, downloaded from their own HTTPS addresses only when the
// player taps Download, and the sign-in happens in their own windows.
//
// What Madeira adds: a Settings section that downloads the installer into drive_c and
// adds it to the library, finds the installed launcher and adds it too, and repairs
// what older Ubisoft games look for (Uplay.exe, the Ubisoft registry values in both
// registry views, the uplay:// protocol). The launcher's recommended settings
// (GameRecommendations.swift) start it in the Wine desktop with Windows services
// first and give its Chromium window the address-space layout Social Club and Steam's
// web helper use.
//
// Based on SaimSuhailQu's LauncherSupport.swift (willfaust/Madeira #260, not merged),
// rewritten for this tree: the registry goes through SteamInstallRegistry, the
// library recognises a launcher by its path, and Epic's launcher is left out (Madeira
// has Epic's store itself).

import Foundation
import SwiftUI

enum LauncherID: String, CaseIterable, Identifiable, Sendable {
    case ubisoft, battleNet, rockstar, ffxiv

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ubisoft: return "Ubisoft Connect"
        case .battleNet: return "Battle.net"
        case .rockstar: return "Rockstar Games Launcher"
        case .ffxiv: return "Final Fantasy XIV launcher"
        }
    }

    /// Where each installer puts the program a player starts, newest name first
    /// (Ubisoft's client was upc.exe and before that Uplay.exe).
    var programs: [String] {
        switch self {
        case .ubisoft:
            return ["Program Files (x86)\\Ubisoft\\Ubisoft Game Launcher\\UbisoftConnect.exe",
                    "Program Files\\Ubisoft\\Ubisoft Game Launcher\\UbisoftConnect.exe",
                    "Program Files (x86)\\Ubisoft\\Ubisoft Game Launcher\\upc.exe",
                    "Program Files\\Ubisoft\\Ubisoft Game Launcher\\upc.exe"]
        case .battleNet:
            return ["Program Files (x86)\\Battle.net\\Battle.net Launcher.exe",
                    "Program Files\\Battle.net\\Battle.net Launcher.exe"]
        case .rockstar:
            return ["Program Files\\Rockstar Games\\Launcher\\Launcher.exe",
                    "Program Files (x86)\\Rockstar Games\\Launcher\\Launcher.exe"]
        case .ffxiv:
            return ["Program Files (x86)\\SquareEnix\\FINAL FANTASY XIV - A Realm Reborn\\boot\\ffxivboot.exe",
                    "Program Files\\SquareEnix\\FINAL FANTASY XIV - A Realm Reborn\\boot\\ffxivboot.exe"]
        }
    }

    /// The publisher's own installer address.
    var installerURL: URL {
        switch self {
        case .ubisoft:
            return URL(string: "https://ubistatic3-a.akamaihd.net/orbit/launcher_installer/UbisoftConnectInstaller.exe")!
        case .battleNet:
            return URL(string: "https://www.battle.net/download/getInstallerForGame?os=win&locale=enUS&version=LIVE&gameProgram=BATTLENET_APP")!
        case .rockstar:
            return URL(string: "https://gamedownloads.rockstargames.com/public/installer/Rockstar-Games-Launcher.exe")!
        case .ffxiv:
            return URL(string: "https://gdl.square-enix.com/ffxiv/inst/ffxivsetup.exe")!
        }
    }

    /// The installer's file name; GameRecommendations recognises it by this name.
    var installerName: String {
        switch self {
        case .ubisoft: return "UbisoftConnectInstaller.exe"
        case .battleNet: return "Battle.net-Setup.exe"
        case .rockstar: return "Rockstar-Games-Launcher.exe"
        case .ffxiv: return "ffxivsetup.exe"
        }
    }

    /// Names older games start the launcher by, made as links beside it when missing.
    var aliases: [String] { self == .ubisoft ? ["Uplay.exe", "upc.exe"] : [] }
}

@MainActor
enum LauncherSupport {
    /// drive_c's folder for the downloaded installers.
    static let downloadFolder = "Madeira Downloads"

    /// The installed launcher's program, or nil.
    static func installed(_ id: LauncherID, drive: URL = LibraryModel.drive) -> URL? {
        for program in id.programs {
            if let url = DockInstallers.resolve("C:\\" + program, drive: drive),
               FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// The registry values older Ubisoft games read to find the client: the install
    /// folder (both views: the games are often 32-bit, the client 64-bit) and the
    /// uplay:// protocol in the user's classes (HKEY_CLASSES_ROOT's user half).
    static func ubisoftValues(folder: String, program: String) -> [SteamInstallValue] {
        let launcher = "Software\\Ubisoft\\Launcher"
        var values = [SteamInstallValue(hive: .machine, key: launcher, name: "InstallDir", data: .string(folder + "\\"), followsInstall: true)]
        for scheme in ["uplay", "ubisoft-connect"] {
            values.append(SteamInstallValue(hive: .user, key: "Software\\Classes\\" + scheme, name: "URL Protocol",
                                            data: .string(""), followsInstall: false))
            values.append(SteamInstallValue(hive: .user, key: "Software\\Classes\\" + scheme + "\\shell\\open\\command", name: "",
                                            data: .string("\"" + program + "\" \"%1\""), followsInstall: true))
        }
        return values
    }

    /// Ubisoft's repairs: the alias links beside the client and the registry values.
    /// Only while no session runs (the wineserver keeps the registry in memory). Does
    /// nothing without Ubisoft Connect installed; nothing twice. Returns what changed.
    @discardableResult
    static func repairUbisoft(drive: URL = LibraryModel.drive,
                              prefix: URL = LibraryModel.documents.appendingPathComponent("wine", isDirectory: true)) -> Int {
        guard wine_process_is_running() == 0, let program = installed(.ubisoft, drive: drive),
              DockInstallers.inside(program, drive: drive) else { return 0 }
        let root = drive.resolvingSymlinksInPath().standardizedFileURL.path
        let windowsProgram = "C:\\" + program.resolvingSymlinksInPath().standardizedFileURL.path.dropFirst(root.count + 1)
            .replacingOccurrences(of: "/", with: "\\")
        let folder = program.deletingLastPathComponent()
        let manager = FileManager.default
        var changed = 0
        for alias in LauncherID.ubisoft.aliases {
            let link = folder.appendingPathComponent(alias)
            // A real file of that name (an older client's own) stays; a link a client
            // update left dangling is made again.
            if manager.fileExists(atPath: link.path) { continue }
            if (try? manager.destinationOfSymbolicLink(atPath: link.path)) != nil { try? manager.removeItem(at: link) }
            do { try manager.createSymbolicLink(atPath: link.path, withDestinationPath: program.lastPathComponent); changed += 1 }
            catch { LogStore.shared.log("[launcher] ubisoft alias \(alias) not made: \(error.localizedDescription)", level: .error) }
        }
        let windowsFolder = String(windowsProgram[..<(windowsProgram.lastIndex(of: "\\") ?? windowsProgram.endIndex)])
        do { changed += try SteamInstallRegistry.write(ubisoftValues(folder: windowsFolder, program: windowsProgram), prefix: prefix) }
        catch { LogStore.shared.log("[launcher] ubisoft registry not written: \(error.localizedDescription)", level: .error) }
        if changed > 0 { LogStore.shared.log("[launcher] ubisoft repaired changes=\(changed) client=\(windowsProgram)") }
        return changed
    }
}

@MainActor
final class LauncherSupportModel: ObservableObject {
    static let shared = LauncherSupportModel()

    @Published private(set) var installed: [LauncherID: URL] = [:]
    @Published private(set) var downloading: LauncherID?
    @Published var status = ""
    @Published var error: String?
    /// The installer download keeps going while Madeira keeps running in the background (BackgroundRun.swift).
    private var background: BackgroundRun.Token?
    private var stoppedInBackground = false

    func refresh() {
        var found: [LauncherID: URL] = [:]
        for id in LauncherID.allCases { found[id] = LauncherSupport.installed(id) }
        installed = found
    }

    /// The launcher's library entry, made once; its recommended settings come with the save.
    func add(_ id: LauncherID) {
        error = nil
        guard let program = LauncherSupport.installed(id) else { error = "\(id.title) is not installed yet."; return }
        do {
            if id == .ubisoft { LauncherSupport.repairUbisoft() }
            var entry = try LibraryModel.inspect(program)
            if LibraryModel.shared.entries.contains(where: { $0.relativePath.caseInsensitiveCompare(entry.relativePath) == .orderedSame }) {
                status = "\(id.title) is already in the library."
                if id == .ffxiv { addFFXIVGame(boot: program) }
                return
            }
            entry.title = id.title
            LibraryModel.shared.save(entry)
            status = "Added \(id.title) to the library. Sign in in its own window."
            LogStore.shared.log("[launcher] added \(id.rawValue) path=\(entry.relativePath)")
            if id == .ffxiv { addFFXIVGame(boot: program) }
        } catch { self.error = error.localizedDescription }
    }

    /// Final Fantasy XIV's game beside the launcher's boot folder, once it is installed:
    /// its Play signs in through Madeira (SquareEnixSignIn.swift; Game details asks
    /// for the account first).
    private func addFFXIVGame(boot: URL) {
        let game = boot.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("game", isDirectory: true).appendingPathComponent("ffxiv_dx11.exe")
        guard FileManager.default.fileExists(atPath: game.path), var entry = try? LibraryModel.inspect(game),
              !LibraryModel.shared.entries.contains(where: { $0.relativePath.caseInsensitiveCompare(entry.relativePath) == .orderedSame })
        else { return }
        entry.title = "Final Fantasy XIV"
        LibraryModel.shared.save(entry)
        status = "Added the Final Fantasy XIV launcher (for updates) and the game to the library."
        LogStore.shared.log("[launcher] added ffxiv game path=\(entry.relativePath)")
    }

    func repair() {
        error = nil
        guard wine_process_is_running() == 0 else { error = "Close the running game first."; return }
        let changed = LauncherSupport.repairUbisoft()
        status = changed == 0 ? "Ubisoft Connect needs no repairs." : "Repaired Ubisoft Connect (\(changed) changes)."
    }

    /// Downloads the publisher's installer into drive_c and adds it to the library.
    func download(_ id: LauncherID) {
        guard downloading == nil else { return }
        let folder = LibraryModel.drive.appendingPathComponent(LauncherSupport.downloadFolder, isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { self.error = "The download folder could not be made: \(error.localizedDescription)"; return }
        downloading = id; error = nil; status = "Downloading the \(id.title) installer…"
        LogStore.shared.log("[launcher] download \(id.rawValue) from \(id.installerURL.host ?? "?")")
        let task = URLSession.shared.downloadTask(with: id.installerURL) { temporary, response, failure in
            // The file is gone once this returns: move it before going to the main actor.
            var moved: URL?
            var problem = failure?.localizedDescription
            if problem == nil, let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                problem = "the server answered HTTP \(http.statusCode)"
            }
            if problem == nil, let temporary {
                let target = folder.appendingPathComponent(id.installerName)
                do {
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: temporary, to: target)
                    moved = target
                } catch { problem = error.localizedDescription }
            }
            Task { @MainActor in self.downloaded(id, moved, problem ?? (moved == nil ? "no file arrived" : nil)) }
        }
        stoppedInBackground = false
        background = BackgroundRun.shared.beginTask("\(id.title) installer download") { [weak self, weak task] in
            MainActor.assumeIsolated { self?.stoppedInBackground = true }
            task?.cancel()
        }
        task.resume()
    }

    private func downloaded(_ id: LauncherID, _ file: URL?, _ problem: String?) {
        downloading = nil
        if let background { BackgroundRun.shared.endTask(background) }
        background = nil
        guard let file, problem == nil else {
            error = stoppedInBackground
                ? "The \(id.title) installer download stopped while Madeira was in the background. Tap Download to start it again."
                : "The \(id.title) installer did not download: \(problem ?? "unknown error")."
            LogStore.shared.log("[launcher] download \(id.rawValue) failed: \(problem ?? "?")", level: .error)
            status = ""
            return
        }
        do {
            var entry = try LibraryModel.inspect(file)
            entry.title = "Install \(id.title)"
            if let old = LibraryModel.shared.entries.first(where: { $0.relativePath.caseInsensitiveCompare(entry.relativePath) == .orderedSame }) {
                entry.id = old.id
            }
            LibraryModel.shared.save(entry)
            status = "Downloaded. Play \"Install \(id.title)\" in the library, then come back here and tap Add to library."
            LogStore.shared.log("[launcher] downloaded \(id.rawValue) installer to \(entry.relativePath)")
        } catch {
            self.error = "The \(id.title) installer could not be added: \(error.localizedDescription)"
        }
    }
}

struct LauncherSupportSettingsSection: View {
    @ObservedObject private var model = LauncherSupportModel.shared

    var body: some View {
        Section {
            ForEach(LauncherID.allCases) { id in
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent(id.title, value: model.installed[id] == nil ? "Not installed" : "Installed")
                    HStack {
                        if model.installed[id] != nil {
                            Button("Add to library") { model.add(id) }
                            if id == .ubisoft { Button("Repair") { model.repair() } }
                        } else {
                            Button(model.downloading == id ? "Downloading…" : "Download installer") { model.download(id) }
                                .disabled(model.downloading != nil)
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 2)
            }
            if model.downloading != nil { ProgressView() }
            if !model.status.isEmpty { Text(model.status).font(.caption).foregroundStyle(.secondary) }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
        } header: {
            Text("PC game launchers")
        } footer: {
            Text("These publishers' games only start with their own launcher running, so Madeira runs the real launcher in the Wine desktop. The installer comes from the publisher when you tap Download, and you sign in in the launcher's own window; Madeira never sees your password. Ubisoft games bought on Steam need Ubisoft Connect installed too. Final Fantasy XIV's launcher installs and updates the game; the game itself signs in through Madeira when you play it.")
        }
        .onAppear { model.refresh() }
    }
}
