//
//  LaunchCheck.swift
//  Madeira
//
//  "Will it run?" (Game details, under Play): a few plain lines about what is
//  likely to stop this game on this device, read before the launch rather than
//  out of a 2 MB log afterwards. Nothing here blocks Play.
//
//  - The program to start is missing from the game's folder.
//  - Anti-cheat ships with the game (Easy Anti-Cheat, BattlEye, Vanguard, ...):
//    it cannot run in Wine on iOS, so online play that needs it won't connect.
//  - The program imports a DLL that is in neither its folder, Wine's prefix nor
//    Madeira's Wine libraries: Windows' loader refuses such a program at once.
//  - It imports mscoree.dll (.NET Framework) and Wine Mono is not on the device.
//  - The program imports mshtml/ieframe (web pages) and Wine Gecko is not
//    downloaded yet: Wine would stop it on its own download window.
//  - Steam's store lists a minimum memory this device does not have.
//  - Little free space is left on the device.
//  - On the good side: the game is on KnownGames, the games device-tested on
//    Madeira (also the library's "Tested" pill).
//
//  Plain values and file reads only (no UI), so tests/host/check-launch-check.py
//  compiles and runs it on Linux. LaunchCheckView.swift shows the result.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct LaunchCheckNote: Identifiable, Equatable {
    enum Level: Int, Comparable {
        case good, info, caution, problem
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }
    /// What the note's button does (LaunchCheckView maps it to the page or action).
    enum Fix: Equatable {
        case steamPage, getWineMono, getWineGecko
        var label: String {
            switch self {
            case .steamPage: return "Choose the program"
            case .getWineMono: return "Get Wine Mono"
            case .getWineGecko: return "Get Wine Gecko"
            }
        }
    }
    /// Stable per kind of problem ("anticheat", "missing-dll", ...): Play's question
    /// is asked again only when the set of problems changes.
    let id: String
    let level: Level
    let title: String
    let detail: String
    var fix: Fix? = nil
    /// A page with more about the note (a known issue's report on GitHub).
    var link: URL? = nil
}

enum LaunchCheck {
    /// What the checks read, gathered by LaunchCheckView (entry, device and stores)
    /// and by `scan` (the game's files).
    struct Input {
        /// The program a launch starts, when Madeira knows it.
        var program: URL?
        /// true when `program` must exist (the library starts it itself); false for a
        /// Steam game started through Madeira Dock, whose program Valve's client picks.
        var programRequired = true
        var programIsSteam = false
        /// The game's top folder, searched for anti-cheat.
        var gameFolder: URL?
        var bits = 0
        /// The program's imports (LibraryModel.importNames), lowercased.
        var imports: [String] = []
        /// DLL names (lowercased) the loader would find: the program's folder, the
        /// working folder, Wine's system folders and Madeira's Wine libraries.
        var available: Set<String> = []
        /// Anti-cheat found in the game's files (antiCheat(in:)).
        var antiCheat: String?
        /// The game starts in an official mode without its anti-cheat (Rocket League's
        /// -noeac, GTA V's -nobattleye).
        var antiCheatSkipped = false
        var monoAvailable = true
        var geckoAvailable = true
        var deviceName = "iPhone"
        var physicalMemory: UInt64 = 0
        /// Steam's minimum memory for the game, in bytes (minimumMemory(html:)).
        var steamMinimumMemory: UInt64?
        var freeBytes: Int64?
        /// The game's device test, when it had one (KnownGames).
        var tested: KnownGame?
        /// Problems other players reported for this game (KnownIssues).
        var knownIssues: [KnownIssue] = []
    }

    static let gb: Double = 1_073_741_824

