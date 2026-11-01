#!/usr/bin/env python3
"""Game details › Launch arguments: Battle.net's launcher gets one chip per Blizzard
game that sets a single --exec="launch <code>" switch (production Swift helpers)."""
from pathlib import Path
import re
import subprocess
import tempfile
root = Path(__file__).resolve().parents[2]
swift = (root / 'app/Madeira/Library.swift').read_text()
start = swift.index('struct LaunchFlagChips: View {')
end = swift.index('    var body: some View {', start)
chips = swift[start:end].replace('struct LaunchFlagChips: View {', 'enum LaunchFlagChips {', 1)
chips = chips.replace('@Binding var arguments: String', '').replace('var program: String = ""', '') + '}\n'
launcher = (root / 'app/Madeira/LauncherGames.swift').read_text()
codes = re.search(r'static let blizzardCodes: \[String: String\] = \[.*?\n    \]', launcher, re.S).group(0)
assert 'LaunchFlagChips(arguments: $entry.arguments, program: entry.relativePath)' in swift
test = r'''
precondition(LaunchFlagChips.isBattleNet("Program Files (x86)/Battle.net/Battle.net Launcher.exe"))
precondition(LaunchFlagChips.isBattleNet("Program Files (x86)/Battle.net/Battle.net.exe"))
precondition(!LaunchFlagChips.isBattleNet("Program Files (x86)/StarCraft/StarCraft.exe"))
precondition(LaunchFlagChips.blizzardChips.count == 11)
let s1 = LaunchFlagChips.blizzardChips.first { $0.name == "StarCraft" }!.flag
let d4 = LaunchFlagChips.blizzardChips.first { $0.name == "Diablo IV" }!.flag
precondition(s1 == "--exec=\"launch S1\"")
precondition(d4 == "--exec=\"launch Fen\"")
var a = LaunchFlagChips.blizzardToggled("", s1)
precondition(a == s1)
precondition(LaunchFlagChips.contains(a, s1))
a = LaunchFlagChips.blizzardToggled("-x " + a, d4)   // one game at a time, other args kept
precondition(a == "-x --exec=\"launch Fen\"")
a = LaunchFlagChips.blizzardToggled(a, d4)            // tap again: off
precondition(a == "-x")
print("ok")
'''
with tempfile.TemporaryDirectory(prefix='madeira-bnet-chips-') as folder:
    folder = Path(folder)
    src = 'import Foundation\nenum LauncherID {\n    ' + codes + '\n}\n' + chips + test
    (folder / 'main.swift').write_text(src)
    subprocess.run(['swiftc', str(folder / 'main.swift'), '-o', str(folder / 'a')], check=True)
    subprocess.run([str(folder / 'a')], check=True)
print('PASS Battle.net launch-code chips')
