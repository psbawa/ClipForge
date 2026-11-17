# ClipForge — Plan

Native macOS 14+ app: watch a YouTube live stream/VOD the user owns (or has permission to clip), find highlights with Claude, cut 9:16 captioned clips, publish as Shorts to the user's own channel.

## Layout
- `ClipForge/` — app shell (`@main`, assets). Xcode project `Untitled Project 2.xcodeproj`, target/scheme `ClipForge`.
- `ClipForgeKit/` — local Swift package with all logic + SwiftUI views + tests.
  - `Ingest`, `Transcription`, `Highlight` (+ `AnthropicClient`, `CostTracker`), `Clip` (+ `SmartCrop`), `Caption`, `Publish` (+ `YouTubeAuth`, `PublishPolicy`), `RightsGuard`, `LiveOrchestrator`, `UI/`.

## Milestones
- [x] M1 ingest + transcription (WhisperKit integration test passes; live capture not yet run against a real stream)
- [x] M2 highlight detection (two-stage, CostTracker, 8 unit tests w/ mocked API; not yet run against the live API)
- [x] M3 cut + 9:16 crop + captions (real ffmpeg render test from .ts segments passes)
- [x] M4 UI + clips gallery (app builds + launches; UI not visually verified — no screen-capture permission)
- [x] M5 YouTube OAuth + upload + review queue (6 mocked-HTTP tests pass; **real private test upload still pending** — needs your Google OAuth client)
- [x] M6 live mode + auto-publish limits + RightsGuard (orchestrator tests: VOD auto-publish once, no double publish on resume, foreign-channel gating, kill switch, live step scoring)
- [x] M7 hardening: log audit (no tokens/keys; user text `.private`), per-segment transcription recovery, Claude network retries, live end-of-stream detection, settings schema-merge, Pipeline menu (Stop ⌘., kill switch ⇧⌘K), hardened runtime + `scripts/notarize.sh`