    /// The notes for `input`, most serious first.
    static func notes(_ input: Input) -> [LaunchCheckNote] {
        var notes: [LaunchCheckNote] = []
        let programName = input.program?.lastPathComponent ?? "the game's program"
        if input.programRequired, let program = input.program, !FileManager.default.fileExists(atPath: program.path) {
            notes.append(LaunchCheckNote(id: "missing-program", level: .problem, title: "\(programName) is missing",
                                         detail: input.programIsSteam
                                            ? "The program this game starts is not in its folder any more. Repair the game, or choose another program."
                                            : "The program this entry starts is not in its folder any more. Reinstall the game, or remove this entry and add the game again.",
                                         fix: input.programIsSteam ? .steamPage : nil))
        }
        if let name = input.antiCheat {
            if input.antiCheatSkipped {
                notes.append(LaunchCheckNote(id: "anticheat-off", level: .info, title: "Starts without \(name)",
                                             detail: "Madeira starts this game's official mode without anti-cheat, so only its offline modes work."))
            } else {
                notes.append(LaunchCheckNote(id: "anticheat", level: .caution, title: "Uses \(name)",
                                             detail: "\(name) can't run on \(input.deviceName). A game that needs it to start or to play online won't get past it. Offline and single-player modes may still work."))
            }
        }
        let missing = missingDLLs(imports: input.imports, available: input.available)
        if !missing.isEmpty {
            let list = missing.count <= 3 ? missing.joined(separator: ", ") : missing.prefix(3).joined(separator: ", ") + " and \(missing.count - 3) more"
            notes.append(LaunchCheckNote(id: "missing-dll", level: .problem,
                                         title: missing.count == 1 ? "Missing \(missing[0])" : "Missing \(missing.count) DLLs",
                                         detail: "\(programName) needs \(list), which is not in the game's folder or in Wine. Windows refuses to start a program like this. Repair the game, or copy the file into the game's folder."))
        }
        if input.imports.contains("mscoree.dll"), !input.monoAvailable {
            notes.append(LaunchCheckNote(id: "mono", level: .problem, title: "Needs .NET Framework",
                                         detail: "This game is a .NET program. Madeira runs those with Wine Mono, which is not on this device yet (about 80 MB).",
                                         fix: .getWineMono))
        }
        if !input.geckoAvailable, input.imports.contains(where: { $0 == "mshtml.dll" || $0 == "ieframe.dll" }) {
            notes.append(LaunchCheckNote(id: "gecko", level: .info, title: "Shows web pages",
                                         detail: "This program draws pages with Internet Explorer's engine, which Wine Gecko provides. Madeira gets it on Wi-Fi by itself; get it now so Wine doesn't stop the program to download it.",
                                         fix: .getWineGecko))
        }
        // Compared with the memory as sold (an 8 GB phone reports a little under 8 GB).
        if let needed = input.steamMinimumMemory, input.physicalMemory > 0,
           Double(needed) > (Double(input.physicalMemory) / gb).rounded(.up) * gb {
            notes.append(LaunchCheckNote(id: "memory", level: .caution, title: "Needs more memory than this \(input.deviceName) has",
                                         detail: "Steam lists \(gigabytes(needed)) of memory as the minimum. This \(input.deviceName) has \(gigabytes(input.physicalMemory)), and iOS gives Madeira only part of it. Expect it to run out of memory; close other apps first."))
        }
        if let free = input.freeBytes, free >= 0, Double(free) < 2 * gb {
            notes.append(LaunchCheckNote(id: "space", level: free < 512 * 1_048_576 ? .problem : .caution,
                                         title: "Only \(gigabytes(UInt64(free))) free",
                                         detail: "Games write saves, settings and shader caches while they run. A full device can crash the game or cut a save short. Free some space first."))
        }
        for issue in input.knownIssues {
            notes.append(LaunchCheckNote(id: "known-issue." + issue.id, level: issue.level, title: "Known issue: " + issue.title,
                                         detail: issue.text, link: issue.link))
        }
        if let tested = input.tested {
            notes.append(LaunchCheckNote(id: "tested", level: .good, title: "Tested: runs on Madeira",
                                         detail: tested.detail(deviceName: input.deviceName, physicalMemory: input.physicalMemory)))
        }
        return notes.sorted { $0.level > $1.level }
    }

    /// 12884901888 -> "12 GB"; 1.4 GB -> "1.4 GB". Device memory is rounded up to a
    /// whole GB, as it is sold (iOS reports a little less).
    static func gigabytes(_ bytes: UInt64) -> String {
        let value = Double(bytes) / gb
        if value >= 4 { return "\(Int(value.rounded(.up))) GB" }
        return String(format: "%.1f GB", value)
    }

    // MARK: DLLs

