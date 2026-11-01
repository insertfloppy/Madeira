#!/usr/bin/env python3
"""A game added from a folder inside a Steam library starts with its own Steam identity.

Without it, a local library entry for a program under steamapps/common/<game> gets the
bridge's fixed identity (SteamAppId 356400, Thumper's path; WineProcessBridge.m "Steam
game vars"), so a Steam wrapper in the game sees another game's App ID. Checks that:
  - DockGame.containing matches a program inside an install folder, any case and either
    slash, needs the folder's trailing backslash (no "Game2" match for "Game"), and picks
    the deepest folder;
  - configureLaunch publishes it only for a non-Steam, non-Desktop entry, through the same
    MADEIRA_STEAM_APPID / MADEIRA_STEAM_APPPATH pair a direct Steam start uses;
  - the bridge still validates and clears that pair and keeps the fixed fallback.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
failures = []


def check(what, cond):
    print(('ok   ' if cond else 'FAIL ') + what)
    if not cond:
        failures.append(what)


dock = (app / 'MadeiraDock.swift').read_text(encoding='utf-8')
at = dock.index('static func containing(windowsProgram program: String, in games: [DockGame]) -> DockGame? {')
body = dock[at:dock.index('\n    }\n', at)]
check('containing lowercases the program and turns / into \\',
      'program.replacingOccurrences(of: "/", with: "\\\\").lowercased()' in body)
check('containing needs the install folder plus a backslash as a prefix',
      'path.hasPrefix($0.windowsInstallPath.lowercased() + "\\\\")' in body)
check('containing picks the deepest install folder',
      '.max { $0.windowsInstallPath.count < $1.windowsInstallPath.count }' in body)

library = (app / 'Library.swift').read_text(encoding='utf-8')
at = library.index('func configureLaunch() {')
launch = library[at:library.index('\n    }\n', at)]
check('configureLaunch clears the pair first', 'unsetenv("MADEIRA_STEAM_APPID"); unsetenv("MADEIRA_STEAM_APPPATH")' in launch)
local = launch.index('} else if steamAppID == nil, desktop != true,')
check('a local entry is matched against the installed Steam games',
      'DockGame.containing(windowsProgram: launchWindowsPath, in: MadeiraDock.games(drive: MadeiraDock.drive))' in launch[local:local + 300])
check('a local entry publishes the game\'s App ID and install folder',
      'setenv("MADEIRA_STEAM_APPID", String(game.id), 1)' in launch[local:local + 600]
      and 'setenv("MADEIRA_STEAM_APPPATH", game.windowsInstallPath, 1)' in launch[local:local + 600])
check('the local branch follows the direct Steam start branch',
      launch.index('if startsSteamGameDirectly, let steamAppID {') < local)

bridge = (app / 'WineProcessBridge.m').read_text(encoding='utf-8')
at = bridge.index('const char *direct_app = getenv("MADEIRA_STEAM_APPID");')
seg = bridge[at:at + 2500]
check('the bridge checks the App ID is digits and the path is on C:',
      'strspn(direct_app, "0123456789") == strlen(direct_app)' in seg and "direct_path[2] == '\\\\'" in seg)
check('the bridge keeps the fixed fallback', 'setenv("SteamGameId", "356400", 1);' in seg)
check('the bridge clears the pair', 'unsetenv("MADEIRA_STEAM_APPID");' in seg and 'unsetenv("MADEIRA_STEAM_APPPATH");' in seg)

if failures:
    raise SystemExit(f'{len(failures)} check(s) failed')
print('all checks passed')
