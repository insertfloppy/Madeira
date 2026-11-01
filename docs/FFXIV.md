# Final Fantasy XIV

Madeira's FINAL FANTASY XIV support is Trey Boyer's (wwboyer/Madeira,
feat/square-enix-login and feat/ffxiv-patching, upstream #488):

- Sign-in with a Square Enix account, license choice and one-time password:
  `docs/SQUARE_ENIX_SIGNIN.md` (`app/Madeira/SquareEnixSignIn.swift`,
  `app/Madeira/SquareEnixSignInView.swift`).
- The library's FINAL FANTASY XIV section installs the game on this device or an
  external drive and downloads and applies Square Enix's patches itself:
  `docs/FFXIV_PATCHING.md` (`app/Madeira/FFXIVLibrary.swift`,
  `app/Madeira/FFXIVPatcher.swift`).
- `env.MADEIRA_FFXIV = 0` turns the section off. Square Enix's own launcher then
  returns to Settings › PC game launchers (docs/LAUNCHERS.md) for installs and
  updates.
- Wine patch 0017 (`build/wine-patches/0017-ntdll-hide-wine-host-version.patch`)
  hides `wine_get_host_version` from the game's run-time lookups when the app sets
  `MADEIRA_HIDE_WINE_HOST_VERSION=1` (a Windows license), so it doesn't pick its
  Mac version.

Our earlier sign-in at Play (FFXIVLaunch.swift, SwiftFFXIV/FFXIVLogin.swift) was
replaced by this on 2026-11-01.