    /// Names the loader resolves without a file: API sets, and the kernel's own.
    static func resolvedWithoutFile(_ name: String) -> Bool {
        name.hasPrefix("api-ms-") || name.hasPrefix("ext-ms-") || name == "ntoskrnl.exe"
    }
    /// Microsoft runtimes a session links into the prefix itself (WineProcessBridge.m:
    /// the VC++ package with MFC, and the DirectX redistributable's names Wine builds),
    /// so a prefix that never ran a game does not have them yet.
    static let sessionProvided = ["mfc", "msvcp", "msvcr", "vcruntime", "vcomp", "concrt", "vccorlib", "vcamp", "ucrtbase",
                                  "d3dx", "d3dcompiler", "xinput", "xaudio", "x3daudio", "xapofx"]
    /// Nothing is reported when `available` has no kernel32.dll: the system folders
    /// could not be read, so every import would look missing.
    static func missingDLLs(imports: [String], available: Set<String>) -> [String] {
        guard available.contains("kernel32.dll") else { return [] }
        var seen = Set<String>()
        return imports.filter { name in
            guard name.hasSuffix(".dll"), !resolvedWithoutFile(name), !available.contains(name),
                  !sessionProvided.contains(where: { name.hasPrefix($0) }) else { return false }
            return seen.insert(name).inserted
        }
    }
    /// The lowercased file names in `folders` (one level each).
    static func fileNames(in folders: [URL]) -> Set<String> {
        var names = Set<String>()
        for folder in folders {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] { names.insert(name.lowercased()) }
        }
        return names
    }

    // MARK: Anti-cheat

    /// File and folder names (lowercased) that only ship with an anti-cheat.
    static let antiCheatMarkers: [(name: String, marker: String)] = [
        ("Easy Anti-Cheat", "easyanticheat"), ("Easy Anti-Cheat", "easyanticheat_eos.sys"), ("Easy Anti-Cheat", "start_protected_game.exe"),
        ("BattlEye", "battleye"), ("BattlEye", "beservice.exe"), ("BattlEye", "beservice_x64.exe"), ("BattlEye", "bedaisy.sys"),
        ("Riot Vanguard", "vgk.sys"), ("Riot Vanguard", "vgc.exe"),
        ("nProtect GameGuard", "gameguard"), ("nProtect GameGuard", "gamemon.des"),
        ("XIGNCODE3", "xigncode"), ("PunkBuster", "pnkbstra.exe"), ("PunkBuster", "pnkbstrb.exe"),
        ("EA Javelin anti-cheat", "eaanticheat.gameservice.dll"), ("EA Javelin anti-cheat", "eaanticheat.installer.exe"),
        ("Anti-Cheat Expert", "anticheatexpert"), ("mhyprot anti-cheat", "mhyprot2.sys"),
    ]
    /// The anti-cheat in `folder`, looked for three levels down (anti-cheats install
    /// at the game's top folder or beside its program). nil for none.
    static func antiCheat(in folder: URL, depth: Int = 3, limit: Int = 20_000) -> String? {
        let fm = FileManager.default
        var level = [folder], visited = 0
        for _ in 0..<depth {
            var next: [URL] = []
            for dir in level {
                guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
                for name in names {
                    visited += 1
                    if visited > limit { return nil }
                    let lower = name.lowercased()
                    if let hit = antiCheatMarkers.first(where: { $0.marker == lower }) { return hit.name }
                    var isDirectory: ObjCBool = false
                    let url = dir.appendingPathComponent(name)
                    if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue { next.append(url) }
                }
            }
            level = next
        }
        return nil
    }

    /// A game's top folder from its program's path relative to drive_c: a store's
    /// install folder (GOG Games/<game>, Program Files/Epic Games/<game>, ...), else
    /// the program's folder, climbing out of folders named like Binaries/Win64.
    static func gameFolder(drive: URL, relativeProgram: String) -> URL {
        let parts = relativeProgram.split(separator: "/").map(String.init)
        let lower = parts.map { $0.lowercased() }
        let storeDepth: Int? = {
            if lower.count > 3, lower[0] == "program files" || lower[0] == "program files (x86)",
               ["epic games", "ea games", "ubisoft", "rockstar games"].contains(lower[1]) { return 3 }
            if lower.count > 2, ["gog games", "itch", "games"].contains(lower[0]) { return 2 }
            return nil
        }()
        if let storeDepth { return parts.prefix(storeDepth).reduce(drive) { $0.appendingPathComponent($1) } }
        var folder = Array(parts.dropLast())
        let binNames: Set<String> = ["bin", "bin32", "bin64", "binaries", "win32", "win64", "x86", "x64", "x86_64", "retail", "game"]
        while folder.count > 1, binNames.contains(folder.last!.lowercased()) { folder.removeLast() }
        return folder.reduce(drive) { $0.appendingPathComponent($1) }
    }

    // MARK: Steam's minimum memory

    /// "Memory: 8 GB RAM" (or MB) in Steam's minimum requirements HTML, in bytes.
    static func minimumMemory(html: String) -> UInt64? {
        let text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        guard let range = text.range(of: #"Memory:\s*([0-9]+(?:[.,][0-9]+)?)\s*(GB|MB)"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let found = String(text[range])
        let parts = found.replacingOccurrences(of: ",", with: ".")
            .components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).filter { !$0.isEmpty }
        guard let number = parts.first.flatMap(Double.init), number > 0 else { return nil }
        let unit: Double = found.uppercased().hasSuffix("MB") ? 1_048_576 : gb
        return UInt64(number * unit)
    }

    /// Steam's minimum memory for `appID` from the public store (no sign-in), kept
    /// for 30 days in UserDefaults; 0 is kept for "none listed". nil when unknown.
    static func steamMinimumMemory(appID: Int) async -> UInt64? {
        let key = "launch-check-memory.\(appID)"
        let defaults = UserDefaults.standard
        if let saved = defaults.dictionary(forKey: key), let bytes = saved["bytes"] as? Double,
           let at = saved["at"] as? Double, Date().timeIntervalSince1970 - at < 30 * 86400 {
            return bytes > 0 ? UInt64(bytes) : nil
        }
        var url = URLComponents(string: "https://store.steampowered.com/api/appdetails")!
        url.queryItems = [URLQueryItem(name: "appids", value: String(appID)), URLQueryItem(name: "filters", value: "basic"),
                          URLQueryItem(name: "l", value: "english")]
        var request = URLRequest(url: url.url!); request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count < 4_000_000,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let app = json[String(appID)] as? [String: Any] else { return nil }
        // pc_requirements is an object with "minimum" HTML, or an empty array for none.
        let html = ((app["data"] as? [String: Any])?["pc_requirements"] as? [String: Any])?["minimum"] as? String
        let bytes = html.flatMap(minimumMemory(html:))
        defaults.set(["bytes": Double(bytes ?? 0), "at": Date().timeIntervalSince1970], forKey: key)
        return bytes
    }

    /// One log line for the session's log, so a bug report shows what Play warned about.
    static func logLine(title: String, notes: [LaunchCheckNote]) -> String {
        "[will-it-run] \(title): " + (notes.isEmpty ? "no warnings" : notes.map { "\($0.id)=\($0.level)" }.joined(separator: " "))
    }
}

