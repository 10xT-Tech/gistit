# Gist It

**Not just a translator — a companion for actually living in another language.**

A word-for-word translator answers one narrow question: *what does this mean?* But being dropped into
a language — as a traveller, an expat, or anyone studying in an immersion setting — throws harder
questions at you all day: *What is this sign telling me? Did I understand that correctly? How do I say
this without sounding like a phrasebook?* Gist It turns your phone into a quiet assistant for
exactly those moments. It **reads the world around you**, **explains what things really mean** (not
just their dictionary gloss), and **hands you natural ways to say what you want** — then quietly
remembers the phrases worth keeping, so the language you meet in the wild becomes the language you
actually learn.

Built originally for learning **English from Russian**; the studied and native languages are now
configurable, so it works between any pair of the six supported languages.

- **Platform:** iOS 26 · Swift 6 · SwiftUI · SwiftData · async/await + actors · Xcode 27 (iOS 27 SDK, deployment target iOS 26)
- **Powered by Claude** (Anthropic Messages API) — online-first.
- **Design:** monochrome "Liquid Glass"; color is reserved for functional signals (success / error / warning).

See `CLAUDE.md` for the full architecture map and `CHANGELOG.md` for release history.

---

## Why it's more than a translator

Living in a language is three problems, not one — and the app is built around exactly those three.
Each is a tab, and each works whether you're online at a café or you just need a quick answer on the
street:

- 👁️ **See it — read the world.** You can *see* the words but not understand them. Point the camera
  (or pick a photo) at a **sign, menu, label, or page**; the text is recognised and the translation is
  drawn right over the image, where it is. Tap any phrase to have it **explained** in plain language,
  or saved.
- 🧠 **Get it — understand what reached you.** You *heard* or *read* something and want to be sure.
  Type it, or **dictate** it in the language you're learning. **Translate** gives a faithful meaning;
  **Explain** tells you what it *really* says — how formal or blunt it sounds, when people actually use
  it, and a familiar comparison so it clicks. And when the language is coming at you faster than you
  can type — a lecture, a counter clerk, a tour guide — **Online** just listens and translates the
  room in real time, both transcripts scrolling live.
- 💬 **Say it — put words in your mouth.** You need to *speak*. Say or type the thought in your own
  language and get **three natural phrasings** to choose from. Or describe the **situation** —
  "ordering coffee", "apologising for being late", "haggling at a market" — and get the handful of
  phrases that situation actually calls for. Pick a **tone** (Polite / Casual / Slang) to match the room.

Every result can be **spoken aloud** in the language you're studying — so you can hear it before you
say it — and any phrase worth keeping is **one tap** from your personal study list.

---

## What it does

