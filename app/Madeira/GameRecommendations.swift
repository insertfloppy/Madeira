//
//  GameRecommendations.swift
//  Madeira
//
//  madeira-bcd: the settings Madeira recommends for the games it has been
//  tested with, shipped in the app (owner's decision, 2026-10-09).
//
//  A recommendation is the game's own config file (GameProfiles.swift,
//  madeira.cfg syntax) plus the switches the game's settings page keeps
//  elsewhere: AVX, Report an NVIDIA GPU, Wine's C++ runtime, the fastsync
//  switches, the FPS limit, the resolution and the scaling. A game that
//  arrives with no config of its own gets its recommendation once (a Steam
//  install, a game added by hand, a game already in the library);
//  "Reset to Recommended" at the bottom of its settings brings it back at
//  any time (GameRecommendationsApply.swift).
//
//  How a game is recognised:
//    - A library Steam game by its App ID or by its folder under
//      steamapps\common, which Steam keeps the same from build to build.
//    - A program by its file name, wherever it was installed; only the
//      game's own programs count, not a redistributable in its folder.
//    - GTA V Enhanced by PlayGTAV.exe (or GTA5_Enhanced.exe) beside
//      GTA5_Enhanced.exe: inside a Steam library it is the Steam copy,
//      anywhere else a copy from outside Steam (Rockstar Games Launcher or
//      another store), and each has its own list. Red Dead Redemption 2's
//      RDR2.exe and PlayRDR2.exe the same way.
//    - The publishers' launchers (LauncherSupport.swift): Ubisoft Connect's
//      UbisoftConnect.exe or upc.exe in an "Ubisoft Game Launcher" folder,
//      "Battle.net Launcher.exe" or Battle.net.exe in a "Battle.net" folder,
//      Launcher.exe in a "Rockstar Games\Launcher" folder, and their
//      installers by the names they download with, wherever they are.
//    - Any other game, and the Desktop, gets the standard list (owner's
//      decisions, 2026-10-12; GameRecommendationsApply.swift).
//
//  This file is Foundation only: tests/host/check-game-recommendations.py
//  compiles it with a test harness. The lists are the working ones recorded
//  in the private notes (OYUN-AYARLARI); a game that gets a newer working
//  list gets it here too, with a higher `version` (with every build, owner's
//  order 2026-10-09).
//

import Foundation

/// The recommended setup of one game. A switch left nil is not touched.
struct GameRecommendation: Equatable {
    /// Stable identity ("rdr2-steam"); the record of what was applied keys on it.
    let id: String
    /// Shown under "Reset to Recommended".
    let title: String
    /// Raised whenever `config` or a switch changes.
    let version: Int
    /// The game's own config file, madeira.cfg syntax.
    let config: String
    var avx: Bool? = nil
    var nvidia: Bool? = nil
    /// Game details › Older NVIDIA card (Direct3D 9) (LibraryBCD.swift, D3D9Identity).
    var olderNvidia: Bool? = nil
    var wineVCRT: Bool? = nil
    /// Game details › Fast synchronization (LibraryEntry.fastSync).
    var fastSync: Bool? = nil
    /// Game details › Fast semaphore waits (LibraryEntry.semaphoreFastPath).
    var semaphoreFastPath: Bool? = nil
    /// LibraryEntry.fpsMode: 1 = 60, 3 = 30, 4 = 40, 0 = display maximum, 2 = uncapped.
    var fpsMode: Int? = nil
    /// "WxH", or `GameRecommendation.screen720`. nil keeps the device's own
    /// default, which is what the lists recorded as 1408x648 were on a 19.5:9 iPhone.
    var resolution: String? = nil
    /// `resolution`: this screen's shape at 720 lines (ResolutionChoices.screen720,
    /// 1568x720 on a 19.5:9 iPhone), for games that offer full screen only at 720
    /// lines or more. A screen whose default already has them keeps its default.
    static let screen720 = "screen@720"
    /// Aspect & scaling (DisplayMode raw value); "fit" is the default.
    var display: String? = nil
    /// Game details › Launch › Start (LibraryEntry.launchMode): "desktop", the Wine desktop.
    var launchMode: String? = nil
    /// Game details › Launch › Start Windows services first (LibraryEntry.startServices).
    var startServices: Bool? = nil

    /// The config file's text as GameProfile stores it (one trailing newline).
    var fileText: String { config.hasSuffix("\n") ? config : config + "\n" }

    /// A short list of the switches it sets, for Game details.
    var switchSummary: String {
        var parts: [String] = []
        if let avx { parts.append("AVX \(avx ? "on" : "off")") }
        if let nvidia { parts.append("NVIDIA \(nvidia ? "on" : "off")") }
        if let olderNvidia { parts.append("older NVIDIA card \(olderNvidia ? "on" : "off")") }
        if let wineVCRT { parts.append("Wine's C++ runtime \(wineVCRT ? "on" : "off")") }
        if fastSync == false { parts.append("fast synchronization off") }
        if let semaphoreFastPath { parts.append("fast semaphore waits \(semaphoreFastPath ? "on" : "off")") }
        if let fpsMode {
            let label = [1: "60", 3: "30", 4: "40", 0: "display maximum", 2: "uncapped"][fpsMode] ?? "\(fpsMode)"
            parts.append("FPS limit \(label)")
        }
        if let resolution { parts.append(resolution == Self.screen720 ? "this screen's shape at 720 lines" : resolution) }
        if launchMode == "desktop" { parts.append("starts in the Wine desktop") }
        if startServices == true { parts.append("Windows services first") }
        return parts.joined(separator: ", ")
    }
}

enum GameRecommendations {
    // MARK: The lists