/// One device test of a known game. More devices can be added to a game later.
struct KnownTest: Equatable {
    /// "iPhone 17 Pro Max"; nil when the device was not recorded.
    let device: String?
    /// "iOS 27".
    let os: String?
    let build: Int
    /// The device's memory as sold, in GB (0 when unknown).
    let memoryGB: Int

    var text: String {
        let on = device.map { name in os.map { "\(name) (\($0))" } ?? name }
        return (on.map { "\($0), " } ?? "") + "Madeira build \(build)"
    }
}

/// Games device-tested on Madeira that run (the project's own test log). A game
/// with recommended settings gets them on first sight (GameRecommendations.swift),
/// so "runs" means with those. Recognised like GameRecommendations: a Steam App
/// ID, the install folder under steamapps\common, or the game's own program.
struct KnownGame: Equatable {
    let id: String
    let title: String
    let appIDs: Set<Int>
    /// Lowercased folder names (steamapps\common or wherever it was copied).
    let folders: Set<String>
    /// Lowercased program names.
    let programs: Set<String>
    /// Where it ran, newest first.
    let tests: [KnownTest]
    let note: String

    /// "Tested on iPhone 17 Pro Max (iOS 27), Madeira build 47." plus a hint when this
    /// device has less memory than every device it was tested on.
    func detail(deviceName: String, physicalMemory: UInt64) -> String {
        var text = "Tested on " + tests.map(\.text).joined(separator: "; ") + "."
        let tested = tests.map(\.memoryGB).filter { $0 > 0 }
        let own = Int((Double(physicalMemory) / LaunchCheck.gb).rounded(.up))
        if physicalMemory > 0, let least = tested.min(), own < least {
            text += " This \(deviceName) has \(own) GB of memory, less than the \(least) GB it was tested with, so it may not run the same."
        }
        return note.isEmpty ? text : text + " " + note
    }
}