## Assumptions
- Existing Xcode project reused (renamed target to ClipForge) rather than generating a new one; logic lives in an SPM package so `xcodebuild test` runs it headless.
- yt-dlp and ffmpeg come from Homebrew (`/opt/homebrew/bin`, `/usr/local/bin`, or `PATH`); not bundled. App sandbox is OFF (it must exec those binaries and write to ~/Movies); Hardened Runtime ON for Developer ID notarization.
- Live capture = `yt-dlp -o - URL | ffmpeg -f segment` (10 s .ts segments + CSV index). Timeline is "session seconds" from capture start; on reconnect the timeline continues from the last segment end (the dropped gap is lost).
- Retention: segments older than `bufferMinutes` (default 30) are deleted. A clip can only be cut while its segments still exist.
- Transcription: each segment's audio is extracted to 16 kHz mono WAV and transcribed by WhisperKit; word timestamps are offset by the segment start. Default model `openai_whisper-base.en`.
- Every finished video gets at least `minClipsPerVideo` (default 3) clips: its best non-overlapping moments, even below the thresholds. Stage A always returns its best 1–3 picks per window with honest scores. Auto-publish still requires `minAutoScore`, so low scorers wait in review. Live streams use thresholds only (no "end" to fill at).
- Highlight JSON times are session seconds. Stage A runs on the last `windowSeconds` (360) every `stepSeconds` (90). Stage B ranks only candidates ≥ `stageBThreshold`.
- Claude: raw HTTPS to `/v1/messages` (no official Swift SDK). Static instructions in the system block with `cache_control`. Haiku 5.5 at effort `low`. Default prices (USD/MTok, editable): Haiku 5.5 0.10 in / 0.50 out, Sonnet 5.5 2.00 / 10.00; cache write 1.25× input, cache read 0.1×.
- YouTube OAuth scopes: `youtube.upload` **plus `youtube.readonly`** — needed to read the authenticated channel ID for RightsGuard (upload scope alone can't call `channels.list?mine=true`). User supplies their own Google "Desktop app" OAuth client ID/secret in Settings (stored in Keychain).
- Shorts qualification: output is 1080×1920 and ≤ 180 s; "#Shorts" appended to title (if room) and description.
- Restart safety: before uploading, the clip record stores its resumable session URL and status `publishing`. On launch, such records are reconciled by querying the session (complete → published, partial → resume, gone → back to review). Never re-POST automatically.
- Captions: Homebrew `ffmpeg` has no libass, so karaoke captions are rendered as transparent PNG frames (CoreGraphics) on an ffconcat timeline and overlaid by ffmpeg; `.srt` sidecar written alongside. Encoder: `h264_videotoolbox` 8 Mbps, loudnorm −14 LUFS.
- Smart crop: Vision face detection (fallback: attention saliency) sampled every 1 s, smoothed, emitted as a piecewise-linear ffmpeg `crop` x-expression.

## Manual steps (cannot be automated here)
- Enter Anthropic API key and Google OAuth client in Settings.
- First upload: keep privacy = private, verify on YouTube Studio.
- Notarization: set your Team ID, `xcodebuild archive`, `xcrun notarytool submit`.

## Status / notes
- All milestones done. `xcodebuild test` → 26 tests pass (1 extra opt-in WhisperKit test: `TEST_RUNNER_CLIPFORGE_INTEGRATION=1`).
- Verified for real: WhisperKit transcription, ffmpeg cut + crop + caption render. App builds (Debug/Release, hardened runtime) and launches.
- **Not yet verified against real services** (need user credentials/streams): Claude API calls, YouTube OAuth + upload (do a private test upload first), yt-dlp live capture on a real stream, UI visually.
- Known ceilings: live timeline restarts on Resume after an app crash (old clips stay in the queue; uploads are reconciled, never re-POSTed). Smart crop samples 1 fps. Caption frames are full-canvas PNGs (fine for ≤3 min clips).

## Resume in a fresh session
Read this file + CLAUDE.md. Code map: `ClipForgeKit/Sources/ClipForgeKit/` — `AppModel*.swift` (orchestrator + publish), one file per service, `UI/`. Tests mirror services in `ClipForgeKit/Tests/`.

## Story Shorts (separate feature)
Gameplay video → 9:16 story short (hook → buildup → climax → payoff), two caption layers, mood music. Code: `ClipForgeKit/Sources/ClipForgeKit/StoryShorts/` + `UI/StoryShortsView.swift`; tweak prompts/options/levels in `StoryConfig.swift`.
- [x] Analyze: WhisperKit transcript + one proxy pass (scdet motion/scene, ebur128 loudness) → candidate moments → 3 frames each
- [x] Story: one Claude Sonnet 5.5 vision call → storyboard JSON, strict validation, 1 retry with the reason, length fit to ±5%
- [x] Captions: narrative cards (upper third) + karaoke subtitles (lower middle), inside the 9:16 safe zone
- [x] Music: `~/Music/ClipForge/<mood>/` (user's licensed tracks) → user-picked file → generated placeholder fallback; beat detection + cut snapping (≤0.25 s); ducking under speech/important audio
- [x] Render: per-beat smart crop or blur fill, crossfades (white flash into climax), H.264 1080×1920 30 fps, −14 LUFS
- [x] Jobs: stages with per-stage watchdog timeouts, real error per stage, Retry from failed stage, Re-render without a new Claude call, export .mp4 + .txt metadata
- [x] Real gameplay test: 50-min CoD MW campaign video (AV1 1080p, used with permission) → 30.8 s short, 6 beats, smart crop + blur fill, −14.8 LUFS, $0.023, ~10 min (analysis dominated by software AV1 decode).
- Known ceilings: game events are inferred by Claude from frames (no dedicated kill/win detector); beat snapping only nudges cuts; placeholder music is basic.

## Subject-aware clipping + review/publish flow
- [x] `Reframer.swift` (shared by highlight clips and Story Shorts): 4 fps Vision analysis (faces + mouth movement, upper bodies, motion, saliency), scene-cut shots, active speaker / fit-everyone / blur-fill fallback, dead-zone + pan-speed smoothing, headroom zoom (≤1.15×) keeping faces above the bottom 20%. Debug preview draws boxes, crop window, caption zone and shot labels.
- [x] Boundaries: `HighlightLogic.normalize` snaps to sentence ends, ≥0.5 s pauses and scene cuts, padded into silence, never mid-word, scored moment always kept whole (only the 3-min limit applies); render snaps edges to cuts within 1 s.
- [x] Review: `UI/ReviewView.swift` (review screen + Review Queue with bulk approve/reject/download/publish). Statuses Needs review → Approved/Rejected → Publishing → Published/Downloaded, or Failed with error + Retry. Persisted (SwiftData; real store migration verified on a copy).
- Publishing: YouTube Shorts wired; Instagram Reels / TikTok are placeholders (`PublishPlatform.swift` lists what each needs).
- Verified on the real GTA trailer (scratch copy): 30 cuts / 31 shots; faces & people tracked, couple + title card → blur fill; clip boundaries never mid-word; Needs review → edit captions/trim → re-render → Approved → Downloaded; YouTube publish correctly blocked by RightsGuard for a foreign-channel test source.
- Known ceilings: dissolves aren't detected as cuts (affected shots may fall back to blur fill); a logo slightly wider than the 9:16 window can be cropped; no true audio-based speaker diarization (mouth movement + speech timing heuristic).

## Fix: letterboxed output + random-looking picks (root causes)
- Letterboxing: motion/saliency boxes are diffuse and wide; the "subject wider than 9:16 → blur fill" rule fired on them, so most non-people shots (all gameplay) fell back to blur. Now motion is an intensity-weighted centroid, gameplay uses a "centre of action" (motion + edge-discounted saliency + centre prior), and blur fill is reserved for several people who can't share the frame. Per-shot reasons logged + shown in Review; per-clip override Smart / Fit with blur / Manual position.
- Random picks: VOD selection was transcript-only (Haiku/Sonnet on text) and the "best N" minimum forced weak picks in. Now `MomentSelection.swift`: 30 s windows every 5 s scored on loudness, audio spikes, motion, scene density, speech energy and Haiku's transcript rating (percentile-ranked, weights in `SelectionConfig`), top 8 → Sonnet vision rating with reason + peak, final = 0.4 signals + 0.6 vision. Stored per clip ("Picked because"), logged, saved as selection.txt/json. Any failure stops the run with the error.
- Live streams still score per window from the transcript (framing fix applies).

## Script & AI Voiceover (review screen, optional per clip)
- [x] `Voiceover/`: `TTSProvider` (ElevenLabs with-timestamps; Apple on-device incl. en-IN/hi-IN), `VoiceoverService` (per-line cache keyed by text+voice+settings, `[m:ss]` markers + auto layout, word timings), `AppModel+Voiceover` (Claude script/shorten with frames, generate → mix → render, per-line retake), `UI/VoiceoverSection`.
- [x] Mix in `ClipService.voiceGraph`: lines via adelay, original keep/duck/mute, optional ducked music, voice volume; captions replace/add (add = upper layer). Voiceover off → render unchanged.
- [x] Verified on a copy of the real GTA source: Claude script → Rishi (en-IN) → render → one-line retake → approve → download; captions match the voice. ElevenLabs tested only against mocked HTTP (no key yet).
- macOS 27 speech engine sends no empty end buffer → completion via delegate didFinish + 60 s timeout; Apple renders serialized.

## Highlight Remix (extends Story Shorts — one engine, `RemixStyle`)
- [x] Styles: story / montage / countdown / funny / recap; formats 9:16, 16:9, 1:1; 15/30/60/90/custom; optional direction prompt.
- [x] Coverage: candidates take the best moment from each of 10 timeline slices first; per-style validation (segment lengths, no source overlap, recap order); per-beat transitions (cut/fade/flash/zoom/whip) + slow-mo; montage beat-snap ≤0.5 s; framing plans cached per segment.
- [x] Output becomes a review-flow clip (local-file Source, ownership confirmed) with a `RemixTimeline` (reorder/drag, trim, remove, swap for another candidate, captions, music, style, re-plan, re-render) — no re-analysis. Voiceover mixes on top of the remix render.
- [x] Real run: 50-min CoD → 30 s 9:16 montage, 13 segments from 3:42–42:18, hook = climax teaser, 12/12 cuts on beats, $0.034, ~10 min.

## Pro Editor (shared style layer)
- [x] `ProEditor/`: `StyleProfile` JSON (10 seeds as package resources; refreshed/reference/user versions saved dated, never overwritten), `EditPlanner` (Auto pick via Haiku, profile guide in planner prompt, senior-editor critique pass with notes, intensity post-pass, grades, punch-ins, SFX cues), `SFXLibrary` (user folder or generated whoosh/hit/riser/pop), `TrendRefresh` (YouTube mostPopular only — no TikTok/IG data, no scraping), `ReferenceAnalyzer` (local cut rate, on-screen text via Vision, punch-ins, color, loudness, BPM → profile).
- [x] Applied in Story/Remix (plan + render) and highlight clips (caption look + pop, grade, punch-in + hit on the peak, filler/pause cuts). Style picker + intensity in Story & Remix, Settings → Pro Editor, and Review (applied style, editor notes, switch + re-render, trending-sound tip).
- Real verification (CoD excerpt, 25 s montage): gaming-fast 16 segments / avg 1.7 s / 9 punch-ins / 10 SFX / hype;
  travel-cinematic 13 / 2.1 s / 1 / 2 / epic; aesthetic-vlog 9 / 2.9 s / 0 / none / chill. ≈ $0.06 per styled edit.
- Fixes from it: plan `notes` sent as a list failed to parse (tolerant decoding); punch-ins were no-ops (`zoom+` doesn't
  accumulate with zoompan d=1 → `pzoom+`); reference cut count used the raw-footage threshold (30 → 8 for finished edits);
  reference/trend answers are merged over a complete base profile; trend refresh only saves versions whose recipe changed;
  placeholder music written atomically; `StyleLibrary.rootOverride` is task-local.
- Known limit: punch-in detection in reference mode is a lower bound — camera motion in fast gameplay hides zooms.

## Vlog Editor (Travel Vlog page)
- Import a folder/files → metadata (capture date via `creationDate`, GPS from any ISO 6709 tag, EXIF for photos) → 540p proxies.
- ShotAnalyzer (cached per file): dark / overexposed / lens-covered / blurry / shaky ranges dropped with a reason, near-duplicate
  takes within 5 min flagged, talking-to-camera detected (speech rate + faces), usable sub-ranges kept.
- ChapterBuilder: split by day, 90-min gaps and >3 km moves; place names via CLGeocoder; files without dates titled by date.
- VlogPlanner: one Sonnet vision call plans the full vlog and/or shorts over shot ids + usable ranges; validated (ids, ranges),
  talking beats snapped to whole sentences, one retry.
- VlogRenderer: per-beat segments from the ORIGINAL footage (cached by content key → crash-safe resume), smart reframing,
  deshake for shaky shots, afftdn on talking, exposure match + vibe grade, photo Ken Burns, MapKit route intro (full vlog),
  separate capped music-bed pass (one track per chapter, crossfaded, ducked under talking), loudnorm (-16 / -14 for shorts).
- Outputs: 16:9 vlog + 9:16 shorts with description incl. YouTube chapter timestamps; Export writes .mp4 + .txt.
- Verified with synthetic footage (end-to-end test). Real trip footage: pending from the user.
- Not done: color matching beyond exposure; ffmpeg-full vidstab opt-in; shorts are files (not in the Review Queue).

## Gameplay visual clipper (in highlight selection)
- `GameplayScanner` (local, free, cached per source): HUD text at 1 fps (Vision OCR; keywords count only when they newly
  appear) + sound events (Apple SoundAnalysis built-in classifier: gunfire, boom, cheering, screaming, …).
- `GenreConfig`: fps / sports / racing / fighting / horror / other — HUD keywords, sound weights and signal weights per genre;
  auto-detected from sound shares + HUD hits, or set in Settings → Pro Editor → Gameplay clipper.
- Two new signals ("hud", "events") join `MomentFinder.windows`; Haiku triage (4 frames + events) of the top 40 windows picks
  the 8 Sonnet rates; Sonnet sees the detected events. "Why this clip" shows the events and the two new bars.

## Channel Stats + hookable titles (read-only)
- Separate sign-in `YouTubeAuth.analytics()`: youtube.readonly + yt-analytics.readonly, own Keychain token. Needs the
  "YouTube Analytics API" enabled in the user's Google Cloud project. Impressions/CTR are not in the API (Studio only).
- `ChannelAnalytics`: channel totals, up to 200 uploads with lifetime analytics, 90-day daily trend, per-video retention,
  Shorts vs long, best publish slots (from past uploads), daily snapshot JSON in Application Support/ClipForge/analytics.
- "What works on this channel": Sonnet compares top vs bottom performers → patterns (also fed to the title writer).
- `TitleWriter`: 5 options by hook type (Sonnet) → separate fact check (Haiku, same evidence + frames); unsupported or
  unchecked options are rejected with a reason and can't be used. Fact-checked options go into the download .txt.

## Upload a video from the Mac
- Toolbar "Upload Video from Mac": any file → YouTube (publishing sign-in), with an explicit rights confirmation recorded in
  the Publish Log. Reads a ClipForge download's .txt for title/description. Both options remain: Download, or upload in-app.
- Real check (50-min CoD campaign video, no transcript in either arm): shortlist Sonnet avg 49 → 56; the weakest old pick
  (empty room, 47) replaced by a trench melee at 49:21. +$0.04 and +131 s local scan. Campaign footage has no kill feed, so the
  gain came from sound events + triage; multiplayer HUDs should add more.

## Theme system (UI only)
- Six themes (Neon Darkroom default, Y2K Chrome, Brutalist, Retro Arcade, Glassmorphism, Minimal/Focus), each with light +
  dark palettes, per-feature signature colors, chart palette, type, radius, border, shadow, effects, motion.
- Settings → Appearance: live theme cards, Theme default / Match system / Light / Dark, accent override, effects Off/Subtle/Full,
  Surprise me. Saved in UserDefaults (no account sync exists).
- Honors Reduce Motion, Reduce Transparency (glass → solid), Increase Contrast, Low Power (heavy effects off).
- WCAG AA verified for every text/background pair in all 12 palettes (ThemeTests). Fonts: Press Start 2P, Space Grotesk,
  Space Mono (SIL OFL, licenses bundled).
- Known limits: the sidebar selection highlight, menus and context menus are drawn by macOS (system accent / theme's
  light-dark appearance); table bodies keep system rows inside themed panels.

## iPhone companion (free Apple ID → Wi-Fi sync)
- iPhone: Review queue, All Clips, clip detail (play, approve, reject, approve & publish, title edit + fact-checked ideas,
  Save to Photos, Share), Channel Stats, Upload a video from Photos (the Mac uploads it), Settings (Appearance, unpair). Themed.
- Mac: Settings → iPhone (toggle, pairing code, paired devices). Heavy work and all secrets stay on the Mac.
- Verified in the iOS Simulator against a real Mac server: Bonjour discovery, pairing, list + thumbnails, approve/reject/title
  round-trips, 28.7 MB video download intact. Not verified on a physical iPhone (needs the user's device + Xcode).
- Not done: on-phone editing (would need an AVFoundation rewrite of the ffmpeg pipeline); iCloud sync (needs a paid account);
  traffic is plain HTTP on the LAN (token-protected, local addresses only).

## Fix: wrong transcripts, slow processing, "stuck on scoring" (root causes)
- Transcripts: (1) Whisper word pieces were trimmed and kept as separate words, losing the "leading space = new word"
  signal ("merry -go -round"); (2) speaker-turn dashes leaked ("- Okay."); (3) base.en mishears. Fixed assembly, dropped
  dashes, default model → large-v3 turbo (632 MB) with silence chunking + 4 workers (~11–14× realtime), pause-based
  sentence repair for unpunctuated runs, transcripts tagged with their model and redone when it changes.
- "Stuck on scoring": nothing was hung — five long steps all showed as Scoring and the text/sound scan never reported
  progress (bar frozen at 50% for minutes). Now each running step shows its own % (incl. transcription via WhisperKit's Progress).
- Slow: everything ran in sequence and the video was decoded 3× plus ~160 seeks, the signals pass on -hwaccel videotoolbox
  (measured 2.3× slower than software here), transcript rated in 4×-overlapping windows one at a time. Now: one decode
  (`VideoScanner`: signals + 1 fps frames + 16 kHz WAV, cached) in parallel with transcription; then text/sound scan
  (parallel OCR), transcript rating (non-overlapping, concurrent) and the watch pass run at once; frames come from the scan.
- "See the video": `VideoWatcher` — Haiku rates the whole video as timestamped 3×3 contact sheets → "watch" signal (weight
  0.30) + labels shown to triage/Sonnet and in "Why this clip".
- Real runs (19-min 1080p AV1 video): 3.5–3.8 min end to end incl. transcription and rendering 3–5 clips, ≈ $0.065.

## Fix: Review edits not showing after re-render (root causes)
- Caption style: whenever a Pro Editor style was active (Auto = always), `ClipLook.captionStyle` came from the profile and
  replaced the style picked in Review, so re-renders kept the old captions. Now the clip's caption style is the source of
  truth: a style sets it when applied (cut / Apply style), Review can change it; the profile's uppercase only applies while
  the clip keeps the profile's own style. Review's picker follows the clip when a style is applied.
- Stale output: every render of the same range overwrote `clip-<start>-<end>.mp4`, so the clip's video path never changed.
  Each render now gets its own file (old video/SRT/framing removed after success), so all views reload.
- Verified on a real 1080p clip: Pop → Boxed → Clean + blur → manual crop + trim → travel-cinematic → no style; each
  re-render produced the change, only the latest file remained.
