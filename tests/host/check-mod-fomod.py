#!/usr/bin/env python3
"""FOMOD installers and plugins.txt (app/Madeira/ModFomod.swift).

A mod with fomod/ModuleConfig.xml asks for its options (as Vortex and Mod Organizer
do) and installs the chosen files into the game's Data folder; a plugin it installs is
turned on in %LOCALAPPDATA%\\<game>\\plugins.txt and turned off again on Remove.

Source checks (every host): the file is in the app target, the Mods page runs the
installer and turns plugins on.

Swift fixture (macOS CI with --require-swift; skipped without a compiler): the parser
and the choices on a ModuleConfig.xml shaped like a lighting overhaul's (UTF-16, a
declaration naming the wrong encoding, steps shown by flags, option types depending on
plugins, conditional files, folders, priorities), and plugins.txt / Fallout.ini edits.
"""
from pathlib import Path
import argparse, os, shutil, subprocess, sys, tempfile

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


source = (app / 'ModFomod.swift').read_text(encoding='utf-8')
mods = (app / 'GameMods.swift').read_text(encoding='utf-8')
project = (app.parent / 'Madeira.xcodeproj/project.pbxproj').read_text(encoding='utf-8')

check(project.count('A1009C06 /* ModFomod.swift in Sources */') == 2 and project.count('A2009C06 /* ModFomod.swift */') == 3,
      'ModFomod.swift is in the app target')
check('FomodInstallerSheet(' in mods and 'Fomod.root(in: names)' in mods, 'a mod with a FOMOD installer asks for its options')
check('BethesdaPlugins.activate(' in mods and 'BethesdaPlugins.deactivate(' in mods, 'plugins are turned on at install and off at Remove')
check('import SwiftUI' not in source and 'LibraryModel' not in source, 'ModFomod.swift is Foundation only')

config = r'''<?xml version="1.0" encoding="utf-8"?>
<config xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://qconsulting.ca/fo3/ModConfig5.0.xsd">
  <moduleName>Lighting Overhaul NV</moduleName>
  <moduleImage path="fomod\images\main.png"/>
  <requiredInstallFiles>
    <folder source="00 Core" destination="" priority="0"/>
    <file source="docs\readme.txt" destination="Docs\LO readme.txt"/>
  </requiredInstallFiles>
  <installSteps order="Explicit">
    <installStep name="Main">
      <optionalFileGroups order="Explicit">
        <group name="Interiors" type="SelectExactlyOne">
          <plugins order="Explicit">
            <plugin name="Dark interiors">
              <description><![CDATA[Darker interiors & caves.]]></description>
              <image path="fomod\images\dark.png"/>
              <files><file source="01 Dark\LO - Dark.esp" destination="LO.esp"/></files>
              <conditionFlags><flag name="look">dark</flag></conditionFlags>
              <typeDescriptor><type name="Recommended"/></typeDescriptor>
            </plugin>
            <plugin name="Vanilla interiors">
              <description>Brighter.</description>
              <files><file source="02 Vanilla\LO - Vanilla.esp" destination="LO.esp"/></files>
              <conditionFlags><flag name="look">vanilla</flag></conditionFlags>
              <typeDescriptor><type name="Optional"/></typeDescriptor>
            </plugin>
          </plugins>
        </group>
        <group name="Extras" type="SelectAny">
          <plugins order="Ascending">
            <plugin name="Zeta lights">
              <description>Extra lamps.</description>
              <files><folder source="03 Zeta" destination="meshes\zeta" priority="1"/></files>
              <typeDescriptor><type name="Optional"/></typeDescriptor>
            </plugin>
            <plugin name="DLC patch">
              <description>Needs Dead Money.</description>
              <files><file source="04 DLC\LO - DM.esp" destination="LO - DM.esp"/></files>
              <typeDescriptor>
                <dependencyType>
                  <defaultType name="NotUsable"/>
                  <patterns>
                    <pattern>
                      <dependencies operator="And"><fileDependency file="DeadMoney.esm" state="Active"/></dependencies>
                      <type name="Recommended"/>
                    </pattern>
                  </patterns>
                </dependencyType>
              </typeDescriptor>
            </plugin>
          </plugins>
        </group>
      </optionalFileGroups>
    </installStep>
    <installStep name="Dark tweaks">
      <visible><flagDependency flag="look" value="dark"/></visible>
      <optionalFileGroups order="Explicit">
        <group name="Brightness" type="SelectAtMostOne">
          <plugins order="Explicit">
            <plugin name="Pitch black">
              <description>Very dark.</description>
              <files><file source="05 Black\black.ini" destination="black.ini"/></files>
              <typeDescriptor><type name="Optional"/></typeDescriptor>
            </plugin>
          </plugins>
        </group>
      </optionalFileGroups>
    </installStep>
  </installSteps>
  <conditionalFileInstalls>
    <patterns>
      <pattern>
        <dependencies operator="And"><flagDependency flag="look" value="dark"/></dependencies>
        <files><file source="06 Patch\dark patch.esp" destination="LO dark patch.esp" priority="2"/></files>
      </pattern>
    </patterns>
  </conditionalFileInstalls>
</config>
'''