enum KnownGames {
    /// Cameron's iPhone (iPhone18,2), where the project's device tests run.
    static let iPhone17ProMax = (device: "iPhone 17 Pro Max", os: "iOS 27", memoryGB: 12)
    static func onIPhone17ProMax(build: Int) -> KnownTest {
        KnownTest(device: iPhone17ProMax.device, os: iPhone17ProMax.os, build: build, memoryGB: iPhone17ProMax.memoryGB)
    }

    static let all: [KnownGame] = [
        KnownGame(id: "counter-strike-2", title: "Counter-Strike 2", appIDs: [730],
                  folders: ["counter-strike global offensive"], programs: ["cs2.exe"],
                  tests: [onIPhone17ProMax(build: 47)],
                  note: "With Madeira's recommended settings. Start it with -insecure (community servers and bots): how VAC treats Madeira is unknown."),
        KnownGame(id: "escapists-2", title: "The Escapists 2", appIDs: [641990],
                  folders: ["the escapists 2"], programs: ["theescapists2.exe"],
                  tests: [onIPhone17ProMax(build: 47)], note: "With Madeira's recommended settings."),
        KnownGame(id: "terraria", title: "Terraria", appIDs: [105600],
                  folders: ["terraria"], programs: ["terraria.exe"],
                  tests: [onIPhone17ProMax(build: 47)], note: ""),
        KnownGame(id: "stardew-valley", title: "Stardew Valley", appIDs: [413150],
                  folders: ["stardew valley"], programs: ["stardew valley.exe"],
                  tests: [onIPhone17ProMax(build: 48)], note: ""),
        KnownGame(id: "slay-the-spire-2", title: "Slay the Spire 2", appIDs: [2868840],
                  folders: ["slay the spire 2"], programs: ["slaythespire2.exe"],
                  tests: [onIPhone17ProMax(build: 48)], note: "With Madeira's recommended settings."),
        // The campaign only: multiplayer (10190, iw4mp.exe) shares the folder and is untested.
        KnownGame(id: "modern-warfare-2-2009", title: "Call of Duty: Modern Warfare 2 (2009)", appIDs: [10180],
                  folders: [], programs: ["iw4sp.exe"],
                  tests: [onIPhone17ProMax(build: 48)], note: "The single-player campaign."),
        KnownGame(id: "project-zomboid", title: "Project Zomboid", appIDs: [108600],
                  folders: ["projectzomboid"], programs: ["projectzomboid64.exe"],
                  tests: [onIPhone17ProMax(build: 60)],
                  note: "With Madeira's recommended settings. Loading to the main menu takes about 2 to 3 minutes; it isn't frozen, so leave it running."),
        KnownGame(id: "megabonk", title: "Megabonk", appIDs: [],
                  folders: ["megabonk"], programs: ["megabonk.exe"],
                  tests: [KnownTest(device: nil, os: nil, build: 31, memoryGB: 0)], note: ""),
        // Multiplayer on Steam's x86-64 branch with -nochromium; the Chromium main menu doesn't load yet.
        KnownGame(id: "garrys-mod", title: "Garry's Mod", appIDs: [4000],
                  folders: ["garrysmod"], programs: ["gmod.exe"],
                  tests: [onIPhone17ProMax(build: 60)],
                  note: "Multiplayer, on Steam version x86-64 with -nochromium in Launch arguments and Madeira's recommended settings. The main menu doesn't load yet (\"Menu failed to load\"): use the server browser, or press ~ for the console and type connect <address>. Single player: in the console, gamemode sandbox, then map gm_construct. Server web pages (welcome screens, some HUD icons) stay blank."),
        KnownGame(id: "grounded", title: "Grounded", appIDs: [962130],
                  folders: ["grounded"], programs: ["maine-win64-shipping.exe"],
                  tests: [onIPhone17ProMax(build: 63)],
                  note: "With Madeira's recommended settings. Loading into the world is slow: much of the game's memory goes to the swap file on storage. Low graphics settings help."),
        KnownGame(id: "fallout-new-vegas", title: "Fallout: New Vegas", appIDs: [22380],
                  folders: ["fallout new vegas"], programs: ["falloutnv.exe"],
                  tests: [onIPhone17ProMax(build: 18)],
                  note: "Saves load with Older NVIDIA card (Direct3D 9), which Madeira turns on for it."),
        KnownGame(id: "batman-arkham-city", title: "Batman: Arkham City", appIDs: [200260],
                  folders: ["batman arkham city goty"], programs: ["batmanac.exe"],
                  tests: [onIPhone17ProMax(build: 63)],
                  note: "With Older NVIDIA card (Direct3D 9), which Madeira turns on for it. Without it the game opens its own launcher instead and the session ends."),
        // BlackOps.exe through Steam; multiplayer (42710, BlackOpsMP.exe) shares the folder and is untested.
        KnownGame(id: "black-ops-1", title: "Call of Duty: Black Ops", appIDs: [42700],
                  folders: [], programs: ["blackops.exe"],
                  tests: [onIPhone17ProMax(build: 64)],
                  note: "Through Steam, with Madeira's recommended settings. Multiplayer is untested."),
    ]

