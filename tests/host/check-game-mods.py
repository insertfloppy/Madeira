#!/usr/bin/env python3
"""Game details > Mods (app/Madeira/GameMods.swift).

Mods from a .zip or an unpacked folder, put where the game expects them (game folder,
Data, BepInEx, BepInEx/plugins/<mod>), recorded so Remove takes them back out; BepInEx 5
for Unity (Mono) games in one tap, pinned by SHA-256, with winhttp=n,b.

Source checks (every host): the page is in Game details, the file is in the project, the
BepInEx pins match the release files.

Swift fixture (macOS CI with --require-swift; skipped without a compiler): the part of
GameMods.swift above "MARK: Views" on synthetic mods.
"""
from pathlib import Path
import argparse, os, re, shutil, subprocess, sys, tempfile

parser = argparse.ArgumentParser()
parser.add_argument('--require-swift', action='store_true')
args = parser.parse_args()

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
failures = 0


def check(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


source = (app / 'GameMods.swift').read_text(encoding='utf-8')
library = (app / 'Library.swift').read_text(encoding='utf-8')
project = (app.parent / 'Madeira.xcodeproj/project.pbxproj').read_text(encoding='utf-8')

check('case .mods: GameModsSection(entry: entry)' in library and '[.library, .iniFiles, .dllOverrides, .mods, .advanced]' in library,
      'Game details has a Mods page for games (not the Desktop)')
check(project.count('A1009C02 /* GameMods.swift in Sources */') == 2 and project.count('A2009C02 /* GameMods.swift */') == 3,
      'GameMods.swift is in the app target')
# BepInEx 5.4.23.5 release zips, checked 2026-10-31.
check('static let version = "5.4.23.5"' in source and
      '82f9878551030f54657792c0740d9d51a09500eeae1fba21106b0c441e6732c4' in source and
      '37651c79e40d6f909572a4f461ac25350bb3ef8fe7fbd29f1aa8791a33b84c82' in source,
      'BepInEx downloads are pinned by SHA-256')
check('WineMonoInstaller.sha256(of: temp) == pin.sha256' in source, 'the download is checked before it is installed')
check('overrides.set(dll, "n,b")' in source and 'dllOverride: "winhttp"' in source,
      "BepInEx's Doorstop gets winhttp=n,b in the game's DLL overrides")
foundation = source[:source.index('// MARK: Views')]
code = '\n'.join(l for l in foundation.splitlines() if not l.strip().startswith('//'))
check('LibraryModel' not in code and 'LogStore' not in code and 'LibraryEntry' not in code,
      'the model part is Foundation only')

main_swift = r'''
import Foundation
func show(_ p: ModPlan) -> String {
    p.place.rawValue + ":" + p.targets(p.place, dataFolder: "Data").map(\.path).joined(separator: ",") + ":\(p.skipped)"
}
func plan(_ names: [String], _ name: String = "Cool Mod-1.2.zip", data: String? = nil, bep: Bool = false) -> String {
    show(ModPlan.make(names: names, modName: name, dataFolder: data, hasBepInEx: bep))
}
print("wrap=" + plan(["Cool Mod/", "Cool Mod/Data/a.esp", "Cool Mod/Data/meshes/x.nif", "__MACOSX/._a", "Cool Mod/.DS_Store"], data: "Data"))
print("loose=" + plan(["a.esp", "textures/t.dds"], data: "Data"))
print("nodata=" + plan(["a.esp", "textures/t.dds"]))
print("nvse=" + plan(["nvse_loader.exe", "nvse_1_4.dll", "Data/NVSE/Plugins/x.dll"], data: "data"))
print("thunder=" + plan(["manifest.json", "icon.png", "README.md", "Mod.dll"], "Author-Mod-1.0.0.zip"))
print("thunderdirs=" + plan(["manifest.json", "plugins/Mod.dll", "config/mod.cfg"]))
print("pack=" + plan(["manifest.json", "icon.png", "BepInExPack/winhttp.dll", "BepInExPack/BepInEx/core/BepInEx.dll", "BepInExPack/doorstop_config.ini"]))
print("bepinex=" + plan(["winhttp.dll", "doorstop_config.ini", ".doorstop_version", "BepInEx/core/BepInEx.dll"]))
print("plugin=" + plan(["MyPlugin.dll"], bep: true))
print("plain=" + plan(["MyPlugin.dll"]))
print("tool=" + plan(["Tool.exe", "lib.dll"], bep: true))
print("evil=" + plan(["../../x.dll", "/abs.dll", "ok.txt", "a\\b.txt"]))
let doorstop = ModPlan.make(names: ["winhttp.dll", "BepInEx/core/a.dll"], modName: "B", dataFolder: nil, hasBepInEx: false)
print("doorstop=\(doorstop.loadsDoorstop(at: .gameFolder))\(doorstop.loadsDoorstop(at: .bepinex))")
let p = ModPlan.make(names: ["a.esp"], modName: "x", dataFolder: "Data", hasBepInEx: false)
print("moved=" + p.targets(.bepinexPlugins, dataFolder: "Data").map(\.path).joined(separator: ","))
print("name=" + ModPlan.cleanName("A/B:C.7z") + "|" + ModPlan.cleanName(".zip"))
let a = InstalledMod(id: UUID(), name: "a", installed: Date(), files: ["G/x.dll", "G/y.dll"], replaced: [], dllOverride: nil)
let b = InstalledMod(id: UUID(), name: "b", installed: Date(), files: ["g/X.dll"], replaced: ["g/X.dll"], dllOverride: nil)
print("removable=" + GameModRecords.removable(a, in: [a, b]).joined(separator: ",") + "|" + GameModRecords.removable(b, in: [a, b]).joined(separator: ","))
print("unity=" + [GameModRecords.unityKind(topNames: ["UnityPlayer.dll", "Game.exe"], hasManaged: true),
                  GameModRecords.unityKind(topNames: ["GameAssembly.dll", "UnityPlayer.dll"], hasManaged: false),
                  GameModRecords.unityKind(topNames: ["Game.exe"], hasManaged: false)].map { $0 ?? "nil" }.joined(separator: ","))
print("pin=" + BepInExPin.pin(bits: 32).url.absoluteString + "|" + BepInExPin.pin(bits: 0).arch)
'''

compiler = os.environ.get('SWIFTC') or shutil.which('swiftc')
if not compiler:
    print('SKIP: Swift compiler unavailable locally; macOS CI must run this check with --require-swift')
    if args.require_swift:
        failures += 1
else:
    with tempfile.TemporaryDirectory(prefix='madeira-mods-', dir=os.environ.get('TMPDIR')) as directory:
        temporary = Path(directory)
        body = foundation
        for line in ('import SwiftUI\n', 'import UIKit\n', 'import UniformTypeIdentifiers\n'):
            body = body.replace(line, '')
        (temporary / 'GameMods.swift').write_text(body)
        (temporary / 'main.swift').write_text(main_swift)
        binary = temporary / 'mods'
        subprocess.run(compiler.split() + ['-swift-version', '5', str(temporary / 'GameMods.swift'), str(temporary / 'main.swift'),
                                           '-o', str(binary)], check=True)
        out = dict(line.split('=', 1) for line in subprocess.run([str(binary)], capture_output=True, text=True,
                                                                 check=True).stdout.splitlines())
        check(out['wrap'] == 'gameFolder:Data/a.esp,Data/meshes/x.nif:2', 'a wrapping folder is opened; macOS litter is left out')
        check(out['loose'] == 'dataFolder:Data/a.esp,Data/textures/t.dds:0', 'loose plugins and meshes/textures go into Data')
        check(out['nodata'] == 'gameFolder:a.esp,textures/t.dds:0', 'a game without a Data folder gets them in its folder')
        check(out['nvse'] == 'gameFolder:nvse_loader.exe,nvse_1_4.dll,data/NVSE/Plugins/x.dll:0',
              "a script extender lands in the game's folder, its Data part in the game's own Data spelling")
        check(out['thunder'] == 'bepinexPlugins:BepInEx/plugins/Author-Mod-1.0.0/Mod.dll:3',
              'a Thunderstore plugin goes to BepInEx/plugins/<mod>, without its package files')
        check(out['thunderdirs'] == 'bepinex:BepInEx/plugins/Mod.dll,BepInEx/config/mod.cfg:1', 'plugins/ and config/ go under BepInEx')
        check(out['pack'] == 'gameFolder:winhttp.dll,BepInEx/core/BepInEx.dll,doorstop_config.ini:2',
              "BepInExPack's contents go into the game's folder")
        check(out['bepinex'] == 'gameFolder:winhttp.dll,doorstop_config.ini,.doorstop_version,BepInEx/core/BepInEx.dll:0',
              "BepInEx itself goes into the game's folder")
        check(out['plugin'] == 'bepinexPlugins:BepInEx/plugins/Cool Mod-1.2/MyPlugin.dll:0', 'a DLL for a game with BepInEx is a plugin')
        check(out['plain'] == 'gameFolder:MyPlugin.dll:0', "a DLL for a game without BepInEx goes into the game's folder")
        check(out['tool'] == 'gameFolder:Tool.exe,lib.dll:0', 'a mod with a program is not a plugin')
        check(out['evil'] == 'gameFolder:ok.txt,a/b.txt:2', 'nothing may leave the folder; backslash paths are read')
        check(out['doorstop'] == 'truefalse', "Doorstop in the game's folder needs winhttp=n,b")
        check(out['moved'] == 'BepInEx/plugins/x/a.esp', 'the player can move a mod to another place')
        check(out['name'] == 'A-B-C|Mod', 'mod names make safe folder names')
        check(out['removable'] == 'G/y.dll|g/X.dll', 'Remove leaves a file a later mod also wrote')
        check(out['unity'] == 'mono,il2cpp,nil', 'Unity games are told apart (Mono gets BepInEx 5)')
        check(out['pin'] == 'https://github.com/BepInEx/BepInEx/releases/download/v5.4.23.5/BepInEx_win_x86_5.4.23.5.zip|x64',
              '32-bit games get the x86 BepInEx, others x64')

print('FAIL' if failures else 'PASS')
sys.exit(1 if failures else 0)