names = ['fomod/ModuleConfig.xml', 'fomod/images/dark.png', '00 Core/meshes/lights/a.nif', '00 Core/LO - Core.esm',
         'docs/readme.txt', '01 Dark/LO - Dark.esp', '02 Vanilla/LO - Vanilla.esp', '03 Zeta/z1.nif', '03 Zeta/sub/z2.nif',
         '04 DLC/LO - DM.esp', '05 Black/black.ini', '06 Patch/dark patch.esp']

main_swift = r'''
import Foundation
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let names = try! String(contentsOf: dir.appendingPathComponent("names.txt"), encoding: .utf8).split(separator: "\n").map(String.init)
let fomod = try! Fomod(xml: Data(contentsOf: dir.appendingPathComponent("ModuleConfig.xml")))
func noDLC(_ name: String) -> String { "Missing" }
func withDLC(_ name: String) -> String { name.lowercased() == "deadmoney.esm" ? "Active" : "Missing" }
print("name=\(fomod.name)|\(fomod.steps.count)|\(fomod.steps[0].groups.map(\.name).joined(separator: ","))")
print("order=" + fomod.steps[0].groups[1].options.map(\.name).joined(separator: ","))
print("desc=" + fomod.steps[0].groups[0].options[0].description + "|" + (fomod.steps[0].groups[0].options[0].image ?? "nil"))
var sel = fomod.defaultSelection(plugin: noDLC)
print("default=\(sel.map { $0.map { $0.sorted() } })")
print("types=" + fomod.steps[0].groups[1].options.map { fomod.type(of: $0, flags: [:], plugin: noDLC).rawValue + "/" + fomod.type(of: $0, flags: [:], plugin: withDLC).rawValue }.joined(separator: ","))
print("visible=\(fomod.isVisible(step: 1, sel, plugin: noDLC))")
func show(_ pairs: [(source: String, destination: String)]) -> String { pairs.map { $0.source + ">" + $0.destination }.joined(separator: ";") }
print("dark=" + show(fomod.install(sel, names: names, plugin: noDLC)))
// Vanilla: the dark step hides, its choice no longer counts.
sel = fomod.toggle(sel, step: 1, group: 0, option: 0, flags: fomod.flags(sel, plugin: noDLC), plugin: noDLC)
sel = fomod.toggle(sel, step: 0, group: 0, option: 1, flags: fomod.flags(sel, plugin: noDLC), plugin: noDLC)
print("hidden=\(fomod.isVisible(step: 1, sel, plugin: noDLC))")
sel = fomod.toggle(sel, step: 0, group: 1, option: 1, flags: [:], plugin: noDLC)   // DLC patch: not usable, refused
sel = fomod.toggle(sel, step: 0, group: 1, option: 0, flags: [:], plugin: noDLC)   // Zeta on
print("vanilla=" + show(fomod.install(sel, names: names, plugin: noDLC)))
let one = fomod.toggle(sel, step: 0, group: 0, option: 1, flags: [:], plugin: noDLC)
print("exactly=\(one[0][0].sorted())")
print("root=" + [Fomod.root(in: ["My Mod/Fomod/moduleconfig.XML", "My Mod/a.esp"]).map { $0.root + "|" + $0.config } ?? "nil",
                 Fomod.root(in: ["a.esp"]).map { $0.root } ?? "nil"].joined(separator: ","))
print("bad=\((try? Fomod(xml: Data("<nope".utf8))) == nil ? "refused" : "taken")")

// plugins.txt and Fallout.ini
let nv = BethesdaPlugins.game(topNames: ["FalloutNV.exe", "Data"])!
let sse = BethesdaPlugins.game(topNames: ["SkyrimSE.exe"])!
print("games=\(nv.folder)|\(nv.starred)|\(nv.looseFilesIni ?? "nil")|\(sse.folder)|\(sse.starred)|\(BethesdaPlugins.game(topNames: ["game.exe"]) == nil)")
let fresh = BethesdaPlugins.activate(["LO.esp", "LO - Core.esm"], in: nil, starred: false, masters: ["FalloutNV.esm", "DeadMoney.esm"])
print("fresh=" + fresh.replacingOccurrences(of: "\r\n", with: "/"))
let existing = "# This file is used by Fallout\r\nFalloutNV.esm\r\nCaravanPack.esm\r\nOther.esp\r\n"
let added = BethesdaPlugins.activate(["New.esm", "lo.esp", "other.esp"], in: existing, starred: false, masters: [])
print("added=" + added.replacingOccurrences(of: "\r\n", with: "/"))
print("starred=" + BethesdaPlugins.activate(["Mod.esp", "Off.esp"], in: "*Skyrim.esm\nOff.esp\n", starred: true, masters: []).replacingOccurrences(of: "\r\n", with: "/"))
print("removed=" + BethesdaPlugins.deactivate(["lo.esp", "New.esm"], in: added).replacingOccurrences(of: "\r\n", with: "/"))
let ini = "[General]\r\nsStartingCell=\r\n[Archive]\r\nbInvalidateOlderFiles=0\r\nSArchiveList=Fallout - Textures.bsa\r\n\r\n[Display]\r\niSize W=1280\r\n"
var set = BethesdaPlugins.setIni(ini, section: "Archive", key: "bInvalidateOlderFiles", value: "1")
set = BethesdaPlugins.setIni(set, section: "Archive", key: "SInvalidationFile", value: "")
print("ini=" + set.replacingOccurrences(of: "\r\n", with: "/"))
print("newini=" + BethesdaPlugins.setIni("[General]\n", section: "Archive", key: "bInvalidateOlderFiles", value: "1").replacingOccurrences(of: "\r\n", with: "/"))
'''