    /// Red Dead Redemption 2 from Steam, through Madeira Dock: the build 463
    /// list, plus build 466's memory and ExecuteIndirect switches, the DXGI
    /// monitor identity and mode list for Borderless / Full Screen (which no
    /// longer crash, 2026-10-09 11:34), build 467's full-screen window and
    /// 720-line screen, the least RDR2 offers in full screen (which fits the
    /// screen, 13:09), build 470's test: the swap file also takes the 1-4 MB
    /// blocks (the game still reached the 8 GB limit a minute into play), and
    /// build 472's pool-mid: a mapping between the pool's two regions at image
    /// load cut the pool to 604 MB and the game stopped with ERR_GFX_INIT (14:33);
    /// and ring-share: on build 470 (14:48) the argument-buffer chunks grew to
    /// 1.5 GB of the 3.6 GB Metal held in play; and build 476's test: the x64
    /// program files (libcef.dll 228 MB, steamclient64.dll, the launcher, the
    /// game) move to the swap file once read, the launcher's and Social Club's
    /// DXMT upload rings take 4 MB blocks instead of 32 MB (they held 200 MB
    /// through play on 467), and the ExecuteIndirect probe is off (on 470 it
    /// split render passes every 3 s per pipeline for the first two minutes);
    /// and build 480's: on 476 the game loaded xinput1_4.dll only at its first
    /// controller read, when the launcher's, Social Club's and the game's
    /// 128 MB code buffers had left the JIT pool no room for it, so neither the
    /// controller nor the on-screen controls reached the game; the DLL is now
    /// loaded with the D3D12 device. Build 479 also kept 192 MB of the pool for
    /// DLLs: the game's code buffer then got 16 MB and was refilled again and
    /// again (2-3 FPS, 19:35), so the pool is back to 128 MB. The orphan-lock
    /// reaper releases only locks a live thread has stamped (it released live
    /// locks: three "is not owned" errors on 476). Version 10 (build 514,
    /// 2026-10-12): the first install's VC++ setup may not start its elevated
    /// engine (.be\vc_redist), which crashed with a lock held while the setup
    /// waited for it forever (12:43). With the line the setup fails at once and
    /// the installs pass (12:57); the session links its own VC++ DLLs anyway.
    static let rdr2Steam = GameRecommendation(
        id: "rdr2-steam", title: "Red Dead Redemption 2 (Steam)", version: 10,
        config: """
        # Madeira's recommended settings for Red Dead Redemption 2 (Steam).
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        d3d12-caps-log = 2
        d3d12-shader-pack = 1
        replay-split = 1
        ring-share = 1
        pool-low = 1
        pool-mid = 1
        pool-page-fit = 1
        pool-split = 1
        vram-mb = 2304
        swap-mb = 8192
        swap-mode = 2
        swap-min-mb = 1
        swap-images = 1
        pso-warm = 2
        fence-chain = 6
        avail-phys = 1
        indirect-fast = 1
        ind-probe = 0
        fullscreen-window = 1
        env.WINE_D3D_CONFIG = renderer=no3d
        env.FEX_VECTORTSOENABLED = 0
        env.MADEIRA_BAND_CENSUS = 1
        env.MADEIRA_RDR2_VA_HOLD = 1
        env.MADEIRA_SWAP_RESERVE_MAX_MB = 9216
        env.MADEIRA_THREAD_STACK_SPILL = 1
        env.MADEIRA_SMALL_STACK_EXES = RDR2.exe
        env.MADEIRA_DOCK_GAME_SCM = 1
        env.MADEIRA_DOCK_KEEP_ALIVE = Launcher.exe;RDR2.exe
        env.MADEIRA_DXGI_BUDGET_EVENTS = 1
        env.DXMT_WSI_MONITOR_IDENTITY = 1
        env.DXMT_WSI_MODE_TABLE = 1
        env.DXMT_SMALL_RINGS = Launcher.exe;SocialClubHelper.exe
        env.MADEIRA_EXECREQ_LEAVE = 1
        env.MADEIRA_LOCK_ORPHAN = stamped
        env.MADEIRA_PIN_GRAPHICS_DLLS = 1
        env.MADEIRA_PRELOAD_DLLS = xinput1_4.dll
        env.MADEIRA_POOL_HEAD_RESERVE_MB = 128
        env.MADEIRA_POOL_LOW_IMAGES = 1
        env.MADEIRA_POOL_RECYCLE_IMAGES = 1
        env.MADEIRA_SC_PA_POOLS = 2
        env.MADEIRA_SPAWN_BLOCK = RockstarErrorHandler;.be\\vc_redist
        env.MADEIRA_TOUCH_MOUSE = 1
        env.MADEIRA_WOW_MIN_FREE_GB = 2
        env.MADEIRA_X64_GRAPHICS_ENTRY = 1
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        env.WINEDLLOVERRIDES = video64=
        env.MADEIRA_DEVICE_STATS = 1
        env.MADEIRA_METAL_HUD_MAIN = 1
        # madeira-bcd's defaults, which this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, nvidia: false, wineVCRT: false, fastSync: true, semaphoreFastPath: false,
        resolution: GameRecommendation.screen720, display: "fit")

    /// Red Dead Redemption 2 started from its own RDR2.exe or PlayRDR2.exe outside
    /// a Steam library (Rockstar Games Launcher or another store; owner's request,
    /// 2026-10-12). Derived from the Steam copy's list and not device-tested on
    /// its own: the Steam list, whose lines are the game's own (its 8960 MB
    /// reservation, the JIT pool, the swap file, the controller DLL, the
    /// launcher's and Social Club's rings), without the two only Madeira Dock
    /// reads when Steam starts the game (the service manager and the programs
    /// that keep that session alive), plus the line GTA V Enhanced's list outside
    /// Steam starts with: the [ec-hook] reporter off.
    static let rdr2Other = GameRecommendation(
        id: "rdr2-other", title: "Red Dead Redemption 2 (outside Steam)", version: 1,
        config: """
        # Madeira's recommended settings for Red Dead Redemption 2 outside Steam (Rockstar Games Launcher or another store).
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        d3d12-caps-log = 2
        d3d12-shader-pack = 1
        replay-split = 1
        ring-share = 1
        pool-low = 1
        pool-mid = 1
        pool-page-fit = 1
        pool-split = 1
        vram-mb = 2304
        swap-mb = 8192
        swap-mode = 2
        swap-min-mb = 1
        swap-images = 1
        pso-warm = 2
        fence-chain = 6
        avail-phys = 1
        indirect-fast = 1
        ind-probe = 0
        fullscreen-window = 1
        env.WINE_D3D_CONFIG = renderer=no3d
        env.FEX_VECTORTSOENABLED = 0
        env.MADEIRA_BAND_CENSUS = 1
        env.MADEIRA_RDR2_VA_HOLD = 1
        env.MADEIRA_SWAP_RESERVE_MAX_MB = 9216
        env.MADEIRA_THREAD_STACK_SPILL = 1
        env.MADEIRA_SMALL_STACK_EXES = RDR2.exe
        env.MADEIRA_DXGI_BUDGET_EVENTS = 1
        env.DXMT_WSI_MONITOR_IDENTITY = 1
        env.DXMT_WSI_MODE_TABLE = 1
        env.DXMT_SMALL_RINGS = Launcher.exe;SocialClubHelper.exe
        env.MADEIRA_EXECREQ_LEAVE = 1
        env.MADEIRA_LOCK_ORPHAN = stamped
        env.MADEIRA_PIN_GRAPHICS_DLLS = 1
        env.MADEIRA_PRELOAD_DLLS = xinput1_4.dll
        env.MADEIRA_POOL_HEAD_RESERVE_MB = 128
        env.MADEIRA_POOL_LOW_IMAGES = 1
        env.MADEIRA_POOL_RECYCLE_IMAGES = 1
        env.MADEIRA_SC_PA_POOLS = 2
        env.MADEIRA_SPAWN_BLOCK = RockstarErrorHandler;.be\\vc_redist
        env.MADEIRA_TOUCH_MOUSE = 1
        env.MADEIRA_WOW_MIN_FREE_GB = 2
        env.MADEIRA_X64_GRAPHICS_ENTRY = 1
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        env.WINEDLLOVERRIDES = video64=
        env.MADEIRA_DEVICE_STATS = 1
        env.MADEIRA_METAL_HUD_MAIN = 1
        env.MADEIRA_EC_HOOK_TRACE = 0
        # madeira-bcd's defaults, which this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, nvidia: false, wineVCRT: false, fastSync: true, semaphoreFastPath: false,
        resolution: GameRecommendation.screen720, display: "fit")

