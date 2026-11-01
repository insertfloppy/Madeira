#!/usr/bin/env python3
"""The launchers' library sections (app/Madeira/LauncherGames.swift, docs/LAUNCHERS.md).

Source checks: the file is in the app target, the library lists one section per
launcher after Other games, and Other games leaves out what a launcher's section lists.

Swift (LauncherGames.swift's model half with LauncherSupport.swift's LauncherID): in
a scratch drive_c, each launcher's installer, launcher and games belong to its
section and nothing else does; the games each launcher installed are found, and the
ones already in the library are not offered again.
"""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc') or str(Path.home() / '.local/share/swiftly/bin/swiftc')
failures = 0


def require(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


games = (app / 'LauncherGames.swift').read_text()
support = (app / 'LauncherSupport.swift').read_text()
library = (app / 'Library.swift').read_text()
project = (root / 'app/Madeira.xcodeproj/project.pbxproj').read_text()

require(project.count('/* LauncherGames.swift in Sources */') == 2 and project.count('/* LauncherGames.swift */') == 3,
        'LauncherGames.swift is in the app target')
require('private var otherEntries: [LibraryEntry] { entries.filter { LauncherID.owner(of: $0) == nil } }' in library,
        'Other games leaves out what a launcher\'s section lists')
page = library[library.index('LibrarySectionHeader(title: "Other games"'):]
require(page.index('LauncherGamesSection(id: id') < page.index('GOGGamesSection('), 'the launchers\' sections follow Other games')
require('cells(entries, width: viewport.size.width)' not in page[:page.index('GOGGamesSection(')],
        'Other games shows otherEntries only')

enum = support[support.index('enum LauncherID'):support.index('@MainActor\nenum LauncherSupport')]
model = games[games.index('extension LauncherID {'):games.index('/// One launcher\'s library section.')]
stubs = r'''
import Foundation
struct LibraryEntry {
    var relativePath: String
    var title = ""
    var arguments = ""
    var desktop: Bool? = nil
    var steamAppID: Int? = nil
    var epicAppName: String? = nil
    var gogProductID: Int? = nil
    var itchGameID: Int? = nil
    var eaOfferID: String? = nil
}
enum LibraryModel {
    nonisolated(unsafe) static var drive = URL(fileURLWithPath: "/")
    nonisolated(unsafe) static var shared = Store()
    static func inspect(_ url: URL) throws -> LibraryEntry { LibraryEntry(relativePath: url.path) }
}
final class Store { var saved: [LibraryEntry] = []; func save(_ e: LibraryEntry) { saved.append(e) } }
enum LauncherSupport { static let downloadFolder = "Madeira Downloads" }
final class LogStore { nonisolated(unsafe) static let shared = LogStore(); func log(_ m: String) {} }
enum ItchProgram { static func find(in folder: URL, title: String) -> String? { title == "Mystery" ? nil : title + ".exe" } }
'''
checks = r'''
import Foundation
var failures = 0
func require(_ condition: @autoclosure () -> Bool, _ label: String) {
    if condition() { print("PASS: " + label) } else { print("FAIL: " + label); failures += 1 }
}
@main
struct Checks {
    @MainActor static func main() throws {
        let drive = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        LibraryModel.drive = drive
        func owner(_ path: String) -> LauncherID? { LauncherID.owner(of: LibraryEntry(relativePath: path)) }
        require(owner("Program Files (x86)/Ubisoft/Ubisoft Game Launcher/UbisoftConnect.exe") == .ubisoft
                && owner("Program Files (x86)/Ubisoft/Ubisoft Game Launcher/games/Far Cry 3/bin/farcry3.exe") == .ubisoft
                && owner("Madeira Downloads/UbisoftConnectInstaller.exe") == .ubisoft, "Ubisoft Connect: installer, client, games")
        require(owner("Program Files (x86)/Battle.net/Battle.net Launcher.exe") == .battleNet
                && owner("Program Files (x86)/Diablo IV/Diablo IV.exe") == .battleNet
                && owner("Madeira Downloads/Battle.net-Setup.exe") == .battleNet, "Battle.net: installer, client, Blizzard's game folders")
        require(owner("Program Files/Rockstar Games/Launcher/Launcher.exe") == .rockstar
                && owner("Program Files/Rockstar Games/Grand Theft Auto V Enhanced/PlayGTAV.exe") == .rockstar, "Rockstar: launcher and games")
        require(owner("Program Files (x86)/SquareEnix/FINAL FANTASY XIV - A Realm Reborn/game/ffxiv_dx11.exe") == .ffxiv
                && owner("Madeira Downloads/ffxivsetup.exe") == .ffxiv, "FFXIV: installer, launcher, game")
        require(owner("Games/Celeste/Celeste.exe") == nil && owner("Program Files (x86)/Ubisoft Other/x.exe") == nil
                && owner("Madeira Downloads/other.exe") == nil, "other programs stay in Other games")
        var steam = LibraryEntry(relativePath: "Program Files (x86)/Battle.net/Battle.net.exe"); steam.steamAppID = 1
        var desktop = LibraryEntry(relativePath: "Program Files/Rockstar Games/Launcher/Launcher.exe"); desktop.desktop = true
        require(LauncherID.owner(of: steam) == nil && LauncherID.owner(of: desktop) == nil, "store games and the Desktop keep their own places")

        let fm = FileManager.default
        for dir in ["Program Files (x86)/Ubisoft/Ubisoft Game Launcher/games/Far Cry 3", "Program Files (x86)/Ubisoft/Ubisoft Game Launcher/games/Anno 1800",
                    "Program Files (x86)/Diablo IV", "Program Files (x86)/Battle.net",
                    "Program Files/Rockstar Games/Launcher", "Program Files/Rockstar Games/Social Club", "Program Files/Rockstar Games/Red Dead Redemption 2",
                    "Program Files (x86)/SquareEnix/FINAL FANTASY XIV - A Realm Reborn/game", "Program Files (x86)/SquareEnix/FINAL FANTASY XIV - A Realm Reborn/boot"] {
            try fm.createDirectory(at: drive.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        fm.createFile(atPath: drive.appendingPathComponent("Program Files (x86)/SquareEnix/FINAL FANTASY XIV - A Realm Reborn/game/ffxiv_dx11.exe").path, contents: Data())
        let added = [LibraryEntry(relativePath: "Program Files (x86)/Ubisoft/Ubisoft Game Launcher/games/Anno 1800/Bin/Win64/Anno1800.exe"),
                     LibraryEntry(relativePath: "Program Files (x86)/SquareEnix/FINAL FANTASY XIV - A Realm Reborn/boot/ffxivboot.exe")]
        let ubi = LauncherGames.found(.ubisoft, entries: added).map(\.title)
        require(ubi == ["Far Cry 3"], "Ubisoft: the games folder's games, less the added ones (\(ubi))")
        let bnet = LauncherGames.found(.battleNet, entries: added).map(\.title)
        require(bnet == ["Diablo IV"], "Battle.net: Blizzard's folders that exist (\(bnet))")
        let rock = LauncherGames.found(.rockstar, entries: added).map(\.title)
        require(rock == ["Red Dead Redemption 2"], "Rockstar: its games, not the launcher or Social Club (\(rock))")
        let ff = LauncherGames.found(.ffxiv, entries: added)
        require(ff.map(\.title) == ["Final Fantasy XIV"], "FFXIV: the game is offered even with the launcher added")
        let ffGame = added + [LibraryEntry(relativePath: "Program Files (x86)/SquareEnix/FINAL FANTASY XIV - A Realm Reborn/game/ffxiv_dx11.exe")]
        require(LauncherGames.found(.ffxiv, entries: ffGame).isEmpty, "FFXIV: not offered once the game is added")
        require(LauncherGames.add(ff[0]) == nil && LibraryModel.shared.saved.last?.relativePath.hasSuffix("/game/ffxiv_dx11.exe") == true
                && LibraryModel.shared.saved.last?.title == "Final Fantasy XIV", "adding FFXIV adds its game")
        // Blizzard games start through Battle.net (--exec="launch <code>"), as Lutris starts them.
        require(LauncherID.blizzardLaunch(folder: "Program Files (x86)/StarCraft") == "--exec=\"launch S1\""
                && LauncherID.blizzardLaunch(folder: "Program Files (x86)/StarCraft II") == "--exec=\"launch S2\""
                && LauncherID.blizzardLaunch(folder: "Program Files (x86)/Diablo IV") == "--exec=\"launch Fen\""
                && LauncherID.blizzardLaunch(folder: "Program Files (x86)/Call of Duty") == nil, "Blizzard product codes")
        fm.createFile(atPath: drive.appendingPathComponent("Program Files (x86)/Battle.net/Battle.net Launcher.exe").path, contents: Data())
        let d4 = LauncherGames.found(.battleNet, entries: added)[0]
        require(LauncherGames.add(d4) == nil && LibraryModel.shared.saved.last?.relativePath.hasSuffix("/Battle.net/Battle.net Launcher.exe") == true
                && LibraryModel.shared.saved.last?.arguments == "--exec=\"launch Fen\"" && LibraryModel.shared.saved.last?.title == "Diablo IV",
                "adding a Blizzard game adds Battle.net's launcher with --exec=\"launch <code>\"")
        require(LauncherGames.found(.battleNet, entries: added + [LibraryModel.shared.saved.last!]).isEmpty,
                "a Blizzard game added through Battle.net is not offered again")
        require(LauncherGames.add(LauncherFoundGame(folder: "Games/Mystery"))?.contains("choose its .exe") == true,
                "a game without one clear program asks for +")
        if failures > 0 { exit(1) }
    }
}
'''
with tempfile.TemporaryDirectory(prefix='madeira-launcher-games-') as tmp:
    tmp = Path(tmp)
    drive = tmp / 'drive_c'; drive.mkdir()
    (tmp / 'stubs.swift').write_text(stubs)
    (tmp / 'model.swift').write_text('import Foundation\n' + enum + model)
    (tmp / 'checks.swift').write_text(checks)
    exe = tmp / 'check'
    if not Path(SWIFTC).exists() and not shutil.which(SWIFTC):
        if '--require-swift' in sys.argv:
            require(False, 'Swift compiler available (--require-swift)')
        else:
            print('SKIP: Swift compiler unavailable; the compiled launcher section checks did not run')
    else:
        build = subprocess.run([SWIFTC, '-parse-as-library', '-swift-version', '5', '-o', str(exe),
                                str(tmp / 'stubs.swift'), str(tmp / 'model.swift'), str(tmp / 'checks.swift')])
        require(build.returncode == 0, 'the launcher sections\' model compiles on the host')
        if build.returncode == 0:
            run = subprocess.run([str(exe), str(drive)])
            require(run.returncode == 0, 'launcher section checks pass')

if failures:
    print(f'FAILURES: {failures}')
    sys.exit(1)
print('PASS: the launchers\' library sections')
