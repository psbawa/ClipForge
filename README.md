# ClipForge

ClipForge is a native macOS app that turns your own long videos and live streams into vertical Shorts. It finds the best
moments with Claude, cuts 9:16 clips with burned-in captions, and lets you review, download or publish them to YouTube.
An optional iPhone companion app lets you review and publish from your phone.

> **Bring your own keys.** ClipForge ships with no API keys. Every user creates and pastes in their own
> Anthropic key, Google OAuth client and (optionally) ElevenLabs key. Keys are stored only in the macOS Keychain on
> your Mac — never in files, logs or this repository — and you pay your providers directly for what you use.

## What it does

- **Finds the best moments.** One pass over the video measures loudness, audio spikes, motion and scene cuts;
  Whisper transcribes the speech; Claude reads the transcript, *watches the whole video* as timestamped contact sheets,
  and rates the strongest windows from their frames. Gameplay videos also get on-screen text (kill feeds, "VICTORY")
  and game sounds (gunfire, explosions, cheering) as signals.
- **Cuts real Shorts.** Subject-aware 9:16 reframing, captions that follow the speech, clip edges on sentence and
  scene boundaries.
- **Review before anything is posted.** Review queue, "why this clip", fact-checked title ideas, trim/style/framing,
  approve, reject, download (MP4 + SRT + metadata) or publish.
- **More tools:** Story Shorts and Highlight Remix (a whole video as one edited short), Pro Editor styles, script &
  AI voiceover, a Travel Vlog editor for folders of trip footage, a read-only YouTube Channel Stats dashboard, uploads
  of any video from your Mac, and six UI themes.
- **iPhone companion.** Review, play, approve, publish, save to Photos and see stats on your iPhone. The Mac does the
  work and keeps all keys; the phone talks to it over your local Wi-Fi.

## Use it responsibly

Only process videos and streams **you own or have permission to use**. ClipForge asks you to confirm this for every
source, records it, and refuses to publish sources from channels that aren't yours without a recorded permission.
Downloading is done with `yt-dlp`; make sure your use follows YouTube's Terms of Service and copyright law.
Publishing uses the official YouTube Data API.

## Requirements

- A Mac with **Apple Silicon** and **macOS 14 Sonoma or later**
- **Xcode 26** (to build)
- [Homebrew](https://brew.sh) with **ffmpeg** and **yt-dlp**:
  ```sh
  brew install ffmpeg yt-dlp
  ```
- Your own accounts/keys (next section). The iPhone app needs iOS 17+.

## Build and run

1. Open `Untitled Project 2.xcodeproj` in Xcode.
2. Select the **ClipForge** scheme → *Signing & Capabilities* → choose **your** Team (a free Apple ID works).
3. Run (⌘R). The first transcription downloads the Whisper model (≈ 630 MB) once.

## Set up your own keys

Open **ClipForge → Settings → Accounts** and paste each key. They are saved in your Mac's Keychain.

### 1. Anthropic API key (required)

ClipForge uses Claude (Haiku for fast passes, Sonnet for final ratings).

1. Create an account at [console.anthropic.com](https://console.anthropic.com) and add billing.
2. *API Keys* → **Create Key** → copy it into **Settings → Accounts → Anthropic**.
3. Set a **daily budget** in **Settings → Highlights** — ClipForge stops before spending more. As a rough guide, a
   20-minute video costs a few cents to analyze.

### 2. Google OAuth client (for YouTube publishing and Channel Stats)

Needed only if you want to publish from the app or see Channel Stats. Downloading and clipping work without it.

1. Go to [console.cloud.google.com](https://console.cloud.google.com), create a project.
2. *APIs & Services → Library*: enable **YouTube Data API v3** and (for Channel Stats) **YouTube Analytics API**.
3. *OAuth consent screen*: choose **External**, fill in the app name and your email, and add your own Google account
   under **Test users**.
4. *Credentials → Create credentials → OAuth client ID* → application type **Desktop app**.
5. Paste the **Client ID** and **Client secret** into **Settings → Accounts → Google**, then press **Sign In with Google** (Settings → Accounts → YouTube account).

Scopes requested: `youtube.upload` + `youtube.readonly` for publishing. Channel Stats uses a **separate, read-only**
sign-in (`youtube.readonly` + `yt-analytics.readonly`) that cannot change anything on your channel.
Uploads cost YouTube API quota (≈ 1,600 of the default 10,000 units per day).

### 3. ElevenLabs API key (optional)

For AI voiceovers with ElevenLabs voices. Without it, ClipForge uses the free built-in Apple voices.
Create a key at [elevenlabs.io](https://elevenlabs.io) → paste into **Settings → Accounts → ElevenLabs**.

## iPhone companion (optional)

1. On the Mac: **Settings → iPhone** → turn it on.
2. In Xcode choose the **ClipForge Mobile** scheme, select your Team, plug in your iPhone and Run. On the phone,
   enable Developer Mode (Settings → Privacy & Security) and trust your developer profile
   (Settings → General → VPN & Device Management).
3. Open the app, pick your Mac, and enter the 6-digit code shown under **Pair iPhone…** on the Mac.

Notes: both devices must be on the same Wi-Fi and ClipForge must be open on the Mac. The Mac only accepts local
network connections from paired phones (a random token per phone; the Mac stores only a hash). Traffic is local HTTP,
so prefer your home network over public Wi-Fi. With a free Apple ID, apps installed from Xcode expire after 7 days —
run again from Xcode to renew.

## Development

```sh
cd ClipForgeKit
xcodebuild test -scheme ClipForgeKit-Package -destination 'platform=macOS'
```

- `ClipForgeKit/Sources/ClipForgeKit` — the Mac engine and UI (selection, rendering, publishing, editors)
- `ClipForgeKit/Sources/ClipForgeShared` — themes, shared models and the companion protocol (macOS + iOS)
- `ClipForgeKit/Sources/ClipForgeMobile` — the iPhone companion
- `ClipForge/`, `ClipForgeMobileApp/` — the two app targets
- `PLAN.md`, `CLAUDE.md` — design notes and how each feature was built and verified

Never commit keys: they belong in the Keychain via the Settings screen. `.gitignore` also excludes common
secret files (`*.env`, `client_secret*.json`, …).

## Third-party

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) (MIT) for on-device speech recognition
- Fonts: Press Start 2P, Space Grotesk, Space Mono — SIL Open Font License 1.1 (licenses in
  `ClipForgeKit/Sources/ClipForgeShared/Theme/Fonts`)
- ffmpeg and yt-dlp are installed separately by you via Homebrew and are not bundled.