    /// GTA V Enhanced from Steam, through Madeira Dock (build 456: 18 minutes
    /// idle and 19 minutes of fast driving without a crash, 33-40 FPS at 40).
    /// Version 2 (2026-10-12): the orphan-lock reaper releases only locks a live
    /// thread has stamped, as for RDR2 and Horizon Zero Dawn. Its default mode
    /// released a busy lock in SocialClubHelper.exe while the owner lived; the
    /// helper died at Story Mode and the launcher's window stayed grey (log
    /// 10:53, after a reset and a new Rockstar sign-in). Version 3: the first
    /// install's VC++ setup may not start its elevated engine, as for RDR2
    /// (with the line GTA's installs passed, 13:08).
    static let gta5EnhancedSteam = GameRecommendation(
        id: "gta5e-steam", title: "GTA V Enhanced (Steam)", version: 3,
        config: """
        # Madeira's recommended settings for GTA V Enhanced (Steam).
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        d3d12-caps-log = 2
        d3d12-core-dll = 1
        d3d12-msaa8 = 1
        d3d12-tile-based = 0
        d3d12-tiled-resources = 1
        d3d12-typed-uav-load = 1
        pool-low = 1
        pool-page-fit = 1
        pool-split = 1
        vram-mb = 4096
        swap-mb = 3072
        pso-warm = 2
        env.FEX_VECTORTSOENABLED = 0
        env.MADEIRA_CHILD_ARGS = PlayGTAV.exe -nobattleye
        env.MADEIRA_DOCK_GAME_SCM = 1
        env.MADEIRA_DOCK_KEEP_ALIVE = Launcher.exe;GTA5_Enhanced.exe
        env.MADEIRA_EXECREQ_LEAVE = 1
        env.MADEIRA_KMT_ADAPTER = 1
        env.MADEIRA_LOCK_ORPHAN = stamped
        env.MADEIRA_PIN_GRAPHICS_DLLS = 1
        env.MADEIRA_POOL_HEAD_RESERVE_MB = 128
        env.MADEIRA_POOL_LOW_IMAGES = 1
        env.MADEIRA_POOL_RECYCLE_IMAGES = 1
        env.MADEIRA_SC_PA_POOLS = 2
        env.MADEIRA_SPAWN_BLOCK = RockstarErrorHandler;.be\\vc_redist
        env.MADEIRA_TOUCH_MOUSE = 1
        env.MADEIRA_WOW_MIN_FREE_GB = 2
        env.MADEIRA_X64_GRAPHICS_ENTRY = 1
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        env.WINEDLLOVERRIDES = video64=
        env.MADEIRA_DEVICE_STATS = 1
        env.MADEIRA_PAD_MODE = hid
        env.MADEIRA_METAL_HUD_MAIN = 1
        # madeira-bcd's defaults, which this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, nvidia: true, wineVCRT: false, fastSync: true, semaphoreFastPath: true, fpsMode: 4,
        display: "fit")

    /// GTA V Enhanced started from its own PlayGTAV.exe outside a Steam
    /// library (Rockstar Games Launcher or another store; build 451). Version 2:
    /// the same orphan-lock reaper mode as the Steam copy (its launcher and
    /// Social Club too). Version 3 (2026-11-01, an Epic copy on device, from an empty
    /// Rockstar folder to the launcher's own window): it starts in the Wine desktop, where
    /// the launcher installer's service starts on demand (sechost, env.MADEIRA_SCM_ON_DEMAND)
    /// and Epic copies start under EpicGamesLauncher.exe (no services batch: it would bypass
    /// that parent and write the Epic sign-in arguments to disk). The launcher installer's
    /// VC++ redistributable is not started (the 32-bit setup crashed the session). Social
    /// Club's libcef.dll runs without a JIT-pool copy (the Steam list's pool and image lines;
    /// the pool ran out, error 17), its browser draws without the GPU and DXCore is off
    /// (its GPU thread crashed in Wine's DXCore stub, error 17 again).
    static let gta5EnhancedOther = GameRecommendation(
        id: "gta5e-other", title: "GTA V Enhanced (outside Steam)", version: 3,
        config: """
        # Madeira's recommended settings for GTA V Enhanced outside Steam (Rockstar Games Launcher or another store).
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        vram-mb = 4096
        d3d12-core-dll = 1
        d3d12-typed-uav-load = 1
        d3d12-tiled-resources = 1
        d3d12-tile-based = 0
        d3d12-caps-log = 2
        d3d12-msaa8 = 1
        pool-split = 1
        env.MADEIRA_KMT_ADAPTER = 1
        env.MADEIRA_LOCK_ORPHAN = stamped
        env.MADEIRA_PAD_MODE = hid
        env.SteamDeck = 1
        env.MADEIRA_SC_PA_POOLS = 2
        env.MADEIRA_FASTSYNC_SEM = 1
        env.FEX_VECTORTSOENABLED = 0
        env.MADEIRA_DEVICE_STATS = 1
        env.MADEIRA_EC_HOOK_TRACE = 0
        pool-low = 1
        pool-page-fit = 1
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        env.MADEIRA_POOL_LOW_IMAGES = 1
        env.MADEIRA_POOL_RECYCLE_IMAGES = 1
        env.MADEIRA_POOL_HEAD_RESERVE_MB = 128
        env.MADEIRA_EXECREQ_LEAVE = 1
        env.MADEIRA_PIN_GRAPHICS_DLLS = 1
        env.MADEIRA_X64_GRAPHICS_ENTRY = 1
        env.MADEIRA_WOW_MIN_FREE_GB = 2
        env.DXMT_SMALL_RINGS = Launcher.exe;SocialClubHelper.exe
        env.MADEIRA_SPAWN_BLOCK = RockstarErrorHandler;VCRed\\vc_redist;.be\\vc_redist
        env.MADEIRA_SC_CEF_FLAGS = --disable-gpu --disable-gpu-compositing
        env.WINEDLLOVERRIDES = dxcore=;video64=
        # madeira-bcd's defaults, which this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, nvidia: true, wineVCRT: false, fastSync: true, resolution: "1280x720", display: "fit",
        launchMode: "desktop")

    /// Ghost of Tsushima (build 336: DualSense input, rumble, triggers and light work).
    /// Build 492 adds Horizon Zero Dawn's proven fix for typed buffer views that
    /// start off a 16-byte boundary: the GPU reads such a texture from its start
    /// rounded down, so the shader saw data shifted by a few elements in the frames
    /// where a view landed there (HZD: walls, trees and plants missing for one
    /// frame). GoT's one-frame "shapes in the air" are the same kind of fault.
    /// view-census counts such views, so its first run shows whether GoT makes any.
    /// Version 3 (build 515, 2026-10-12, the owner's working list): the [ec-hook]
    /// reporter is off (on 515 it ended the game at start, reading steam_api64.dll's
    /// protected sections), the swap file holds 4 GB, and a new thread's stacks may
    /// take the kernel's pick once Wine's band is full (a thread the game could not
    /// create froze it in a cutscene, 15:39). With the game's own graphics at their
    /// lowest it stays under the memory limit on an iPhone 17 Pro Max.
    static let ghostOfTsushima = GameRecommendation(
        id: "ghost-of-tsushima", title: "Ghost of Tsushima", version: 3,
        config: """
        # Madeira's recommended settings for Ghost of Tsushima.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        dxil-tess = 0
        sampler-reduction = 3
        ind-count = 6000
        typed-view-align = 16
        typed-view-shadow = 1
        view-census = 1
        env.MADEIRA_PAD_MODE = hid
        swap-mb = 4096
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_THREAD_STACK_SPILL = 1
        # madeira-bcd's defaults, which this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: true, nvidia: true, wineVCRT: false, fastSync: true, semaphoreFastPath: false,
        resolution: "1280x720", display: "fit")

    /// God of War (2018) (build 335: 1080p, DualSense input).
    static let godOfWar = GameRecommendation(
        id: "god-of-war", title: "God of War", version: 1,
        config: """
        # Madeira's recommended settings for God of War.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        dxmt = d3d11.mipClampBC=2
        swap-mb = 6144
        swap-min-kb = 1024
        env.WINEDEBUG = err+all,err-virtual,fixme-all
        env.MADEIRA_PAD_MODE = hid
        # madeira-bcd's defaults, which this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, nvidia: false, wineVCRT: false, fastSync: true, semaphoreFastPath: false,
        resolution: "1920x1080", display: "fit")

