// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Madeira contributors
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
// Host test for GOGInstallScript (tests/host/check-gog-install-script.py). Synthetic data.
import Foundation

var failures = 0
func check(_ ok: Bool, _ label: String) { print((ok ? "PASS: " : "FAIL: ") + label); if !ok { failures += 1 } }

// The shape of The Witcher: Enhanced Edition's script (values as GOG's installer writes them).
let witcher = """
\u{FEFF}{ "productId": "1207658924", "actions": [
 { "name": "setRegistry", "install": { "action": "setRegistry", "arguments": {
   "root": "HKEY_LOCAL_MACHINE", "subkey": "Software/CD Projekt Red/The Witcher", "valueName": "InstallFolder", "valueData": "{app}", "valueType": "string" } } },
 { "name": "setRegistry", "install": { "action": "setRegistry", "arguments": {
   "root": "HKEY_LOCAL_MACHINE", "subkey": "Software\\\\CD Projekt Red\\\\The Witcher", "valueName": "IsDjinniInstalled", "valueData": 1, "valueType": "dword" } } },
 { "name": "setRegistry", "languages": ["en-US"], "install": { "action": "setRegistry", "arguments": {
   "root": "HKLM", "subkey": "Software\\\\CD Projekt Red\\\\The Witcher", "valueName": "Language", "valueData": "3", "valueType": "string" } } },
 { "name": "setRegistry", "languages": ["de-DE"], "install": { "action": "setRegistry", "arguments": {
   "root": "HKLM", "subkey": "Software\\\\CD Projekt Red\\\\The Witcher", "valueName": "Language", "valueData": "1", "valueType": "string" } } },
 { "name": "setRegistry", "install": { "action": "setRegistry", "arguments": {
   "root": "HKEY_CURRENT_USER", "subkey": "Software\\\\CD Projekt Red\\\\The Witcher", "valueName": "Exe", "valueData": "{app}/System/witcher.exe", "valueType": "string" } } },
 { "name": "setRegistry", "osBitness": ["32"], "install": { "action": "setRegistry", "arguments": {
   "root": "HKLM", "subkey": "Software\\\\Only32", "valueName": "x", "valueData": "1", "valueType": "string" } } },
 { "name": "setRegistry", "install": { "action": "setRegistry", "arguments": {
   "root": "HKLM", "subkey": "Software\\\\GOG.com\\\\Games\\\\1207658924", "saveGameData": true } } },
 { "name": "setRegistry", "install": { "action": "setRegistry", "arguments": {
   "root": "HKLM", "subkey": "Software\\\\X", "valueName": "Docs", "valueData": "{userdocs}/Witcher", "valueType": "string" } } },
 { "name": "savePath", "install": { "action": "savePath", "arguments": { "type": "folder" } } },
 { "name": "setRegistry", "install": { "action": "setRegistry", "arguments": {
   "root": "HKEY_CLASSES_ROOT", "subkey": "x", "valueName": "y", "valueData": "z" } } }
]}
"""
let folder = "C:\\GOG Games\\The Witcher Enhanced Edition"
guard let script = GOGInstallScript.parse(Data(witcher.utf8)) else { print("FAIL: parse"); exit(1) }
check(script.productID == "1207658924" && script.actions.count == 10, "parse: product and actions (BOM skipped)")
let plan = script.plan(folder: folder, language: "en-US")
func value(_ name: String) -> GOGInstallScript.Value? { plan.values.first { $0.name == name } }
check(value("InstallFolder") == .init(root: .machine, key: "Software\\CD Projekt Red\\The Witcher", name: "InstallFolder",
                                     data: .string(folder), followsInstall: true), "InstallFolder: {app}, / subkey as \\, follows the folder")
check(value("IsDjinniInstalled")?.data == .dword(1) && value("IsDjinniInstalled")?.followsInstall == false, "dword from a JSON number")
check(value("Language")?.data == .string("3"), "language filter: en-US action kept, de-DE left out")
check(value("Exe") == .init(root: .user, key: "Software\\CD Projekt Red\\The Witcher", name: "Exe",
                            data: .string(folder + "\\System\\witcher.exe"), followsInstall: true), "HKCU, {app}/ path as \\")
check(value("x") == nil, "osBitness 32-only action left out on 64-bit Windows")
check(value("Docs") == nil && plan.notes.contains { $0.contains("unknown placeholder") }, "unknown placeholder left out and noted")
check(plan.notes.contains { $0.contains("savePath left out") }, "savePath noted")
check(plan.notes.contains { $0.contains("HKEY_CLASSES_ROOT") }, "other root noted")
check(plan.values.count == 4, "four values written")
let german = script.plan(folder: folder, language: "de-DE")
check(german.values.first { $0.name == "Language" }?.data == .string("1"), "de-DE install gets its own Language")
check(GOGInstallScript.language("en", matches: "en-US") && GOGInstallScript.language("*", matches: "fr-FR")
      && !GOGInstallScript.language("en-GB", matches: "en-US"), "language matching")
check(GOGInstallScript.isScriptName("goggame-1207658924.script") && GOGInstallScript.isScriptName("GOGGAME-1.SCRIPT")
      && !GOGInstallScript.isScriptName("goggame-1207658924.info") && !GOGInstallScript.isScriptName("goggame-.script")
      && !GOGInstallScript.isScriptName("goggame-12a.script"), "script names")
check(GOGInstallScript.parse(Data("{\"playTasks\": []}".utf8)) == nil && GOGInstallScript.parse(Data("x".utf8)) == nil, "not a script")

let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("gog-script-\(getpid())")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
for name in ["goggame-2.script", "goggame-1.script", "goggame-1.info", "readme.script"] {
    FileManager.default.createFile(atPath: tmp.appendingPathComponent(name).path, contents: Data())
}
check(GOGInstallScript.scripts(in: tmp).map(\.lastPathComponent) == ["goggame-1.script", "goggame-2.script"], "scripts at the folder root, sorted")
try? FileManager.default.removeItem(at: tmp)

print(failures == 0 ? "ALL OK" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