    /// The device test for a game: `windowsPath` is a program or a Steam game's install folder.
    static func find(windowsPath: String, steamAppID: Int?) -> KnownGame? {
        if let steamAppID, let game = all.first(where: { $0.appIDs.contains(steamAppID) }) { return game }
        guard let last = lastPart(windowsPath) else { return nil }
        if last.hasSuffix(".exe") { return all.first { $0.programs.contains(last) } }
        return all.first { $0.folders.contains(last) }
    }
    /// The last part of a Windows path, lowercased: a program or an install folder.
    static func lastPart(_ windowsPath: String) -> String? {
        windowsPath.replacingOccurrences(of: "/", with: "\\").lowercased().split(separator: "\\").last.map(String.init)
    }
}

/// A problem other players reported for one game on the main Madeira project's
/// issue tracker (github.com/willfaust/Madeira/issues) that this build does not
/// fix yet. Will it run? shows it as "Known issue: ..." with a link to the report.
/// Reports that Madeira has fixed since are left out of `KnownIssues.all`.
/// Recognised like KnownGame: a Steam App ID, the install folder or the program.
struct KnownIssue: Equatable {
    let id: String
    let game: String
    let appIDs: Set<Int>
    /// Lowercased folder names (steamapps\common or wherever it was copied).
    let folders: Set<String>
    /// Lowercased program names.
    let programs: Set<String>
    /// .caution when the game may not start or play; .info for smaller problems.
    let level: LaunchCheckNote.Level
    /// Short, after "Known issue: ".
    let title: String
    /// What happens and what to try, in plain words.
    let detail: String
    /// The report's number on github.com/willfaust/Madeira.
    let report: Int
    /// The Madeira version the report was made on ("0.1.3").
    let version: String

    var link: URL { URL(string: "https://github.com/willfaust/Madeira/issues/\(report)")! }
    var text: String { detail + " Reported by a player on Madeira \(version); it may behave differently in this build." }
}