    /// Horizon Zero Dawn (Complete Edition, GOG or Steam), still being brought
    /// up: the list for build 471's test. Its shaders keep their constant
    /// buffers, samplers and textures in register spaces 6 and 8, which build
    /// 466 refused (the game then crashed); MFC ships with build 468. Build 469
    /// drew the first frame and hung (a pipeline without a pixel shader, fixed
    /// in 471); DXGI now lists the virtual monitor's own modes, as user32 does,
    /// so the game can pick this screen's resolution. Build 471 reached the
    /// language menu at 56 FPS with no input at all: no window was foreground,
    /// so its raw keyboard and mouse input went nowhere, and it reads its pad
    /// only through Windows.Gaming.Input; build 475's two switches cover both.
    /// On build 475 (2026-10-09 16:20) the game played for seven minutes, then
    /// stopped with an "Error" box when its settings menu was refused a
    /// pipeline: the converter refused ~4,900 of its shaders with code 4 (they
    /// read a "t4-unbounded" range), each of them again for every pipeline.
    /// Build 477's switches retry those with sized ranges, remember what stays
    /// refused, and hand the game a placeholder instead of a failure; Wine's
    /// "controller_get_User stub" line (12,747 of them, the game asks every
    /// frame) is silenced. On build 479 (19:44) the retried shaders converted,
    /// but the game stopped with "Error" at start: the orphan-lock reaper had
    /// released two locks whose owners were alive (one on 475 too). Build 480's
    /// line lets it release only locks a live thread has stamped. On build 480
    /// (20:28) the game reached play, and iOS closed it two seconds in at
    /// 8,189 MB: in its menu it had created 52,570 pipelines, and their 23,045
    /// shader libraries stayed in memory although a few thousand are drawn; the
    /// image was corrupted from the first gameplay frame, when the game began to
    /// clear rectangles of its targets and the whole targets were cleared. Build
    /// 481's list lets a pipeline's libraries go until its first draw, clears only
    /// the rectangles, puts the game's memory in the swap file as Red Dead
    /// Redemption 2's list does (broad, from 1 MB), and leaves out pso-warm, whose
    /// queue held 24,570 pipelines (and their libraries) when the game closed.
    /// On build 481 (21:52, 21:55) the game played without closing, but its
    /// characters, which it skins in compute shaders, came out with missing
    /// faces, missing hair or collapsed to spikes every few frames, with
    /// gpu-sync = 1 as without it. Build 483's list adds two diagnostics:
    /// skin-check logs those draws, the dispatches that wrote their vertices and
    /// copies of the vertices themselves; view-census names buffer views that
    /// fall back or are cut short. d3d12-typed-uav-load = 1 changed nothing
    /// (481, 23:19). Build 484's list is one test of every candidate the
    /// research left at once, each its own line: the game reads OPTIONS1, so
    /// d3d12-wave-ops = 0 gives it shaders without wave intrinsics; raw and
    /// structured buffer views also carry a texture view (typed reads of them
    /// read zeros otherwise); R32 typed UAVs get ShaderAtomic; FEX orders vector
    /// and memcpy accesses as x86 does and ignores the volatile metadata of
    /// concrt140.dll and mfc140.dll. If the characters come out whole, the lines
    /// are halved to find the one that matters; skin-check stays on either way.
    /// None of them helped (484, 2026-10-10 07:32), so build 485's list drops
    /// them again. Its skinning dispatches gave the same vertex a different
    /// extreme depending on which of the game's two upload heaps the frame
    /// used, so the list now starts typed buffer views at the 16-byte boundary
    /// Apple's converter documents (a bone palette then has no padding
    /// elements), and skin-check traces whole frames, keeps the vertex shaders
    /// of meshes skinned there, dumps the compute skinning's data and compares
    /// what the GPU read with what the CPU had written. On build 485 (09:35)
    /// the characters came out whole: the dumped skinning matched a recompute
    /// vertex for vertex, and the GPU read exactly the CPU's bytes. Plants and
    /// lighting still flicker, and a small view two compute passes read every
    /// frame started 4 bytes past a 16-byte boundary in some frames, so build
    /// 486's list starts every typed view exactly at its first element where a
    /// probe shows the GPU reads such textures right, and drops the skinning
    /// diagnostics (view-census stays: it counts the views that keep an offset).
    /// On build 486 (11:52) nothing changed: the probe showed the GPU reads such
    /// a texture from its start rounded down to 16 bytes, and whole walls,
    /// trees and plants went missing for one frame every few seconds, at the
    /// moments the depth pyramid the game culls with read back near depths.
    /// Build 487's list gives typed views of upload memory that start off a
    /// 16-byte boundary an aligned copy of their bytes (typed-view-shadow),
    /// holds a queue's wait until the work it waits for is committed
    /// (fence-strict), and logs every frame's draws and the pyramid as the GPU
    /// wrote it (vis-trace). Build 489's list adds desc-guard, which logs the
    /// game rewriting a descriptor that a batch still running on the GPU uses
    /// (another one-frame cause: that draw reads another object's data).
    /// Build 490's list keeps the game's two 32 MB readback buffers, where the
    /// GPU writes the depth pyramid the CPU culls with, on Metal's own memory
    /// instead of the file-backed swap tier (readback-swap = 0); vis-trace now
    /// also compares every pyramid readback with the GPU's own copy. Build
    /// 491's list reads a table's single constant buffers when the draw is
    /// recorded, as NVIDIA's driver and vkd3d-proton do (static-cbv): with
    /// vkd3d-proton, Horizon Zero Dawn Remastered's foliage flicker stops when
    /// that is extended to every such constant buffer. On build 491 the game
    /// rendered without a fault (19:28). Two runs then showed what matters: the
    /// list without fence-strict, static-cbv, readback-swap and the trace
    /// diagnostics stayed clean (19:58), and without typed-view-shadow the
    /// vanishing came back (20:01). That list is version 15. Build 494's list
    /// (version 16) adds two lines for frame rate (493, 2026-10-11): our
    /// runtime's log lines no longer go through OutputDebugString, whose
    /// exception and server request cost ~0.5 ms a line, and the census frames
    /// that froze the game for 1.5-2 s every ~10 s in its first minutes are
    /// off (quiet-log); the server names the shader-cache files it opens with
    /// one call instead of realpath, which kept it busy on a performance core
    /// in the menu (MADEIRA_SRV_FGETPATH).
    static let horizonZeroDawn = GameRecommendation(
        id: "horizon-zero-dawn", title: "Horizon Zero Dawn", version: 16,
        config: """
        # Madeira's recommended settings for Horizon Zero Dawn.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        dxbc-register-spaces = 1
        msc-unbounded-retry = 1
        msc-fail-memo = 1
        pso-placeholder = 1
        pso-lazy-libs = 1
        clear-rects = 1
        typed-view-align = 16
        typed-view-shadow = 1
        view-census = 1
        quiet-log = 1
        swap-mb = 6144
        swap-mode = 2
        swap-min-mb = 1
        env.DXMT_WSI_MONITOR_IDENTITY = 1
        env.DXMT_WSI_MODE_TABLE = 1
        env.MADEIRA_INPUT_FOREGROUND = 1
        env.MADEIRA_WGI_HOST_PADS = 1
        env.MADEIRA_LOCK_ORPHAN = stamped
        env.MADEIRA_SRV_FGETPATH = 1
        env.WINEDEBUG = fixme-input
        # madeira-bcd's defaults, which this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        avx: false, nvidia: false, wineVCRT: false, fastSync: true, display: "fit")

    /// Dark Souls: Remastered (tested on an iPhone Air, iOS 27.2, 2026-10).
    /// The game enumerates XInput only at start and never looks again (no
    /// device-arrival broadcast reaches it here), so player 1 is published from
    /// the first frame, and a player without controls of their own gets the Xbox
    /// layout. Without these the game runs but ignores the touch controller.
    /// The game's Arxan protection needs no dearxan: start-up also needs the image
    /// low-alias for steamclient64 (#385).
    static let darkSoulsRemastered = GameRecommendation(
        id: "dark-souls-remastered", title: "Dark Souls: Remastered", version: 1,
        config: """
        # Madeira's recommended settings for Dark Souls: Remastered.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        # The game looks for a controller only when it starts: player 1 is there from the first frame.
        env.MADEIRA_PAD_EARLY_SLOT = 1
        env.MADEIRA_CONTROLS_XBOX_DEFAULT = 1
        env.MADEIRA_EC_HOOK_TRACE = 0
        """)

    /// Dark Souls III (Steam; tested on an iPhone Air, iOS 27.2, 2026-10). Its JIT
    /// pool used to fill with the game's and Steam's image copies (the exe alone is
    /// 87 MB), so FEX's code buffer reset dozens of times a minute and combat ran at
    /// 3-11 fps: pool-split takes the pool past the main thread's stack (688 MB
    /// instead of 384-544) and MADEIRA_X64_IMAGE_NOCOPY runs the pure-x64 images in
    /// place. The orphan-lock reaper in its default mode released a live
    /// DynamicBuffer lock with three waiters, and two threads then crashed in DXMT;
    /// stamped reaps only locks of threads that are gone, as for Horizon Zero Dawn.
    /// The game looks for a controller only at start, as Dark Souls: Remastered.
    /// With these, combat holds 16-20 fps.
    static let darkSoulsIII = GameRecommendation(
        id: "dark-souls-iii", title: "Dark Souls III", version: 1,
        config: """
        # Madeira's recommended settings for Dark Souls III.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        pool-split = 1
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        env.MADEIRA_LOCK_ORPHAN = stamped
        env.MADEIRA_PAD_EARLY_SLOT = 1
        env.MADEIRA_CONTROLS_XBOX_DEFAULT = 1
        env.MADEIRA_EC_HOOK_TRACE = 0
        """)
    /// Fallout: New Vegas (tested on an iPhone, 2026-10-26): loading a save crashed at
    /// 00B57AA9 right after the game built a face, on Madeira's own card name and
    /// driver, which give it the basic render path (Shader Package 2). "Older NVIDIA
    /// card (Direct3D 9)" reports the card and driver the game knows (Shader Package
    /// 13), as the d3d9.dll wrapper its players install does. The config is the
    /// standard list, which the game ran with.
    static let falloutNewVegas = GameRecommendation(
        id: "fallout-new-vegas", title: "Fallout: New Vegas", version: 1,
        config: """
        # Madeira's recommended settings for Fallout: New Vegas.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        """,
        olderNvidia: true)

