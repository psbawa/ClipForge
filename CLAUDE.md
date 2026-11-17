# ClipForge

macOS 14+ SwiftUI app. App shell in `ClipForge/`; everything else in local package `ClipForgeKit/`. Progress + assumptions: `PLAN.md` (update the checklist after each milestone).

## Commands
- Tests: `cd ClipForgeKit && xcodebuild test -scheme ClipForgeKit-Package -destination 'platform=macOS' -quiet`
- App build: `xcodebuild -project "Untitled Project 2.xcodeproj" -scheme ClipForge -destination 'platform=macOS' build -quiet`

## Conventions
- Swift 6 strict concurrency. One `actor` per pipeline stage; each behind a protocol so tests can mock it.
- Pure logic (parsing, merging, policy, rights) lives in `struct`/static funcs and is unit-tested; no network in tests.
- Secrets only in Keychain (`Keychain.swift`). Never log tokens/keys; use `Log` (os.Logger) with `privacy: .private` for user data.
- External tools via `Shell` (yt-dlp, ffmpeg). Never add anything that bypasses platform protections.
- Story Shorts is isolated in `StoryShorts/` (own SwiftData model `StoryJob`, own `StoryModel` runner); all tunables in `StoryConfig.swift`.
- Vlog Editor is in `Vlog/`: `VlogModel` runner, projects saved as JSON (`Movies/ClipForge/vlogs/<id>/project.json`, no SwiftData model); proxies, shot analysis and render segments are cached beside it. Thresholds live at the top of `ShotAnalyzer`/`ChapterBuilder`.
- Tests that render end to end scope their folders with `Paths.$scopedRoot.withValue` (task-local); `StyleLibrary.rootOverride` is task-local too.
- Tests must never write to ~/Movies or ~/Music: set `Paths.rootOverride` / `StoryConfig.musicRootOverride`.
- Commit after each milestone.

## Themes (UI only)
- `ClipForgeKit/Theme/`: `Theme.swift` (tokens), `Themes.swift` (one definition per theme), `ThemeStore.swift` (user choice in
  UserDefaults + resolution with Reduce Motion/Transparency, Increase Contrast, Low Power), `ThemeViews.swift` (root modifier,
  backdrop effects, components), `AppearancePane.swift` (Settings → Appearance), `Fonts/` (OFL fonts + licenses, registered at launch).
- Views read colors as ShapeStyles (`.foregroundStyle(.themeMuted)`, `.themeDanger`, `.themeInk(.review)`, …) and fonts via
  `.themeFont(.caption, weight:, display:, mono:, digits:)`; never hard-code colors/fonts. Sheets need `.themedSheet()`.
- Add a theme: add a `static let` Theme in `Themes.swift` (both palettes, all features) and append it to `Themes.all`.
  `ThemeTests` checks WCAG AA for every pair automatically.
- Effects are background-only (never over content/video); grain/scanlines are pre-rendered tiles.

## iPhone companion
- Package targets: `ClipForgeShared` (macOS+iOS: themes, shared models, companion API types), `ClipForgeKit` (Mac engine + UI,
  re-exports Shared), `ClipForgeMobile` (iPhone UI + client). Xcode targets: `ClipForge` (Mac) and `ClipForge Mobile` (iOS 17,
  bundle app.clipforge.ClipForge.mobile). Run tests with the `ClipForgeKit-Package` scheme.
- The Mac serves the phone over the local network (`Companion/`: Bonjour `_clipforge._tcp`, HTTP/JSON, private IPs only),
  off by default (Settings → iPhone). Pairing: 6-digit code (3 min, single use, 5 tries) → random token; the Mac stores only
  SHA-256 hashes (Keychain `companion.devices`). The phone never gets API keys or YouTube tokens; the Mac does all actions.
- Free Apple ID: no iCloud, so sync is Wi-Fi only and device installs expire after 7 days (re-run from Xcode).