enum KnownIssues {
    static let all: [KnownIssue] = [
        KnownIssue(id: "silksong-cutscenes", game: "Hollow Knight: Silksong", appIDs: [1030300],
                   folders: ["hollow knight silksong"], programs: ["hollow knight silksong.exe"], level: .info,
                   title: "cutscenes are black",
                   detail: "Gameplay works, but most cutscene videos show a black screen while their sound plays. If quitting the game doesn't end the session, use Force close Madeira.",
                   report: 364, version: "0.1.3"),
        KnownIssue(id: "portal-2-controller", game: "Portal 2", appIDs: [620],
                   folders: ["portal 2"], programs: ["portal2.exe"], level: .info,
                   title: "controllers may not work",
                   detail: "The game runs at 60 FPS, but neither the on-screen pad nor a Bluetooth controller reached it. The on-screen pad in Keyboard and mouse mode works.",
                   report: 192, version: "0.1.3"),
        KnownIssue(id: "nfs-most-wanted-2012-input", game: "Need for Speed: Most Wanted (2012)", appIDs: [1262580],
                   folders: [], programs: ["nfs13.exe"], level: .caution,
                   title: "stuck at \"Press any key\"",
                   detail: "Taps, keys and the on-screen pad went to the Windows desktop instead of the game window, so the title screen never moved on.",
                   report: 104, version: "0.1.0"),
        KnownIssue(id: "outlast-illegal-instruction", game: "Outlast", appIDs: [238320],
                   folders: ["outlast"], programs: ["olgame.exe"], level: .caution,
                   title: "crashes while starting",
                   detail: "The game stops with \"illegal instruction\" (C000001D) during loading. Try Game details > Compatibility > AVX and AVX2.",
                   report: 132, version: "0.1.3"),
        KnownIssue(id: "balatro-ipad-m5", game: "Balatro", appIDs: [2379780],
                   folders: ["balatro"], programs: ["balatro.exe"], level: .info,
                   title: "crash on iPad Pro M5",
                   detail: "On an iPad Pro M5 the game crashed during start-up when started with Start with > The game. Start it through Steam (Madeira Dock) instead.",
                   report: 255, version: "0.1.3"),
        KnownIssue(id: "minecraft-dungeons", game: "Minecraft Dungeons", appIDs: [1672970],
                   folders: ["minecraft dungeons"], programs: [], level: .caution,
                   title: "crashes at start",
                   detail: "The game crashed whether it was started from Steam or from its own program.",
                   report: 259, version: "0.1.3"),
        KnownIssue(id: "minecraft-dungeons-2", game: "Minecraft Dungeons II", appIDs: [],
                   folders: ["minecraft dungeons ii"], programs: [], level: .caution,
                   title: "crashes at start",
                   detail: "The game stops with an instruction the CPU translator can't run, before its window opens. Try Game details > Compatibility > AVX and AVX2.",
                   report: 254, version: "0.1.3"),
        KnownIssue(id: "beamng-drive", game: "BeamNG.drive", appIDs: [284160],
                   folders: ["beamng.drive"], programs: ["beamng.drive.x64.exe"], level: .caution,
                   title: "launch gives up",
                   detail: "\"Starting your game...\" stops after about 17 seconds and returns to the library with no error.",
                   report: 432, version: "0.1.3"),
        KnownIssue(id: "bright-memory-infinite", game: "Bright Memory: Infinite", appIDs: [1178830],
                   folders: ["bright memory infinite"], programs: [], level: .caution,
                   title: "doesn't start",
                   detail: "A player reported the game doesn't start.",
                   report: 332, version: "0.1.3"),
        KnownIssue(id: "imperial-glory-menus", game: "Imperial Glory", appIDs: [277450],
                   folders: ["imperial glory"], programs: [], level: .caution,
                   title: "menu buttons are invisible",
                   detail: "The main menu's background shows, but its buttons and text are not drawn. Changing Direct3D 9 mode, Windows version or resolution didn't help.",
                   report: 383, version: "0.1.3"),
        KnownIssue(id: "ff7-1998-free-apple-id", game: "Final Fantasy VII (1998)", appIDs: [39140],
                   folders: ["final fantasy vii"], programs: ["ff7.exe", "ff7_en.exe"], level: .info,
                   title: "black screen with a free Apple ID",
                   detail: "With a free Apple ID (no Memory+ or extended memory), the game stayed on \"Still starting\" because there wasn't room for a 32-bit game. A paid developer account with Memory+ avoids it.",
                   report: 390, version: "0.1.3"),
        KnownIssue(id: "tf2-gl-context", game: "Team Fortress 2", appIDs: [440],
                   folders: ["team fortress 2"], programs: [], level: .caution,
                   title: "\"Failed to create D3D9\"",
                   detail: "The game closed at once with \"Failed to get a GL context\". Set Settings > Graphics > Direct3D 9 back to DXMT (default) and try again.",
                   report: 424, version: "0.1.3"),
        KnownIssue(id: "kingdom-hearts-black", game: "Kingdom Hearts HD 1.5+2.5 ReMIX", appIDs: [2552430],
                   folders: [], programs: [], level: .caution,
                   title: "black screen",
                   detail: "Kingdom Hearts Final Mix and Kingdom Hearts II Final Mix stayed on a black screen at 0 FPS.",
                   report: 433, version: "0.1.3"),
        KnownIssue(id: "astroneer-config", game: "Astroneer", appIDs: [361420],
                   folders: ["astroneer"], programs: [], level: .caution,
                   title: "times out while starting",
                   detail: "The launch waited 150 seconds at the configuration step and gave up.",
                   report: 457, version: "0.1.3"),
        KnownIssue(id: "bad-company-2-campaign", game: "Battlefield: Bad Company 2", appIDs: [24960],
                   folders: ["battlefield bad company 2"], programs: ["bfbc2game.exe"], level: .caution,
                   title: "hangs at the campaign start",
                   detail: "The game gets to the campaign's \"October 6th\" intro text and stops there.",
                   report: 474, version: "0.1.3"),
        KnownIssue(id: "dark-souls-2-title", game: "Dark Souls II: Scholar of the First Sin", appIDs: [335300],
                   folders: [], programs: ["darksoulsii.exe"], level: .caution,
                   title: "black title screen, then a crash",
                   detail: "The title screen stayed black and the game crashed shortly after. It also didn't fill the screen.",
                   report: 492, version: "0.1.3"),
        KnownIssue(id: "undertale-fullscreen", game: "Undertale", appIDs: [391540],
                   folders: ["undertale"], programs: ["undertale.exe"], level: .info,
                   title: "doesn't fill the screen",
                   detail: "The game's small window doesn't grow to the whole screen. Try Game details > Display > Aspect & scaling, or a different Resolution.",
                   report: 492, version: "0.1.3"),
        KnownIssue(id: "cyberpunk-launcher", game: "Cyberpunk 2077", appIDs: [1091500],
                   folders: ["cyberpunk 2077"], programs: ["cyberpunk2077.exe", "redprelauncher.exe"], level: .caution,
                   title: "crashes in its launcher",
                   detail: "REDprelauncher crashed, and starting the game directly stopped before graphics started (8 GB iPad). Turn Memory+ on, start it through Steam, and add --launcher-skip to Launch arguments.",
                   report: 504, version: "0.1.3"),
        KnownIssue(id: "maplestory-launcher", game: "MapleStory", appIDs: [216150],
                   folders: ["maplestory"], programs: ["maplestory.exe"], level: .caution,
                   title: "Nexon launcher crashes",
                   detail: "The Nexon launcher asks for 64 GB of memory space at start and crashes, so it can't start the game.",
                   report: 329, version: "0.1.3"),
        KnownIssue(id: "lego-indiana-jones-relaunch", game: "LEGO Indiana Jones: The Original Adventures", appIDs: [32330],
                   folders: [], programs: ["legoindy.exe"], level: .caution,
                   title: "can close Madeira",
                   detail: "The game restarts itself through Steam, and that second start crashed the whole app. Older Steam games with the same copy protection may do the same.",
                   report: 234, version: "0.1.3"),
        KnownIssue(id: "civilization-vi-slow", game: "Sid Meier's Civilization VI", appIDs: [289070],
                   folders: ["sid meier's civilization vi"], programs: ["civilizationvi.exe"], level: .info,
                   title: "runs slowly",
                   detail: "The game runs but is held back by the CPU translator, so turns and menus are slow.",
                   report: 373, version: "0.1.3"),
        KnownIssue(id: "crysis-2-hang", game: "Crysis 2 Maximum Edition", appIDs: [108800],
                   folders: [], programs: ["crysis2.exe", "crysis2launcher.exe"], level: .caution,
                   title: "hangs before the picture starts",
                   detail: "The game stopped very early in start-up, before any graphics, every time it was tried. (Crysis 2 Remastered is a different game.)",
                   report: 446, version: "iDeck build 56"),
        KnownIssue(id: "burnout-paradise-sse2", game: "Burnout Paradise", appIDs: [24740, 1238080],
                   folders: [], programs: ["burnoutparadise.exe"], level: .caution,
                   title: "\"CPU Error\" about SSE2",
                   detail: "The game says SSE2 isn't supported and exits. Its CPU check misfires on CPUs with many cores: set Game details > Compatibility > CPU cores reported to 4.",
                   report: 116, version: "0.1.0"),
        KnownIssue(id: "diablo-2-resurrected", game: "Diablo II: Resurrected", appIDs: [],
                   folders: ["diablo ii resurrected"], programs: ["d2r.exe"], level: .caution,
                   title: "crashes while starting",
                   detail: "D2R.exe stopped while loading D2R_loader.dll, before the game's window opened.",
                   report: 354, version: "0.1.3"),
    ]

    /// The reports for a game: `windowsPath` is a program or a Steam game's install folder.
    static func find(windowsPath: String, steamAppID: Int?) -> [KnownIssue] {
        let last = KnownGames.lastPart(windowsPath)
        return all.filter { issue in
            if let steamAppID, issue.appIDs.contains(steamAppID) { return true }
            guard let last else { return false }
            return last.hasSuffix(".exe") ? issue.programs.contains(last) : issue.folders.contains(last)
        }
    }
}