    /// Fallout 3 and its Game of the Year Edition: New Vegas's engine, which picks
    /// its render path the same way. Not tested on a device yet.
    static let fallout3 = GameRecommendation(
        id: "fallout-3", title: "Fallout 3", version: 1,
        config: """
        # Madeira's recommended settings for Fallout 3 (not tested yet).
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        """,
        olderNvidia: true)

    /// Batman: Arkham City (GOTY, 200260; the first edition, 57400, has the same
    /// BatmanAC.exe and is not tested). Tested on an iPhone 17 Pro Max, builds 60
    /// and 63 (2026-10-31). Without "Older NVIDIA card (Direct3D 9)", BatmanAC.exe
    /// read the adapter (Madeira's own card name), started its .NET launcher
    /// BmLauncher.exe and exited, and the session ended with the launcher still
    /// opening (log 17:20). With it, BatmanAC.exe started no launcher and drew its
    /// first frame (log 22:26, build 63), and the game played. The config is the
    /// standard list, which it ran with.
    static let batmanArkhamCity = GameRecommendation(
        id: "batman-arkham-city", title: "Batman: Arkham City", version: 1,
        config: """
        # Madeira's recommended settings for Batman: Arkham City.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        """,
        olderNvidia: true)

    /// Call of Duty: Black Ops II, campaign (202970) and Zombies (212910), which
    /// share one folder; multiplayer (202990) lives there too. Build 26
    /// (2026-10-26): Zombies' sound crackled with the 60 ms default although the
    /// speaker was never short (the [ios_audio] ml1230 pacing lines), and 150 ms
    /// cleared it (owner's test, 2026-10-27). The standard list's line besides,
    /// which it ran with; not madeira-bcd's defaults, which it did not.
    static let blackOps2 = GameRecommendation(
        id: "black-ops-2", title: "Call of Duty: Black Ops II", version: 1,
        config: """
        # Madeira's recommended settings for Call of Duty: Black Ops II.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_AUDIO_LEAD_MS = 150
        env.MADEIRA_EC_HOOK_TRACE = 0
        """)

    /// Project Zomboid (Build 42, Steam). Its launcher starts Azul Zulu 25 with
    /// -XX:+UseZGC (ProjectZomboid64.json); ZGC reserves its heap 4-8 TB up and the
    /// guest's address space ends at 512 GB, so every reservation fails and Java
    /// exits with code 1 about a second in. _JAVA_OPTIONS is read after the
    /// launcher's own options, so G1 replaces ZGC without editing the game's file
    /// (iPhone, build 31: Java then starts and reaches LWJGL). The game draws with
    /// OpenGL only. Tested through Madeira Dock with the standard list's lines, so
    /// without madeira-bcd's defaults (see the standard list). No switches.
    /// Version 2 (iPhone, build 50: in a world and playable): Java patches its
    /// code cache all the time, and with a global WINEDEBUG that turns
    /// err:virtual back on (that device had err+all,fixme+all,+seh) every
    /// write-protect change logged three lines: 371 MB, 3.6 million lines while
    /// loading, with heavy stutters. The list keeps Madeira's default of no
    /// err:virtual whatever the global settings say, like God of War's.
    /// Version 3 (iPhone, build 60, 2026-10-31): -XX:TieredStopAtLevel=1 keeps
    /// Java on its quick C1 compiler. FEX translated half as many blocks by the
    /// same point (376k vs ~800k: C2's recompiles patch the code cache, and every
    /// patch re-translates a page), the menus answer faster and play was fine.
    /// Time to the main menu stayed about the same.
    /// Version 4 (iPhone, build 60, 2026-10-31): the launcher's class path is
    /// ".;projectzomboid.jar", so every class load first looked in the game folder,
    /// and each miss is a slow case-insensitive Wine path lookup (fstatat, xattrs).
    /// _JAVA_OPTIONS comes after the launcher's options, so its java.class.path
    /// wins: the jar first, the folder second (loose class files, as Java mods
    /// and older builds use, still load). Main menu in about 2.5 minutes instead
    /// of 4 to 4.5.
    static let projectZomboid = GameRecommendation(
        id: "project-zomboid", title: "Project Zomboid", version: 4,
        config: """
        # Madeira's recommended settings for Project Zomboid.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env._JAVA_OPTIONS = -XX:-UseZGC -XX:+UseG1GC -XX:TieredStopAtLevel=1 -Djava.class.path=projectzomboid.jar;.
        env.WINEDEBUG = err+all,err-virtual,fixme-all
        env.MADEIRA_EC_HOOK_TRACE = 0
        """)

    /// Project Zomboid's legacy build 41 (Steam's b41 beta branch): no
    /// projectzomboid.jar; its classes sit loose under java\ beside the libraries'
    /// jars, all on the launcher's class path, so version 4's java.class.path would
    /// leave the game unable to find its own classes. The same list without it.
    static let projectZomboidB41 = GameRecommendation(
        id: "project-zomboid-b41", title: "Project Zomboid (build 41)", version: 1,
        config: """
        # Madeira's recommended settings for Project Zomboid (build 41).
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env._JAVA_OPTIONS = -XX:-UseZGC -XX:+UseG1GC -XX:TieredStopAtLevel=1
        env.WINEDEBUG = err+all,err-virtual,fixme-all
        env.MADEIRA_EC_HOOK_TRACE = 0
        """)

    /// Build 41 when the game's folder has its program but no projectzomboid.jar;
    /// the current list otherwise (and before the game is installed).
    static func projectZomboidList(folder: String, fileExists: (String) -> Bool) -> GameRecommendation {
        fileExists(folder + "\\ProjectZomboid64.exe") && !fileExists(folder + "\\projectzomboid.jar")
            ? projectZomboidB41 : projectZomboid
    }

    /// Counter-Strike 2 (Steam; tested on an iPhone 17 Pro Max, build 47, 2026-10-30).
    /// v8.dll (48 MB, the Panorama UI) found no room in the JIT pool and cs2.exe
    /// stopped (build 39). Pure-x64 DLLs run from their loaded image instead of a
    /// pool copy (about 400 MB freed), and the pool joins the free run above the
    /// main thread's stack (about 880 MB instead of 592): the game then reaches
    /// its menu and matches. No switches.
    static let counterStrike2 = GameRecommendation(
        id: "counter-strike-2", title: "Counter-Strike 2", version: 1,
        config: """
        # Madeira's recommended settings for Counter-Strike 2.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        pool = 896
        pool-split = 1
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        env.MADEIRA_EC_HOOK_TRACE = 0
        """)

    /// The Escapists 2 (Steam; tested on an iPhone 17 Pro Max, build 47,
    /// 2026-10-30). A 32-bit Unity game on the old mono.dll: Mono's XCHG code
    /// patches at unaligned addresses faulted through the JIT pool's alias, so
    /// its code memory stays plain read/write. No switches.
    static let escapists2 = GameRecommendation(
        id: "escapists-2", title: "The Escapists 2", version: 1,
        config: """
        # Madeira's recommended settings for The Escapists 2.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_WOW_RWX_PLAIN = 1
        env.MADEIRA_EC_HOOK_TRACE = 0
        """)