compiler = os.environ.get('SWIFTC') or shutil.which('swiftc')
if not compiler:
    print('SKIP: Swift compiler unavailable locally; macOS CI must run this check with --require-swift')
    if args.require_swift:
        failures += 1
else:
    with tempfile.TemporaryDirectory(prefix='madeira-fomod-', dir=os.environ.get('TMPDIR')) as directory:
        temporary = Path(directory)
        (temporary / 'ModFomod.swift').write_text(source)
        (temporary / 'main.swift').write_text(main_swift)
        # UTF-16 with a BOM while the declaration says utf-8, as some mods ship it.
        (temporary / 'ModuleConfig.xml').write_bytes(config.encode('utf-16'))
        (temporary / 'names.txt').write_text('\n'.join(names))
        binary = temporary / 'fomod'
        subprocess.run(compiler.split() + ['-swift-version', '5', str(temporary / 'ModFomod.swift'), str(temporary / 'main.swift'),
                                           '-o', str(binary)], check=True)
        out = dict(line.split('=', 1) for line in subprocess.run([str(binary), str(temporary)], capture_output=True, text=True,
                                                                 check=True).stdout.splitlines())
        check(out['name'] == 'Lighting Overhaul NV|2|Interiors,Extras', 'a UTF-16 ModuleConfig.xml with a wrong declaration reads')
        check(out['order'] == 'DLC patch,Zeta lights', '"Ascending" options are sorted by name, "Explicit" ones kept in order')
        check(out['desc'] == 'Darker interiors & caves.|fomod/images/dark.png', 'descriptions (CDATA) and pictures are read')
        check(out['default'] == '[[[0], []], [[]]]', 'the installer starts with the recommended option')
        check(out['types'] == 'NotUsable/Recommended,Optional/Optional', 'an option can depend on a plugin being active (Dead Money)')
        check(out['visible'] == 'true' and out['hidden'] == 'false', 'a step shows only when an earlier choice set its flag')
        check(out['dark'] == '00 Core/LO - Core.esm>LO - Core.esm;00 Core/meshes/lights/a.nif>meshes/lights/a.nif;'
                             'docs/readme.txt>Docs/LO readme.txt;01 Dark/LO - Dark.esp>LO.esp;06 Patch/dark patch.esp>LO dark patch.esp',
              'required folders and files, the chosen option, and conditional files land where the installer says')
        check(out['vanilla'] == '00 Core/LO - Core.esm>LO - Core.esm;00 Core/meshes/lights/a.nif>meshes/lights/a.nif;'
                                'docs/readme.txt>Docs/LO readme.txt;02 Vanilla/LO - Vanilla.esp>LO.esp;'
                                '03 Zeta/sub/z2.nif>meshes/zeta/sub/z2.nif;03 Zeta/z1.nif>meshes/zeta/z1.nif',
              'another choice swaps the file; a hidden step and a not-usable option add nothing; folders keep their tree')
        check(out['exactly'] == '[1]', '"Select exactly one" keeps one choice')
        check(out['root'] == 'My Mod|My Mod/Fomod/moduleconfig.XML,nil', 'the installer is found in any folder, any case')
        check(out['bad'] == 'refused', 'a broken ModuleConfig.xml is refused')
        check(out['games'] == 'FalloutNV|false|Fallout.ini|Skyrim Special Edition|true|true', 'Bethesda games are told apart')
        check(out['fresh'] == 'FalloutNV.esm/DeadMoney.esm/LO - Core.esm/LO.esp/', 'a new plugins.txt lists the masters, then the mod')
        check(out['added'] == '# This file is used by Fallout/FalloutNV.esm/CaravanPack.esm/New.esm/Other.esp/lo.esp/',
              'plugins are added once; a new master goes after the last master')
        check(out['starred'] == '*Skyrim.esm/*Off.esp/*Mod.esp/', 'Skyrim SE / Fallout 4 lists mark active plugins with *')
        check(out['removed'] == '# This file is used by Fallout/FalloutNV.esm/CaravanPack.esm/Other.esp/', 'Remove takes its plugins out')
        check(out['ini'] == '[General]/sStartingCell=/[Archive]/bInvalidateOlderFiles=1/SArchiveList=Fallout - Textures.bsa/'
                            'SInvalidationFile=//[Display]/iSize W=1280/', 'Fallout.ini gets loose files turned on, other keys kept')
        check(out['newini'] == '[General]/[Archive]/bInvalidateOlderFiles=1/', 'a missing [Archive] section is added')

print('FAIL' if failures else 'PASS')
sys.exit(1 if failures else 0)
