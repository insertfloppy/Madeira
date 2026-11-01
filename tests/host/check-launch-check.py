#!/usr/bin/env python3
""""Will it run?" on Game details (app/Madeira/LaunchCheck.swift).

Checks the wiring (both files in the Xcode project, the card under Play, the
"Play anyway?" question before LaunchCurtain), then compiles LaunchCheck.swift
with a harness and runs it against fixture game folders: anti-cheat found,
DLL imports resolved or missing, .NET without Wine Mono, Steam's minimum
memory parsed from store HTML, low free space, and a clean game.
"""
from pathlib import Path
import os, shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
check_swift = (app / 'LaunchCheck.swift').read_text(encoding='utf-8')
view = (app / 'LaunchCheckView.swift').read_text(encoding='utf-8')
library = (app / 'Library.swift').read_text(encoding='utf-8')
pbx = (app.parent / 'Madeira.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
SWIFTC = os.environ.get('SWIFTC') or shutil.which('swiftc')
failures = 0


def check(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


for name in ('LaunchCheck.swift', 'LaunchCheckView.swift'):
    check(pbx.count(f'/* {name} in Sources */') == 2 and pbx.count(f'/* {name} */ = {{isa = PBXFileReference') == 1,
          f'{name} is in the Xcode project and its Sources phase')
check('import UIKit' not in check_swift and 'import SwiftUI' not in check_swift, 'LaunchCheck.swift stays UI-free (host-compilable)')
check('LaunchCheckSection(notes: launchNotes, fix: launchCheckFix)' in library, 'Game details shows the card')
start = library[library.index('    private func start() {'):]
start = start[:start.index('\n    }\n') + 6]
check(start.index('LaunchCheck.acknowledged') < start.index('LaunchCurtain.shared.begin'),
      'Play asks "Play anyway?" before the launch starts')
check('case .getWineGecko: WineGeckoModel.shared.install()' in library
      and 'input.geckoAvailable = WineGeckoModel.available' in view, 'Get Wine Gecko is wired')
check('!confirmPlayAnyway' in library, 'the controller\'s accept does not launch past the question')
check('Button("Play anyway")' in library and 'LaunchCheck.acknowledge(entry' in library, 'Play anyway remembers the answer')
check('LogStore.shared.log(logLine(' in view, 'the result is logged as [will-it-run]')
check('KnownGames.find(windowsPath: entry.windowsPath, steamAppID: entry.steamAppID) != nil { texts.append("Tested") }' in library,
      'the library shows a Tested pill')
check('input.tested = KnownGames.find(' in view, 'Will it run? names a device test')
known = (app / 'GameRecommendations.swift').read_text(encoding='utf-8')
for ident in ('counter-strike-2', 'escapists-2', 'fallout-new-vegas'):
    check(f'id: "{ident}"' in known, f'tested game {ident} has recommended settings')

harness = r'''
import Foundation
func expect(_ ok: Bool, _ label: String) { print((ok ? "PASS: " : "FAIL: ") + label) }
let args = CommandLine.arguments
let fixtures = URL(fileURLWithPath: args[1])
let gb: UInt64 = 1_073_741_824

// Anti-cheat
expect(LaunchCheck.antiCheat(in: fixtures.appendingPathComponent("eac")) == "Easy Anti-Cheat", "EasyAntiCheat folder found")
expect(LaunchCheck.antiCheat(in: fixtures.appendingPathComponent("be")) == "BattlEye", "BEService two levels down found")
expect(LaunchCheck.antiCheat(in: fixtures.appendingPathComponent("clean")) == nil, "a clean game has no anti-cheat")
expect(LaunchCheck.antiCheat(in: fixtures.appendingPathComponent("deep")) == nil, "markers deeper than three levels are not searched")

// Game folders
let drive = URL(fileURLWithPath: "/d")
expect(LaunchCheck.gameFolder(drive: drive, relativeProgram: "GOG Games/Foo/bin/foo.exe").path == "/d/GOG Games/Foo", "GOG install folder")
expect(LaunchCheck.gameFolder(drive: drive, relativeProgram: "Program Files/Epic Games/Bar/Binaries/Win64/bar.exe").path == "/d/Program Files/Epic Games/Bar", "Epic install folder")
expect(LaunchCheck.gameFolder(drive: drive, relativeProgram: "Stuff/Baz/Binaries/Win64/baz.exe").path == "/d/Stuff/Baz", "Binaries/Win64 climbed out of")
expect(LaunchCheck.gameFolder(drive: drive, relativeProgram: "Stuff/Qux/qux.exe").path == "/d/Stuff/Qux", "program's own folder")

// DLLs
let missing = LaunchCheck.missingDLLs(imports: ["kernel32.dll", "steam_api64.dll", "api-ms-win-crt-runtime-l1-1-0.dll", "msvcp140.dll",
                                                "mfc140u.dll", "physxloader.dll", "physxloader.dll", "xinput1_3.dll"],
                                      available: ["kernel32.dll", "steam_api64.dll"])
expect(missing == ["physxloader.dll"], "only a DLL nobody provides is missing, once: \(missing)")
expect(LaunchCheck.missingDLLs(imports: ["kernel32.dll", "foo.dll"], available: []).isEmpty, "unreadable system folders report nothing")
expect(LaunchCheck.fileNames(in: [fixtures.appendingPathComponent("clean")]).contains("game.exe"), "file names are read lowercased")

// Memory
expect(LaunchCheck.minimumMemory(html: "<ul><li><strong>Memory:</strong> 8 GB RAM<br></li></ul>") == 8 * gb, "8 GB RAM parsed")
expect(LaunchCheck.minimumMemory(html: "<strong>Memory:</strong> 512 MB RAM") == 512 * 1_048_576, "512 MB parsed")
expect(LaunchCheck.minimumMemory(html: "<strong>Memory:</strong> 1,5 GB RAM") == UInt64(1.5 * Double(gb)), "decimal comma parsed")
expect(LaunchCheck.minimumMemory(html: "<strong>Storage:</strong> 8 GB available space") == nil, "storage is not memory")

func ids(_ input: LaunchCheck.Input) -> [String] { LaunchCheck.notes(input).map(\.id) }
var base = LaunchCheck.Input()
base.program = fixtures.appendingPathComponent("clean/game.exe")
base.physicalMemory = 12 * gb - 300 * 1_048_576
base.freeBytes = Int64(50 * gb)
expect(ids(base).isEmpty, "a clean game has no notes")

var input = base
input.steamMinimumMemory = 12 * gb
expect(ids(input).isEmpty, "12 GB minimum on a 12 GB device (reported a little lower) is fine")
input.steamMinimumMemory = 16 * gb
let memory = LaunchCheck.notes(input)
expect(memory.map(\.id) == ["memory"] && memory[0].detail.contains("16 GB") && memory[0].detail.contains("12 GB"), "16 GB minimum warns with both sizes")

input = base; input.program = fixtures.appendingPathComponent("clean/gone.exe")
expect(ids(input) == ["missing-program"], "a missing program is a problem")
input.programRequired = false
expect(ids(input).isEmpty, "Dock games' program is not required")
input = base; input.program = fixtures.appendingPathComponent("clean/gone.exe"); input.programIsSteam = true
expect(LaunchCheck.notes(input).first?.fix == .steamPage, "a Steam game's missing program links to its Steam page")

input = base; input.antiCheat = "Easy Anti-Cheat"; input.deviceName = "iPad"
let ac = LaunchCheck.notes(input)
expect(ac.map(\.id) == ["anticheat"] && ac[0].level == .caution && ac[0].detail.contains("iPad"), "anti-cheat is a caution naming the device")
input.antiCheatSkipped = true
expect(ids(input) == ["anticheat-off"], "an official no-anti-cheat start is info only")

input = base; input.imports = ["mscoree.dll", "foo.dll"]; input.available = ["mscoree.dll", "kernel32.dll"]; input.monoAvailable = false
let mono = LaunchCheck.notes(input)
expect(Set(mono.map(\.id)) == ["missing-dll", "mono"] && mono.first { $0.id == "mono" }?.fix == .getWineMono, ".NET without Wine Mono offers Get Wine Mono")
expect(mono.first { $0.id == "missing-dll" }?.title == "Missing foo.dll", "one missing DLL is named in the title")
input = base; input.imports = ["mshtml.dll"]; input.available = ["mshtml.dll", "kernel32.dll"]; input.geckoAvailable = false; input.bits = 32
let gecko = LaunchCheck.notes(input)
expect(gecko.map(\.id) == ["gecko"] && gecko[0].level == .info && gecko[0].fix == .getWineGecko, "a web-page program without Wine Gecko offers Get Wine Gecko")
input.geckoAvailable = true
expect(ids(input).isEmpty, "no Gecko line once it is downloaded")

input = base; input.freeBytes = Int64(gb)
expect(LaunchCheck.notes(input).first?.level == .caution, "1 GB free is a caution")
input.freeBytes = 100 * 1_048_576
expect(LaunchCheck.notes(input).first?.level == .problem, "100 MB free is a problem")

input = base; input.antiCheat = "BattlEye"; input.freeBytes = 100 * 1_048_576
expect(LaunchCheck.notes(input).map(\.level) == [.problem, .caution], "most serious first")
expect(LaunchCheck.logLine(title: "X", notes: LaunchCheck.notes(input)) == "[will-it-run] X: space=problem anticheat=caution", "log line")
// Known games
expect(KnownGames.find(windowsPath: #"C:\Program Files (x86)\Steam\steamapps\common\Counter-Strike Global Offensive"#, steamAppID: 730)?.id == "counter-strike-2", "CS2 by App ID")
expect(KnownGames.find(windowsPath: #"C:\x\steamapps\common\The Escapists 2"#, steamAppID: nil)?.id == "escapists-2", "Escapists 2 by folder")
expect(KnownGames.find(windowsPath: #"C:\Games\Megabonk\Megabonk.exe"#, steamAppID: nil)?.id == "megabonk", "Megabonk by program")
expect(KnownGames.find(windowsPath: #"C:\x\steamapps\common\ProjectZomboid"#, steamAppID: 108600)?.id == "project-zomboid", "Project Zomboid by app ID")
expect(KnownGames.find(windowsPath: #"C:\x\steamapps\common\Stardew Valley\Stardew Valley.exe"#, steamAppID: nil)?.id == "stardew-valley"
       && KnownGames.find(windowsPath: "", steamAppID: 413150)?.tests.first?.build == 48, "Stardew Valley by program and App ID, build 48")
expect(KnownGames.find(windowsPath: #"C:\x\steamapps\common\Slay the Spire 2\SlayTheSpire2.exe"#, steamAppID: nil)?.id == "slay-the-spire-2"
       && KnownGames.find(windowsPath: "", steamAppID: 2868840)?.tests.first?.build == 48, "Slay the Spire 2 by program and App ID, build 48")
expect(KnownGames.find(windowsPath: #"C:\x\steamapps\common\Call of Duty Modern Warfare 2\iw4sp.exe"#, steamAppID: nil)?.id == "modern-warfare-2-2009"
       && KnownGames.find(windowsPath: "", steamAppID: 10180)?.tests.first?.build == 48, "MW2 (2009) campaign by program and App ID, build 48")
expect(KnownGames.find(windowsPath: #"C:\x\steamapps\common\Call of Duty Modern Warfare 2\iw4mp.exe"#, steamAppID: 10190) == nil, "MW2 multiplayer is not marked tested")
expect(KnownGames.find(windowsPath: #"C:\x\steamapps\common\GarrysMod\bin\win64\gmod.exe"#, steamAppID: nil)?.id == "garrys-mod"
       && KnownGames.find(windowsPath: "", steamAppID: 4000)?.tests.first?.build == 60, "Garry's Mod by program and App ID, build 60")
expect(KnownGames.find(windowsPath: #"C:\Games\Foo\foo.exe"#, steamAppID: 620) == nil, "other games are not known")
expect(Set(KnownGames.all.map(\.id)).count == KnownGames.all.count, "known game ids are unique")
input = base; input.tested = KnownGames.all[0]
let tested = LaunchCheck.notes(input)
expect(tested.map(\.id) == ["tested"] && tested[0].level == .good
       && tested[0].detail.hasPrefix("Tested on iPhone 17 Pro Max (iOS 27), Madeira build 47.") && !tested[0].detail.contains("less than"),
       "a tested game names the device, iOS and build: \(tested[0].detail)")
var small = input; small.physicalMemory = 8 * gb - 400 * 1_048_576
let hint = LaunchCheck.notes(small).first { $0.id == "tested" }?.detail ?? ""
expect(hint.contains("This iPhone has 8 GB of memory, less than the 12 GB it was tested with"), "less memory than the tested device is pointed out: \(hint)")
let mega = KnownGames.find(windowsPath: #"C:\Games\Megabonk\Megabonk.exe"#, steamAppID: nil)!
expect(mega.detail(deviceName: "iPhone", physicalMemory: 4 * gb) == "Tested on Madeira build 31.", "no device recorded: build only, no memory hint")
input.antiCheat = "Valve Anti-Cheat"
expect(LaunchCheck.notes(input).last?.id == "tested", "the good line sorts last")
expect(LaunchCheck.gigabytes(12 * gb - 1) == "12 GB" && LaunchCheck.gigabytes(gb + gb / 2) == "1.5 GB", "sizes in words")
'''

if not SWIFTC:
    print('SKIP: swiftc not found, LaunchCheck.swift not run')
else:
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        fx = tmp / 'fixtures'
        for path in ['eac/EasyAntiCheat/x.txt', 'be/Binaries/BEService_x64.exe', 'clean/game.exe', 'clean/data/a.pak',
                     'deep/a/b/c/BattlEye/x']:
            (fx / path).parent.mkdir(parents=True, exist_ok=True)
            (fx / path).write_text('x')
        (tmp / 'main.swift').write_text(harness, encoding='utf-8')
        subprocess.run([SWIFTC, str(app / 'LaunchCheck.swift'), str(tmp / 'main.swift'), '-o', str(tmp / 'run')], check=True)
        out = subprocess.run([str(tmp / 'run'), str(fx)], check=True, capture_output=True, text=True).stdout
        print(out, end='')
        failures += out.count('FAIL: ')
        check(out.count('PASS: ') >= 30, 'harness ran every case')

if failures:
    print(f'{failures} check(s) failed')
    sys.exit(1)
print('PASS: "Will it run?" checks')