    /// Slay the Spire 2 (Steam; tested on an iPhone 17 Pro Max, build 48,
    /// 2026-10-30). SlayTheSpire2.exe is 855 MB (Godot packs the game data inside
    /// it), more than the whole JIT pool, so it could not load (c0000017): CS2's
    /// pool lines run it from its loaded image. .NET 9's 256 GB heap reservation
    /// gets 16 GB instead, and .NET's write-xor-execute double mapping is off (the
    /// run view is a copy, so the runtime's own writes never showed there and it
    /// stopped on "m_pRegionToGenTableImmediate"). No switches.
    static let slayTheSpire2 = GameRecommendation(
        id: "slay-the-spire-2", title: "Slay the Spire 2", version: 1,
        config: """
        # Madeira's recommended settings for Slay the Spire 2.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        pool = 896
        pool-split = 1
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        env.DOTNET_GCRegionRange = 400000000
        env.DOTNET_EnableWriteXorExecute = 0
        env.MADEIRA_EC_HOOK_TRACE = 0
        """)

    /// Garry's Mod (Steam; tested on an iPhone 17 Pro Max, build 60, 2026-10-31).
    /// Multiplayer works on Steam's x86-64 branch (64-bit gmod.exe, 60 FPS against
    /// 17-53 on the 32-bit default branch) with -nochromium. Its main menu and other
    /// web panels are Chromium pages, and Chromium's sandboxed helpers don't start on
    /// Madeira yet, so the menu says "Menu failed to load". CS2's pool lines carry the
    /// 64-bit libcef.dll; pool-split is harmless and NOCOPY does nothing on 32-bit,
    /// so the list fits both branches. No switches. How to play (branch, launch
    /// argument, console commands) is the Will it run? note (KnownGames).
    static let garrysMod = GameRecommendation(
        id: "garrys-mod", title: "Garry's Mod", version: 1,
        config: """
        # Madeira's recommended settings for Garry's Mod.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        pool = 896
        pool-split = 1
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        env.MADEIRA_EC_HOOK_TRACE = 0
        """)

    /// The Rockstar Games Launcher outside Steam (125hz, 6f7eb58a on
    /// 125hz/Madeira vulkan-stack-1028). Through Madeira Dock the game's own list
    /// carries the launcher chain's lines and the Dock starts the service manager; a
    /// library entry for the launcher itself had neither. Log 91: no service manager,
    /// so the launcher's service could not be installed (\pipe\svcctl missing, RPC
    /// 1722). Log 92: with it, the sign-in helper's libcef.dll found no room in a
    /// 624 MB pool (c0000017, six restarts, a black window). Log 93: with the pool
    /// lines, libcef loaded, then the helper's 32 GB PartitionAlloc reservation met
    /// the emulator's arena and Chromium stopped itself (0x80000003). So: the Wine
    /// desktop with Windows services first, and the chain's lines from the games'
    /// lists (Social Club layout 2, the pool lines, pure-x64 images uncopied, the
    /// crash handler and the vc_redist re-run refused).
    static let rockstarLauncher = GameRecommendation(
        id: "rockstar-launcher", title: "Rockstar Games Launcher", version: 1,
        config: """
        # Madeira's recommended settings for the Rockstar Games Launcher outside Steam.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        pool-low = 1
        pool-mid = 1
        pool-page-fit = 1
        pool-split = 1
        env.FEX_VECTORTSOENABLED = 0
        env.MADEIRA_SC_PA_POOLS = 2
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        env.MADEIRA_EXECREQ_LEAVE = 1
        env.MADEIRA_LOCK_ORPHAN = stamped
        env.MADEIRA_POOL_HEAD_RESERVE_MB = 128
        env.MADEIRA_POOL_LOW_IMAGES = 1
        env.MADEIRA_POOL_RECYCLE_IMAGES = 1
        env.MADEIRA_SPAWN_BLOCK = RockstarErrorHandler;.be\\vc_redist
        env.MADEIRA_TOUCH_MOUSE = 1
        env.MADEIRA_WOW_MIN_FREE_GB = 2
        env.DXMT_SMALL_RINGS = Launcher.exe;SocialClubHelper.exe
        env.DXMT_WSI_MONITOR_IDENTITY = 1
        env.DXMT_WSI_MODE_TABLE = 1
        env.MADEIRA_EC_HOOK_TRACE = 0
        # madeira-bcd's defaults, which this list was tested with (upstream's differ).
        env.MADEIRA_FREE_DELAY_MS = 2000
        env.MADEIRA_CTX_CPU_AREA = 2
        env.MADEIRA_WAIT_CHILDREN = 1
        env.MADEIRA_JIT_DUMP = 0
        """,
        fastSync: true, display: "fit", launchMode: "desktop", startServices: true)

    /// The Rockstar launcher's installer (125hz, log 91): it installs the launcher's
    /// service, which needs the service manager, and runs the embedded vc_redist,
    /// which the launcher's list refuses; so the two Launch switches and the
    /// standard line only.
    static let rockstarLauncherSetup = GameRecommendation(
        id: "rockstar-launcher-setup", title: "Rockstar Games Launcher installer", version: 1,
        config: """
        # Madeira's recommended settings for the Rockstar Games Launcher installer.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        """,
        launchMode: "desktop", startServices: true)

    /// Ubisoft Connect (LauncherSupport.swift; owner's choice, 2026-10-29). The client
    /// is 32-bit: UbisoftConnect.exe starts upc.exe and UplayWebCore.exe (a 32-bit
    /// Chromium), each in its own 4 GB window. Version 1 took the 64-bit Chromium
    /// layout Social Club and the Rockstar launcher use (Social Club layout 2, the pool
    /// lines), which fills [0x7400000000, 0x7c00000000) with libcef's reservations; on
    /// build 48 the second 32-bit process then found no window ("[wow-window] no free
    /// 4GB-aligned slot", upc.exe exit code 1) and the client never opened. Version 2
    /// has none of those lines, so the extra windows spill into that range
    /// (MADEIRA_WOW_SPILL_CEF), and keeps the 2 GB margin, every window slot from the
    /// start and the small DXMT rings. Version 3 (build 58): upc.exe hooks ntdll by
    /// writing into its own code, and a write into its own process is denied unless
    /// the program is a local-write-target ("[hard-error] ... Error at hooking API
    /// \"LdrFindResource_U\"", then exit 0xdeadc0de). Its service and out-of-process COM need the
    /// service manager, so the Wine desktop with Windows services first. The swap
    /// file takes the web helper's idle pages. No release delay (madeira-bcd's
    /// 2000 ms): Chromium's allocator reserves, releases and reserves again.
    /// Version 4 (build 58 log, 2026-10-31): with the hook fixed the window opened,
    /// then five UplayWebCore.exe helpers found no 4 GB window ("BOOT FAILED at stage
    /// 'guest-window-reserve'"; the band holds eight), the picture only redrew on a
    /// minimize and the client quit. upc.exe is the Chromium browser process (it
    /// starts the UplayWebCore.exe helpers), and Chromium reads switches from the
    /// process command line, so MADEIRA_CHILD_ARGS gives it one renderer and the GPU
    /// work inside upc.exe. Device log 16:16Z: upc.exe still started a GPU process, so
    /// Ubisoft's CEF setup seems to ignore its own command line; the line is harmless
    /// and stays until a log shows otherwise. That run had no failed helpers before
    /// upc.exe hit the x18 LDRSW crash (fixed in signal_arm64_ios.c).
    /// Version 5 (log 16:20Z): with the crash gone, upc.exe ran its two services,
    /// Chromium's GPU, network and storage helpers and asked for six renderers; the
    /// ninth program found the window registry (eight entries) full and the client
    /// said "Ubisoft services are temporarily unavailable". The switches line is
    /// dropped; instead upc.exe alone is told 479 MB of memory (exe-phys-mb), which
    /// caps Chromium at three renderers (physical MB / 2 / 60, at least 3), and the
    /// registry now holds ten windows. The renderers keep the real figure for V8.
    static let ubisoftConnect = GameRecommendation(
        id: "ubisoft-connect", title: "Ubisoft Connect", version: 5,
        config: """
        # Madeira's recommended settings for Ubisoft Connect.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        swap-mb = 4096
        swap-min-mb = 1
        local-write-target = upc.exe;UbisoftConnect.exe;UplayWebCore.exe
        env.MADEIRA_SWAP_COVERAGE = broad
        env.MADEIRA_LOCK_ORPHAN = stamped
        env.MADEIRA_TOUCH_MOUSE = 1
        env.MADEIRA_WOW_MIN_FREE_GB = 2
        env.MADEIRA_WOW_PLACEHOLDERS = 1
        env.DXMT_SMALL_RINGS = UbisoftConnect.exe;upc.exe;UplayWebCore.exe
        env.MADEIRA_EC_HOOK_TRACE = 0
        exe-phys-mb = upc.exe:479
        """,
        fastSync: true, display: "fit", launchMode: "desktop", startServices: true)

