# Publishers' launchers

Some publishers' games only start with the publisher's own launcher running:
Ubisoft Connect, Battle.net and the Rockstar Games Launcher. None of them has an
open client Madeira could speak for, as it does for Steam, Epic and GOG, so
Madeira runs the real launcher in the Wine desktop
(`app/Madeira/LauncherSupport.swift`).

## Settings › PC game launchers

- **Download installer** fetches the publisher's installer from its own HTTPS
  address into `drive_c\Madeira Downloads` and adds it to the library as
  "Install <launcher>". Nothing is downloaded until you tap it.
- Play that entry and finish the installer in the Wine desktop.
- **Add to library** then adds the installed launcher. Sign in in the
  launcher's own window; Madeira never sees the password.
- **Repair** (Ubisoft Connect) runs the Ubisoft repairs below by hand.

An installer you downloaded yourself works the same way: add it to the library
as any program. Madeira recognises it by its file name.

## Recommended settings

`GameRecommendations.swift` recognises each launcher by its program in its own
folder, and each installer by the name it downloads with:

| Program | List |
|---|---|
| `Ubisoft Game Launcher\UbisoftConnect.exe`, `upc.exe`, `Uplay.exe` | `ubisoft-connect` (v5) |
| `UbisoftConnectInstaller.exe` | `ubisoft-connect-setup` |
| `Battle.net\Battle.net Launcher.exe`, `Battle.net.exe` | `battle-net` (v3) |
| `Battle.net-Setup.exe` | `battle-net-setup` |
| `Rockstar Games\Launcher\Launcher.exe` | `rockstar-launcher` (125hz) |
| `Rockstar-Games-Launcher.exe` | `rockstar-launcher-setup` (125hz) |
| `boot\ffxivboot.exe` | `ffxiv-launcher` (v2) |
| `ffxivsetup.exe` | `ffxiv-setup` (v2) |

Every one of them starts in the Wine desktop with Windows services first (the
lists' `launchMode` and `startServices`): the launchers install services and use
out-of-process COM. Rockstar's launcher is 64-bit Chromium (CEF), so its list takes the lines Social Club and Steam's web helper need: Social Club layout 2
(`env.MADEIRA_SC_PA_POOLS = 2`, room for Chromium 128+'s three 32 GB
reservations), the JIT pool lines for libcef.dll, pure-x64 images uncopied, and
the swap file for the web helper's idle pages. No list has a release delay (`MADEIRA_FREE_DELAY_MS`): Chromium's allocator
reserves, releases and reserves again. The installers get the standard line
only.

Ubisoft Connect and Battle.net are 32-bit: UbisoftConnect.exe, upc.exe and
UplayWebCore.exe, and Battle.net Launcher.exe, Battle.net.exe and Agent.exe, each
need a 4 GB window, so their lists (version 2) have none of the 64-bit Chromium
lines. With them, build 48's upc.exe and Battle.net.exe found no window and the
clients never opened. The extra windows spill into the range the 64-bit Chromium
layout would take.

When a program raises a Windows error box (NtRaiseHardError), Wine never shows
it; wine patch 0016 logs its text as `[hard-error]` lines. On build 48, upc.exe
raised one (status 50000018) and closed with 0xdeadc0de; build 58's log
gave its text, `Error at hooking API "LdrFindResource_U"`. upc.exe hooks ntdll by
writing into its own code, and Madeira's wineserver denies a write into a
pseudo-process unless its program is a `local-write-target`, so Ubisoft Connect's
list version 3 names upc.exe, UbisoftConnect.exe and UplayWebCore.exe.

Battle.net's list also turns off Windows' location service
(`env.WINEDLLOVERRIDES = locationapi=d`), which the client stops on under Wine.

Battle.net's version 2 list works on build 58 (Cameron, 2026-10-31; slow, its window is 32-bit Chromium). Ubisoft Connect's version 3 is not device-tested yet.

Fewer Chromium helpers (Ubisoft v4, Battle.net v3). The band holds eight 4 GB windows,
and both clients start more 32-bit Chromium helpers than that: on build 58 their
renderers failed with `BOOT FAILED at stage 'guest-window-reserve'`. Ubisoft's
picture then only redrew on a minimize and the client quit. Battle.net's main page
renderer crashed in libcef.dll during a StarCraft install and its replacement could not
start, which left a blank window while Agent.exe went on. Chromium reads switches from
the browser process's own command line (upc.exe, Battle.net.exe), so the lists pass
`--renderer-process-limit=1 --in-process-gpu` through `env.MADEIRA_CHILD_ARGS`, which
removes the GPU process and the extra renderers. Battle.net's own "Use browser hardware
acceleration" switch (Settings > App) off is the usual Wine advice too (Wine bug 50637).
Device logs (2026-10-31): Battle.net.exe took the switches (no GPU process, no failed
helpers, faster load). upc.exe still started a GPU process, so Ubisoft's CEF setup seems
to ignore them. Both clients then hit `[x18-emul3] UNRECOGNIZED insn=b9980e5c`
(wow64.dll's `ldrsw` of WowTebOffset with x18 = 0), which the x18 emulation now handles.

Ubisoft list version 5 (log 16:20Z): past the crash, upc.exe ran two UplayService.exe
copies, Chromium's GPU, network and storage helpers and asked for six renderers. The ninth
32-bit program found the guest-window registry (eight entries) full, and the client said
"Ubisoft services are temporarily unavailable". Chromium's browser keeps at most
physical MB / 2 / 60 renderers (at least 3), so the list tells upc.exe alone 479 MB
(`exe-phys-mb = upc.exe:479`, virtual_ios.c `ios_exe_phys_bytes`; the renderers keep the
real figure for V8's heap), and the registry now holds ten windows (the band and its spill
range have at most ten 4 GB-aligned candidates). The switches line is dropped.

## Library sections

Each launcher has its own library section, like Steam's and GOG's
(`app/Madeira/LauncherGames.swift`), shown once the launcher is installed or added:

- the launcher and the games you added from its folders (they leave Other games);
- an **Add** card when the launcher is installed but not in the library yet;
- the games it installed that are not in the library yet, each with **Add**:
  Ubisoft's `games` folder, Rockstar's game folders, Blizzard's game folders,
  Final Fantasy XIV's game. Add picks the folder's one program (helpers aside), or
  the one named like the folder; otherwise it asks for + instead.

Final Fantasy XIV's launcher is in the same section, for installing and updating the
game only: its window is Internet Explorer's engine, so its lists are the standard
line in the Wine desktop with services first (its InstallShield installer stayed
black when started directly on build 48). The game signs in through Madeira (docs/FFXIV.md).

## Ubisoft repairs

Older Ubisoft games (Assassin's Creed and others) look for `Uplay.exe`, the
client's install folder in the registry (often from a 32-bit game), or start the
client through `uplay://`. Before every library start and every Madeira Dock
start, while no session runs, Madeira:

- makes `Uplay.exe` and `upc.exe` links beside the client when missing (a real
  file of that name stays; a link a client update left dangling is made again);
- writes `HKLM\Software\Ubisoft\Launcher` `InstallDir` in both registry views;
- registers `uplay://` and `ubisoft-connect://` in the user's classes.

Nothing happens without Ubisoft Connect installed, and nothing twice. The
registry goes through `SteamInstallRegistry` (a `.madeira-bak` copy is kept
before the first change). A Ubisoft game bought on Steam still needs Ubisoft
Connect installed and signed in.

Based on SaimSuhailQu's launcher support (willfaust/Madeira #260, not merged).
Tests: `tests/host/check-launcher-support.py`,
`tests/host/check-game-recommendations.py`.