On first launch a short **onboarding** lets you pick three languages — **interface**, **studied** (the
one you're learning), and **native** (the one translations and explanations come in). All three are
changeable later in Settings. Then the app opens on five tabs:

| Tab | What it's for |
|---|---|
| **Сказать / Say it** *(center, default)* | Speak or type a thought in your native language → get **3** natural phrasings ("How to say"), or describe a **situation** → get the 3–10 most useful phrases for it ("What to say"). Pick a tone (Polite / Casual / Slang); tap a card to hear it; bookmark to save. |
| **Понять / Get it** | Type or dictate an expression in the studied language. **Translate** gives a faithful meaning; **Explain** breaks down what it means, how formal or blunt it sounds, where it's used, and a familiar comparison. **Online** turns the phone into a live interpreter: tap **Listen** and surrounding speech is recognized and translated in real time — recognized text in a small pane, the running translation in a big one, both auto-scrolling (scroll up to re-read; grab the bottom to re-engage) and copyable. **Pause** mutes the session instantly; the **direction switch** (EN | RU) flips who is being translated — mid-session it draws a divider and continues. Every session is saved to History with its audio. |
| **Смотреть / See it** | Point the camera (or pick a photo) at a sign, menu, or page → on-device text recognition → translation drawn over the image. Explain or save any phrase from the result. |
| **Изучаю / Study** | Your flat study list. Add manually, mark learned, swipe to delete, and **export to AlgoApp** (your SRS app) via the system share sheet. |
| **История / History** | A chronological log of every request; tap an entry to see the full result, replay it, copy, or explain. Live-translation sessions keep their **original audio** for playback. Swipe left to delete an entry (a session's recording is deleted with it). |

A **Settings** sheet (gear, top-right of every screen) covers a live Claude connection check, the
three language pickers, the appearance theme, and app/model info.

### Little things that make it feel like an assistant

- **Hear it before you say it.** Every phrase plays back in the studied language with one tap.
- **Save the keepers.** Bookmark any card; it lands in **Study** and exports to your SRS app.
- **Walk away during a long request.** Leave the app mid-recognition or mid-explanation and get a
  **notification** the moment the result is ready.
- **Instant, offline repeats.** Ask for the same translation or phrasing again and it comes straight
  from an on-device **cache** — no wait, no connection needed. (Asking for *fresh* variants still
  goes to Claude.)
- **One tap from the Lock Screen.** Seven **widgets**, one per scenario, deep-link straight into the
  app with the **camera ready** (See it), the **mic already listening** (Get it / Say it), or a
  **live-translation session already running** (Get it · Online).
- **Share a photo straight in.** Send an image to Gist It from Photos or any app to translate it.
- **Light / dark / system** theme, and a live check that Claude is reachable.

### Supported languages

Russian · English · French · Spanish · German · Italian — available for the **interface**, as the
**studied** language, and as the **native** language (translations / generation / explanations / speech).

### Under the hood

Language work runs on **Claude Sonnet 5.5** for everything but plain translation, which uses the faster
**Claude Haiku 5.5** tier for speed; you can override the model per scenario in Settings. Push-to-talk
dictation and all speech playback run **on-device**; the **Online** live interpreter streams 16 kHz
PCM over a WebSocket to **Soniox** (`stt-rt-v5`), whose real-time model recognizes AND translates in
the same stream (partial tokens render instantly; sessions auto-stop after 5 minutes of silence and
keep listening in the background). The app is online-first — it needs a connection to reach Claude —
but cached translations and saved phrases stay available offline.

---

## Architecture — Clean Architecture

Each layer is a **separate Swift framework module**, so the compiler enforces the dependency rule
(the dependency arrow only ever points inward):

```
            ┌───────────────┐
            │     App       │  composition root · DI · @main · AppConfig
            └──────┬────────┘
        ┌──────────┼───────────┬──────────────┐
        ▼          ▼           ▼              ▼
   Presentation   Data    DesignSystem     (Domain)
        │          │           │
        ├──► Domain ◄──────────┘   (Presentation→Domain, Data→Domain)
        └──► DesignSystem
```

- **Domain** — entities, port protocols, prompt templates, use cases. Foundation only; no platform/UI/transport frameworks (enforced by `ForbiddenImportTests`).
- **Data** — adapters implementing the Domain ports (`ClaudeLLMClient`, native Speech/Vision adapters, `SonioxLiveTranslator` — the live mic→WebSocket interpreter with session recording, SwiftData repositories, AlgoApp exporter). Compiled as the **`Adapters`** module (a module named `Data` would shadow `Foundation.Data`).
- **DesignSystem** — `Tokens.swift` (single source of truth) + components built on it; also hosts the runtime localizer (`Loc` / `LocCatalog`).
- **Presentation** — SwiftUI views + MVVM view models; consumes **use cases** only.
- **App** — the only place that knows the concrete adapters; wires the graph and injects use cases.

Each LLM use case is a **prompt template** in Domain (system prompt + strict output JSON schema +
typed decoder), so adding a feature means adding a template — the LLM adapter never changes.

---

## Build & run

The Xcode project is generated from `project.yml` (the `.xcodeproj` is gitignored).

> **Public vs. internal name.** The app ships publicly as **Gist It** (its display name / App Store name).
> The Xcode project, scheme, module, and bundle identifier keep the original internal name
> **EnglishHelper** — so the commands below and the paths in *Project layout* still reference `EnglishHelper`.

```sh
cp Secrets.example.xcconfig Secrets.xcconfig   # first time only — then fill in CLAUDE_API_KEY
brew install xcodegen                           # if needed
xcodegen generate
open EnglishHelper.xcodeproj                     # or ⌘R in Xcode
```

Build / test from the CLI:

```sh
xcodebuild -scheme EnglishHelper -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcodebuild test  -scheme EnglishHelper        -destination 'platform=iOS Simulator,name=iPhone 17 Pro'  # unit tests (fast)
xcodebuild test  -scheme EnglishHelperUITests -destination 'platform=iOS Simulator,name=iPhone 17 Pro'  # XCUI suite (slow; drives the real app on stubs)
```

> The live mic→speech path and the camera capture path are **device-only** (no mic/camera on the
> Simulator; the camera button is hidden there).

### Security note

`AppConfig` reads `CLAUDE_API_KEY`, `CLAUDE_MODEL`, and `SONIOX_API_KEY` (the Online live
interpreter; omit it and the mode simply shows a "no key" banner) from the app's Info.plist,
populated at build time from `Secrets.xcconfig` (gitignored; layered in via `Config/Base.xcconfig`
with `#include?`). The base URL defaults to `https://api.anthropic.com`; the model defaults to
`claude-sonnet-5-5` (fast tier: `claude-haiku-5-5`). **A key embedded in a built app is extractable** — so for any
build that leaves your hands set `BACKEND_URL` instead (see [`Backend/README.md`](Backend/README.md)): the AWS
backend holds the keys and the app authenticates with App Attest; Release builds strip the direct keys. Direct keys are
fine for personal/dev builds only.

---

## Swapping an engine (one line)

Every backend is wired in exactly one place — the composition root, `App/AppContainer.swift`,
`bootLive(config:)`. The Domain and Presentation layers never learn which backend is wired, so
swapping an engine touches exactly ONE registration line:

```swift
speechRecognizer:  NativeSpeechRecognizer(localeProvider: …),   // ← swap ASR engine here
speechSynthesizer: NativeSpeechSynthesizer(localeProvider: …),  // ← swap TTS engine here
textRecognizer:    VisionTextRecognizer(),                      // ← swap OCR engine here
liveTranslating:   SonioxLiveTranslator(apiKey: …),             // ← swap live-interpreter engine here
```

To move speech recognition to a cloud ASR, change only the first line — no other file changes,
because `SpeechRecognizing` already models streaming `(text, isFinal)` + cancellation
backend-agnostically. The deck **export mapping** (recognition vs production) is likewise a one-line
default in `AlgoAppXMLExporter(mapping:)`.

## Testing the cloud path before a cloud backend exists

Each engine port ships a `Mock*` (instant, happy) **and** a `Stub*` (latency + failure) in
`Data/Stubs/`, so slow/flaky cloud behavior is testable today —
`StubLLMClient(behavior: .timeout)`, `StubSpeechRecognizing(behavior: .failure(.permissionDenied))`,
etc.

---

## Project layout

```
Domain/          Entities · Ports · Prompts · UseCases · DomainErrors
Data/            Adapters (live) + Mocks/ + Stubs/   (compiled as the `Adapters` module)
DesignSystem/    Tokens.swift · Loc.swift · LocCatalog.swift · Components/
Presentation/    Root · Onboarding · Voice (Say it) · In (Get it) · Photo (See it) · Library (Study) · History · Settings · Support
App/             EnglishHelperApp · AppContainer (DI) · AppConfig · Info.plist · Assets
Tests/           ForbiddenImportTests · DIBootTests · use-case / view-model / adapter tests
Config/          Base.xcconfig · Secrets.example.xcconfig
docs/            RUN.md + build-order notes
CHANGELOG.md     user-facing release notes
```

---

## Status

**v1.5.0 (build 5)** — **Gist It Pro + backend + new telemetry.** One monthly auto-renewable
subscription. On the free plan translation stays unlimited, explanations and Say it share 1 request
per 5 min, and Online is subscription-only. The backend enforces it from the StoreKit JWS, and the
app mirrors it with `SubscriptionState` + `PaywallView` (StoreKit `SubscriptionStoreView`). Claude
and Soniox now go through our AWS backend behind App Attest (`Backend/`), and Release builds carry no
third-party keys. LLM output uses structured outputs (`output_config.format`). Analytics moved from
TelemetryDeck to Amplitude (EU), Sentry crash reporting was added (project `10xt/gistit`), and both are
split by build channel (`AppDistribution`: production / testflight / local). All page scrolling goes
through `VerticalScrollView` (no sideways drift). Built with the iOS 27 SDK. Previously, in v1.4.3:
**The live session on the Lock Screen + a See it → Explain fix.** A running
Online session now shows as a **Live Activity** (Lock Screen banner + Dynamic Island): pulsing record
indicator, direction label, self-ticking timer, and **Pause** / **Stop** buttons that run as
`LiveActivityIntent`s inside the app process (alive thanks to the audio background mode), so they
work without unlocking. `InViewModel` drives a `LiveSessionActivityPresenting` port (spy-tested);
the ActivityKit controller lives in App; the attributes/intents file is compiled into BOTH the app
and the LockWidgets extension. Separately, **See it → Explain** failed on every photo whose
explanation ran to several paragraphs: the model put raw line breaks inside a JSON string and the
strict decoder rejected the answer. `decodeJSON` now runs `JSONSanitizer` first (escapes control
characters inside string literals only — a no-op on valid JSON) and the shared plain-text prompt
rule asks for `\n` escapes. Study also gained a **Clean up** toolbar button (eraser, next to +):
after a confirmation dialog it bulk-deletes every card marked learned (`cleanUpLearned`, optimistic
with reload-on-failure). Previously, in v1.4.2: the **Paste** button became the system paste
control (no "Allow Paste?" dialog), See it keeps each mode's result per photo, Settings got a
**Disk usage** card, and button labels were fixed across all six languages. Previously, in
v1.4.1: **Online: a live interpreter inside Get it.** A third mode listens to the
speech around you and translates it in real time: tap **Listen** (a toggle with a live sound
diagram) and the recognized speech streams into a small pane while its translation runs in the big
one — partial words render instantly and firm up as Soniox (`stt-rt-v5`, one WebSocket stream for
recognition AND translation) commits them. Both panes auto-follow the newest text, pause when you
scroll up, re-engage at the bottom, scroll each other proportionally, break into paragraphs at
speech pauses, and are copyable. The control row: **Pause** (instant mute/resume — the connection
stays warm on keepalives), **Listen**, and a **direction switch** (two positions, the live-green
highlight marks the language being heard; studied→native by default — flipping mid-session
finalizes the tail, draws a divider in both transcripts, and rotates the stream to the reversed
language pair, same session, same recording).
Sessions keep listening in the **background**, auto-stop after **5 minutes of silence**,
and each one is saved to **History** with its original **audio recording** (playable from the
Request card of the entry; History rows are now swipe-to-delete, which also removes the audio). The mic pill was redesigned into the same capsule
form as the action buttons, and photo recognition errors now offer **Retry**. New in the stack: a
backend-agnostic `LiveTranslating` Domain port, the `SonioxLiveTranslator` adapter (16 kHz PCM
chunks, silence watchdog, interruption-safe, AAC session recording), and a `SessionRecordings`
store. Previously, in v1.3.3: voice input became **push-to-talk**: capture runs while the mic button is
held (press haptic + the standard iOS record chimes around the actual recording, sequenced in the
speech adapter so the beep is never captured); a deliberate release stops and submits, while a
SYSTEM touch-cancel (call / permission alert / scroll steal / backgrounding) stops WITHOUT firing a
request. The widget deep-link flow keeps its hands-free auto-listen; VoiceOver degrades to a
tap-toggle. The Get it action button also doubles as **Paste** while the field is empty and the
clipboard holds text (metadata-only check; the clipboard is read solely on the explicit tap).
Previously, in v1.3.2: **anonymous product analytics** via TelemetryDeck behind a Domain
`AnalyticsTracking` port (closed no-payload event enum — no PII by construction; SDK confined to
the Adapters module and off entirely when no App ID is configured). In v1.3.1:
the app now ships publicly as **Gist It** (renamed from EnglishHelper);
Lock Screen widgets (one per scenario, deep-linking straight into the camera or a live mic), an
offline translation cache with reuse stats, per-scenario model choice, the standard tier upgraded
to **Claude Sonnet 5**, and per-screen state preservation across tab switches (results, input,
mode, tone — covered by an XCUITest suite). The LLM path now **streams** (bounded time-to-first-byte
+ idle-bounded chunks, per-attempt reachability re-checks), the SwiftData store opens **off the main
thread** behind the launch screen, and routed actions (widgets / Share sheet / "Explain" buttons)
never overwrite the user's saved screen modes. Builds and runs on iOS 26.