    /// Ubisoft Connect's installer: it installs the client's service, which needs the
    /// service manager; so the two Launch switches and the standard line only.
    static let ubisoftConnectSetup = GameRecommendation(
        id: "ubisoft-connect-setup", title: "Ubisoft Connect installer", version: 1,
        config: """
        # Madeira's recommended settings for the Ubisoft Connect installer.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        """,
        launchMode: "desktop", startServices: true)

    /// Battle.net (LauncherSupport.swift; owner's choice, 2026-10-29): "Battle.net
    /// Launcher.exe" starts Battle.net.exe, Blizzard's Chromium (CEF) client, and
    /// Agent.exe, which installs and updates the games. Both the launcher and the
    /// client are 32-bit, like Ubisoft Connect's: version 1 had the 64-bit Chromium
    /// lines, and on build 48 Battle.net.exe found no window ("[wow-window] no free
    /// 4GB-aligned slot") while the launcher held the band's. Version 2 is Ubisoft
    /// Connect's version 2 (the extra windows spill into the Chromium pool range,
    /// MADEIRA_WOW_SPILL_CEF), with the Wine desktop with Windows services first for
    /// the Agent's out-of-process COM. Windows' location service is off: the client
    /// stops on it under Wine (Lutris's Battle.net script turns it off the same way).
    /// Version 3 (build 58 log, 2026-10-31, StarCraft install): ten Battle.net.exe
    /// renderers found no 4 GB window, the main page's renderer then crashed in
    /// libcef.dll and its replacement could not start either, so the window went
    /// blank while Agent.exe kept running. MADEIRA_CHILD_ARGS gives Battle.net.exe
    /// (the Chromium browser process) one renderer and the GPU work in-process.
    /// Version 4 (build 63 logs, 2026-11-01, StarCraft from Battle.net): the store
    /// page's YouTube trailer started extra renderers (site isolation) and crashed
    /// one; YouTube is now unresolvable, autoplay waits for a click and embeds share
    /// the one renderer. The game page's JavaScript JIT kept FEX recompiling for a
    /// minute until the 32-bit renderer ran out of memory: V8 keeps its interpreter
    /// and WebAssembly but no optimizing tiers (--jitless left the page blank). With
    /// that the home page drew at 60 FPS (Cameron). pool-split: the session's JIT
    /// pool also holds the games Battle.net starts (StarCraft's ClientSdk.dll failed
    /// to load in a 560 MB pool; split, 880 MB).
    static let battleNet = GameRecommendation(
        id: "battle-net", title: "Battle.net", version: 4,
        config: """
        # Madeira's recommended settings for Battle.net.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        swap-mb = 4096
        swap-min-mb = 1
        env.MADEIRA_SWAP_COVERAGE = broad
        env.MADEIRA_LOCK_ORPHAN = stamped
        env.MADEIRA_TOUCH_MOUSE = 1
        env.MADEIRA_WOW_MIN_FREE_GB = 2
        env.MADEIRA_WOW_PLACEHOLDERS = 1
        env.DXMT_SMALL_RINGS = Battle.net Launcher.exe;Battle.net.exe;Agent.exe
        env.WINEDLLOVERRIDES = locationapi=d
        env.MADEIRA_EC_HOOK_TRACE = 0
        env.MADEIRA_CHILD_ARGS = Battle.net.exe --renderer-process-limit=1 --in-process-gpu --js-flags="--no-opt --no-sparkplug" --disable-site-isolation-trials --autoplay-policy=user-gesture-required --host-resolver-rules="MAP youtube.com ~NOTFOUND, MAP *.youtube.com ~NOTFOUND, MAP youtube-nocookie.com ~NOTFOUND, MAP *.youtube-nocookie.com ~NOTFOUND, MAP *.googlevideo.com ~NOTFOUND, MAP *.ytimg.com ~NOTFOUND"
        pool-split = 1
        """,
        fastSync: true, display: "fit", launchMode: "desktop", startServices: true)

    /// Battle.net's installer (Battle.net-Setup.exe), which downloads the client:
    /// the two Launch switches and the standard line only.
    static let battleNetSetup = GameRecommendation(
        id: "battle-net-setup", title: "Battle.net installer", version: 1,
        config: """
        # Madeira's recommended settings for the Battle.net installer.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        """,
        launchMode: "desktop", startServices: true)

    /// Final Fantasy XIV's launcher (boot\ffxivboot.exe; LauncherSupport.swift), kept
    /// for installing and updating the game: Madeira signs the game itself in
    /// (FFXIVLaunch.swift). Its window is Internet Explorer's engine (mshtml), not
    /// Chromium, so the standard line only, in the Wine desktop with Windows services
    /// first (version 2): its installer only ran that way on build 48. Not
    /// device-tested yet.
    static let ffxivLauncher = GameRecommendation(
        id: "ffxiv-launcher", title: "Final Fantasy XIV launcher", version: 2,
        config: """
        # Madeira's recommended settings for the Final Fantasy XIV launcher.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        """,
        launchMode: "desktop", startServices: true)

    /// Final Fantasy XIV's installer (ffxivsetup.exe), which installs the launcher
    /// through InstallShield (ffxivinstaller.exe, ISBEW64.exe). Build 48: started
    /// directly its window stayed black; in the Wine desktop with Windows services first
    /// it installed (owner's test, 2026-10-30). Version 2 starts it that way.
    static let ffxivSetup = GameRecommendation(
        id: "ffxiv-setup", title: "Final Fantasy XIV installer", version: 2,
        config: """
        # Madeira's recommended settings for the Final Fantasy XIV installer.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        """,
        launchMode: "desktop", startServices: true)

    /// Every other game, and the Desktop (owner's decisions, 2026-10-12): most games
    /// the owner tried outside these lists closed at start until the [ec-hook]
    /// reporter was off. It reads code a game's protection rewrites at run time
    /// (GTA V Enhanced outside Steam on build 451, Ghost of Tsushima on build 515),
    /// and it only logs, so turning it off costs a game nothing. Version 3: without
    /// madeira-bcd's defaults (version 2 had them). This list reaches every game, and
    /// MADEIRA_FREE_DELAY_MS keeps a released block's addresses taken, so an allocator
    /// that reserves, releases and reserves again inside the same range never gets it
    /// back: Madeira Dock spun on "Loading Steam" before Thumper. The game lists that
    /// were tested with those defaults keep them. No switches.
    static let standard = GameRecommendation(
        id: "standard", title: "games without a list of their own", version: 3,
        config: """
        # Madeira's recommended settings for a game without a list of its own.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        env.MADEIRA_EC_HOOK_TRACE = 0
        """)

    /// Grounded (Steam; tested on an iPhone 17 Pro Max, build 63, 2026-11-01).
    /// Unreal's built-in browser (libcef.dll, 95 MB) needs CS2's pool lines. Loading
    /// into the world reached the 8 GB app memory limit: Unreal commits most of its
    /// memory as 64 KB reservations, so the swap tier backs whole reservations down
    /// to 64 KB (broad, ml2191 grows one extent for side-by-side ones), the game's
    /// images go to the swap file too, and a 1 GB video budget keeps Unreal's
    /// texture pool small. No switches.
    static let grounded = GameRecommendation(
        id: "grounded", title: "Grounded", version: 1,
        config: """
        # Madeira's recommended settings for Grounded.
        # Reset to Recommended, at the bottom of the game's settings, brings them back.
        pool = 896
        pool-split = 1
        env.MADEIRA_X64_IMAGE_NOCOPY = 1
        swap-mb = 8192
        swap-mode = 2
        env.MADEIRA_SWAP_MIN_KB = 64
        swap-images = 1
        vram-mb = 1024
        env.MADEIRA_EC_HOOK_TRACE = 0
        """)

    static let all = [rdr2Steam, rdr2Other, gta5EnhancedSteam, gta5EnhancedOther, ghostOfTsushima, godOfWar, horizonZeroDawn,
                      darkSoulsRemastered, darkSoulsIII, falloutNewVegas, fallout3, batmanArkhamCity, blackOps2, projectZomboid, projectZomboidB41,
                      counterStrike2, escapists2, slayTheSpire2, garrysMod, grounded, rockstarLauncher, rockstarLauncherSetup, ubisoftConnect, ubisoftConnectSetup, battleNet, battleNetSetup,
                      ffxivLauncher, ffxivSetup, standard]

    // MARK: Recognising a game

    /// Steam App IDs.
    static let rdr2AppID = 1174180, gta5EnhancedAppID = 3240220, ghostAppID = 2215430, godOfWarAppID = 1593500,
               horizonZeroDawnAppID = 1151640, darkSoulsRemasteredAppID = 570940, darkSoulsIIIAppID = 374320,
               projectZomboidAppID = 108600, counterStrike2AppID = 730, escapists2AppID = 641990,
               slayTheSpire2AppID = 2868840, garrysModAppID = 4000, groundedAppID = 962130
    static let falloutNewVegasAppID = 22380, fallout3AppIDs: Set<Int> = [22300, 22370]   // Fallout 3, its GOTY Edition
    /// Batman: Arkham City's Game of the Year Edition and its first edition.
    static let batmanArkhamCityAppIDs: Set<Int> = [200260, 57400]
    /// Black Ops II's campaign, Zombies and multiplayer.
    static let blackOps2AppIDs: Set<Int> = [202970, 212910, 202990]

    /// The recommendation for a game, or nil.
    /// - windowsPath: a program ("C:\Games\GoW\GoW.exe"), or a library Steam
    ///   game's install folder ("C:\...\steamapps\common\Red Dead Redemption 2").
    /// - steamAppID: set for a library Steam game.
    /// - fileExists: whether a C:\ path exists (GTA5_Enhanced.exe beside a program).
    static func match(windowsPath: String, steamAppID: Int?, fileExists: (String) -> Bool) -> GameRecommendation? {
        let path = windowsPath.replacingOccurrences(of: "/", with: "\\").trimmingSuffix("\\")
        let parts = path.lowercased().split(separator: "\\").map(String.init)
        guard let last = parts.last else { return nil }
        let steamFolder = steamCommonFolder(parts)
        guard last.hasSuffix(".exe") else {
            // A library Steam game: its App ID, or its install folder right under
            // steamapps\common (not a batch file inside it).
            let installFolder = last == steamFolder ? steamFolder : nil
            if steamAppID == rdr2AppID || installFolder == "red dead redemption 2" { return rdr2Steam }
            if steamAppID == gta5EnhancedAppID || installFolder == "grand theft auto v enhanced" { return gta5EnhancedSteam }
            if steamAppID == ghostAppID || installFolder == "ghost of tsushima director's cut"
                || installFolder == "ghost of tsushima" { return ghostOfTsushima }
            if steamAppID == godOfWarAppID || installFolder == "godofwar" || installFolder == "god of war" { return godOfWar }
            if steamAppID == horizonZeroDawnAppID || installFolder == "horizon zero dawn" { return horizonZeroDawn }
            if steamAppID == darkSoulsRemasteredAppID || installFolder == "dark souls remastered" { return darkSoulsRemastered }
            if steamAppID == darkSoulsIIIAppID || installFolder == "dark souls iii" { return darkSoulsIII }
            if steamAppID == falloutNewVegasAppID || installFolder == "fallout new vegas" { return falloutNewVegas }
            if steamAppID.map(fallout3AppIDs.contains) == true || installFolder == "fallout 3"
                || installFolder == "fallout 3 goty" { return fallout3 }
            if batmanArkhamCityAppIDs.contains(steamAppID ?? 0) || installFolder == "batman arkham city goty"
                || installFolder == "batman arkham city" { return batmanArkhamCity }
            if blackOps2AppIDs.contains(steamAppID ?? 0) || installFolder == "call of duty black ops ii" { return blackOps2 }
            if steamAppID == projectZomboidAppID || installFolder == "projectzomboid" {
                return projectZomboidList(folder: path, fileExists: fileExists)
            }
            if steamAppID == counterStrike2AppID || installFolder == "counter-strike global offensive" { return counterStrike2 }
            if steamAppID == escapists2AppID || installFolder == "the escapists 2" { return escapists2 }
            if steamAppID == slayTheSpire2AppID || installFolder == "slay the spire 2" { return slayTheSpire2 }
            if steamAppID == garrysModAppID || installFolder == "garrysmod" { return garrysMod }
            if steamAppID == groundedAppID || installFolder == "grounded" { return grounded }
            return nil
        }
        // A program, wherever it was installed: only the game's own programs, so a
        // redistributable inside a game's folder gets nothing.
        let inSteam = steamAppID != nil || steamFolder != nil
        switch last {
        case "playgtav.exe", "gta5_enhanced.exe":
            // GTA V Enhanced (the legacy edition has PlayGTAV.exe too, beside GTA5.exe):
            // inside a Steam library the Steam copy, anywhere else the list for outside Steam.
            let folder = path.lastIndex(of: "\\").map { String(path[..<$0]) } ?? ""
            guard fileExists(folder + "\\GTA5_Enhanced.exe") else { return nil }
            return inSteam ? gta5EnhancedSteam : gta5EnhancedOther
        case "rdr2.exe", "playrdr2.exe":
            return inSteam ? rdr2Steam : rdr2Other
        case "ghostoftsushima.exe":
            return ghostOfTsushima
        case "gow.exe":
            return godOfWar
        case "horizonzerodawn.exe":
            return horizonZeroDawn
        case "darksoulsremastered.exe":
            return darkSoulsRemastered
        case "darksoulsiii.exe":
            return darkSoulsIII
        case "falloutnv.exe":
            return falloutNewVegas
        case "fallout3.exe":
            return fallout3
        case "batmanac.exe":
            return batmanArkhamCity
        case "t6sp.exe", "t6zm.exe", "t6mp.exe":
            return blackOps2
        case "projectzomboid64.exe":
            return projectZomboidList(folder: path.lastIndex(of: "\\").map { String(path[..<$0]) } ?? "", fileExists: fileExists)
        case "cs2.exe":
            return counterStrike2
        case "theescapists2.exe":
            return escapists2
        case "slaythespire2.exe":
            return slayTheSpire2
        case "gmod.exe":
            return garrysMod
        case "maine-win64-shipping.exe":
            return grounded
        case "launcher.exe" where Array(parts.dropLast().suffix(2)) == ["rockstar games", "launcher"]:
            // The Rockstar Games Launcher outside Steam; another publisher's Launcher.exe gets nothing here.
            return rockstarLauncher
        case "rockstar-games-launcher.exe":
            return rockstarLauncherSetup
        case "ubisoftconnect.exe", "upc.exe", "uplay.exe":
            // Ubisoft Connect in its own folder (a Uplay.exe of LauncherSupport's links too).
            return parts.dropLast().last == "ubisoft game launcher" ? ubisoftConnect : nil
        case "ubisoftconnectinstaller.exe", "uplayinstaller.exe":
            return ubisoftConnectSetup
        case "battle.net launcher.exe", "battle.net.exe":
            return parts.dropLast().last == "battle.net" ? battleNet : nil
        case "battle.net-setup.exe":
            return battleNetSetup
        case "ffxivboot.exe":
            return parts.dropLast().last == "boot" ? ffxivLauncher : nil
        case "ffxivsetup.exe":
            return ffxivSetup
        default:
            return nil
        }
    }

    /// The folder name right under steamapps\common, lowercased, or nil.
    static func steamCommonFolder(_ parts: [String]) -> String? {
        guard parts.count >= 3 else { return nil }
        for i in 0..<(parts.count - 2) where parts[i] == "steamapps" && parts[i + 1] == "common" {
            return parts[i + 2]
        }
        return nil
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        var s = self
        while s.hasSuffix(suffix) { s.removeLast(suffix.count) }
        return s
    }
}
