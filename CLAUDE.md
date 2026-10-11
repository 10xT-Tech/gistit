# EnglishHelper (ships publicly as **Gist It**)

Personal-use iOS app for living in a studied language (six languages, configurable studied/native
pair; originally EN-from-RU). Five tabs: **Say it** (thought → 3 phrasings / situation → phrases),
**Get it** (Translate / Explain / **Online** — a live interpreter that listens to surrounding speech
and translates it in real time via Soniox), **See it** (photo → explain or translate), **Study**
(flat list, exported to AlgoApp/Anki), **History** (every request; live sessions keep their audio;
swipe-to-delete). Curated phrases go into the study list for the external SRS app.

- iOS 26 · Swift 6 · SwiftUI · Xcode 27 (iOS 27 SDK; deployment target stays iOS 26) · SwiftData (persistence) · async/await + actors.
- Online-first; the LLM is Claude (Sonnet 5.5 / Haiku 5.5) via the Anthropic API; live speech translation is
  Soniox `stt-rt-v5` over WebSocket.
- Monochrome "Liquid Glass" design system; system colors are functional signals only.

## Architecture — Clean Architecture, dependency rule strictly inward

Each layer is a **separate framework module**, so the compiler enforces the dependency rule
(Domain literally cannot import an outer layer):

```
            ┌───────────────┐
            │     App       │  composition root · DI · @main · AppConfig
            └──────┬────────┘
        ┌──────────┼───────────┬──────────────┐
        ▼          ▼           ▼              ▼
   Presentation   Data    DesignSystem     (Domain)
        │          │           │
        ├──► Domain ◄──────────┘ (Presentation→Domain, Data→Domain)
        └──► DesignSystem
```

- **Domain** — entities, port protocols, prompt-template definitions, use cases. Foundation ONLY;
  zero platform/UI/transport frameworks (enforced by `ForbiddenImportTests`).
- **Data** — adapters implementing Domain ports: live adapters (`Adapters/`, `Persistence/`) plus
  `Mock*` / `Stub*` doubles (`Mocks/`, `Stubs/`).
  Folder is `Data/`; the **Swift module is named `Adapters`** (a module named `Data` would shadow
  `Foundation.Data` in every consumer) — so import it as `import Adapters`.
- **DesignSystem** — `Tokens.swift` (single source of truth) + components built on it. No Domain dep.
- **Presentation** — SwiftUI views + MVVM view models. Consumes **use cases** only.
- **App** — the only place that knows concrete adapters; wires the graph and injects use cases.

### Ports (Domain) → adapters (Data)
`LLMClient`, `SpeechRecognizing`, `SpeechSynthesizing`, `TextRecognizing`, `LiveTranslating`
(live mic→cloud interpreter stream) + `SessionRecordingsManaging` (stored session audio),
`TranscriptionServiceChecking` (Soniox health probe), `ExpressionRepository`, `HistoryRepository`
(append/recent/delete), `TranslationCache`, `DeckExporting`, `AnalyticsTracking`. The media ports
are backend-agnostic (on-device OR cloud) and leak no SDK/transport types.

### Prompt templates (Domain)
`PromptTemplate` owns a system prompt + output JSON schema + typed decoder. Templates (all in
`Domain/Prompts/Templates.swift`): `howToSay` (3 variants), `whatToSay`, `explainExpression`,
`understand`, `photoBlocks`, `photoExplain`, `enrichCard`, `healthCheck`. Adding a use case = adding
a template; the LLM adapter never changes.

## Folder layout

```
Domain/          Entities · Ports · Prompts · UseCases · DomainErrors
Data/            Adapters/ · Persistence/ · Mocks/ · Stubs/   (compiled as the `Adapters` module)
DesignSystem/    Tokens.swift · Loc*.swift · Components/
Presentation/    Root/ · Voice/ · In/ · Photo/ · Library/ · History/ · Settings/ · Onboarding/ · Support/
App/             EnglishHelperApp · AppContainer (DI) · AppConfig · Info.plist · Assets.xcassets
Shared/          code compiled into both the app and LockWidgets
LockWidgets/ · ShareExtension/   extension targets
Tests/ · UITests/   unit tests (incl. ForbiddenImportTests, DIBootTests) · XCUI suite
Backend/         AWS Lambda (Node, SAM): Claude proxy + Soniox temp keys behind App Attest — see Backend/README.md
Config/Base.xcconfig   project.yml   Secrets.example.xcconfig
design_system/   archived design handoff bundle (HTML/CSS/JSX) — NO LONGER the source of truth
docs/            RUN.md + prompts 00–02
```

## Build & run

The Xcode project is generated from `project.yml` (it is gitignored).

```sh
cp Secrets.example.xcconfig Secrets.xcconfig   # then fill in CLAUDE_API_KEY (first time only)
brew install xcodegen                          # if needed
xcodegen generate
xcodebuild -scheme EnglishHelper \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' build
open EnglishHelper.xcodeproj                    # or ⌘R in Xcode
```

Tests: `xcodebuild test -scheme EnglishHelper -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0'`
(unit tests only — fast). The XCUI suite is a separate, slow scheme:
`xcodebuild test -scheme EnglishHelperUITests -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0'`

## Config & secrets
`AppConfig` reads `CLAUDE_MODEL` (+ optional `CLAUDE_FAST_MODEL`, `SONIOX_MODEL` — defaults to
`stt-rt-v5`, `AMPLITUDE_API_KEY` — analytics, Amplitude project "GistIt", EU data center, `SENTRY_DSN` — crash reporting, Sentry project `10xt/gistit`, started first in `EnglishHelperApp.init`). Both are split by build channel: `AppDistribution` (Data) resolves `production` (App Store) / `testflight` / `local` (Xcode: DEBUG, Simulator or a build with `embedded.mobileprovision`) → Sentry `environment` + release `bundle@version+build`; Amplitude event + user properties `environment`, `app_build` (`app_version` comes from the SDK). It also reads the credentials from the app's Info.plist,
populated at build time from `Secrets.xcconfig` (gitignored; layered in via `Config/Base.xcconfig`
with `#include?`). Two credential modes:
- **`BACKEND_URL` set (production):** Claude goes through our backend (`Backend/`, same
  `/v1/messages` path) and Soniox gets a single-use temporary key per WebSocket. The app proves
  itself with App Attest (`Data/Adapters/Backend/BackendSession.swift`; key id in UserDefaults).
  No third-party key is in the app.
- **Otherwise (development):** `CLAUDE_API_KEY` / `SONIOX_API_KEY` are used directly. They are
  extractable from a built app, so **Release builds blank them** (`Config/Base.xcconfig`
  `[config=Release]` overrides) — a Release build without `BACKEND_URL` has no live Claude/Soniox.
**Subscription (App Store version only).** One monthly auto-renewable product
(`AppConfig.subscriptionProductID`). Free plan, by SCENARIO not model: translations (Get it/See it →
Translate, card enrichment) unlimited; explanations + Say it share 1 request / 5 min; no Online mode.
Subscribers and every TestFlight / Xcode build: unlimited, no paywall. The backend recognises
translations by their system prompt's fixed opening — changing the first sentence of
`UnderstandTemplate` / `PhotoBlocksTemplate` / `EnrichCardTemplate` must be mirrored in
`Backend/src/validate.mjs` (`SubscriptionTierTests` pins it). The **backend enforces
it** (tier in the session token from StoreKit JWS — see Backend/README.md "Access tiers"); the app
mirrors it for UX: Domain port `SubscriptionManaging` + `AccessTier`; Data
`StoreKitSubscriptionService` (finishes `Transaction.updates`, sends `EntitlementProofs` to
`BackendSession`, which re-opens its session on any plan change); Presentation `SubscriptionState`
(environment) + `PaywallView` (StoreKit `SubscriptionStoreView`, `AppUIState.showPaywall`). A plan
refusal is `LLMError.subscriptionRequired(retryAfter:)` / `LiveTranslationError.subscriptionRequired`;
request screens then show "Subscribe" instead of Retry (`needsSubscription`).
`HealthCheckTemplate` must keep its exact shape (backend `isHealthCheck` exempts it). DEBUG launch
argument `-simulateAppStore` shows the free-plan UI in an Xcode build.
`BACKEND_DEV_TOKEN` is a DEBUG-only Simulator escape hatch (App Attest doesn't run there); never
read in Release. Credentials reach the adapters as `RequestAuthorizing` (Claude) and
`SonioxCredential` (Soniox) — the adapters don't know which mode they're in.

## Current Status

**v1.5.0 (2026-10-11) — Gist It Pro subscription, backend proxy (App Attest), Amplitude + Sentry
split by build channel (`AppDistribution`), structured outputs, `VerticalScrollView`.** User-facing
notes are in `CHANGELOG.md`. 215/215 tests green.

**Xcode 27 / iOS 27 SDK readiness (2026-09-15).** Builds + 208/208 tests green on Xcode 27 (iOS 27.0
simulator). iOS 27 SDK hard requirements already met: scene-based lifecycle (SwiftUI `App`),
`UILaunchScreen`, `TabView` selection always names an existing tab. Changes made for it: every view that
takes a view model in `init` now assigns the wrapped property directly (`self.model = model`, no default
value at the `@State` declaration) — Apple's documented form for the macro-based `@State` in Xcode 27;
never write `_model = State(initialValue:)` again. `PrivacyInfo.xcprivacy` added to EVERY bundle that
touches `UserDefaults` (app: CA92.1 + 1C8F.1 App Group; ShareExtension: 1C8F.1; Presentation /
Adapters / DesignSystem frameworks: CA92.1) — xcodegen picks them up as resources automatically; a new
required-reason API (file timestamps, disk space, boot time…) needs a new entry there. `LastUpgradeCheck`
pinned to 2700. Simulator names are ambiguous across runtimes now — pass `OS=27.0` or a device id.

**v1.4.3 — Lock Screen Live Activity for Online sessions + Explain parse fix.** A running Online
session is mirrored as an ActivityKit Live Activity (banner + Dynamic Island: record indicator,
direction label, timer, Pause/Stop). `InViewModel` talks to a `LiveSessionActivityPresenting` port
(Presentation/Support/LiveSessionActivity.swift); `LiveTranslationActivityController` (App) is the
only ActivityKit user; `Shared/LiveTranslationActivity.swift` (attributes + `LiveActivityIntent`s)
is compiled into BOTH the app and LockWidgets — the intents run in the app process and post
`liveTranslationPauseCommand` / `liveTranslationStopCommand` notifications (names duplicated as
literals in the Shared file — keep in sync). Info.plist: `NSSupportsLiveActivities`. Stale banners
are cleared at boot. LLM output is schema-constrained via structured outputs (`output_config.format`), so
responses are always valid JSON for the template's schema. Study: **Clean up** toolbar button (eraser, next to +) → `confirmationDialog` →
`StudyListViewModel.cleanUpLearned()` bulk-deletes learned cards (optimistic; reload + actionError
on any failed persisted delete). Paste slot (Say it + Get it): `UIPasteboard.changedNotification` is NOT
posted for other-process changes while the app is foreground (Universal Clipboard etc.), which left
a greyed-out `UIPasteControl` and no Explain/Translate — `monitorClipboard()` (1 s `hasStrings`
metadata poll bound to the screen via `.task`) keeps `clipboardHasText` honest; XCUI
`PasteAffordanceUITests` covers both directions. 208/208 tests green. v1.4.2 (2026-08-15) shipped the system Paste control, per-mode See it
result cache, the Disk-usage card, and multilingual button-label fixes.

**v1.4.1 — Online translation (live interpreter).** "Get it" gained a third mode, **Online**: a
Listen TOGGLE (pill with a live sound diagram) streams the mic (AVAudioEngine → AVAudioConverter →
16 kHz mono pcm_s16le, ~120 ms binary chunks) to Soniox `stt-rt-v5` over
`wss://stt-rt.soniox.com/transcribe-websocket` with built-in one_way translation into the native
language; the recommended low-latency endpointing config is on. Control row: **Pause**
(engine.pause + keepalives every ~10 s — the socket stays warm, resume is instant; `LiveMicActivity`
flags the held mic so History playback refuses politely instead of stealing the session), a
**direction toggle** (default studied→native, session-scoped; mid-session it sends
`{"type":"finalize"}`, waits for `<fin>` (2 s cap), ROTATES the socket with swapped languages, and
`insertBoundary()` draws a divider in both transcripts — same session/recording), and **New**
(graceful stop → saved to History, screen cleared; drain-tail updates are discarded). Both panes
have copy buttons. Final tokens append, non-final
tokens REPLACE, and `<end>`/`<fin>` utterance markers start a new PARAGRAPH in both transcripts
(pure `SonioxTokenAccumulator`, unit-tested). Two synced auto-scroll panes
(recognized 4-line pane + translation pane on the remaining height; bottom-stick with pause-on-
scroll-up, proportional cross-sync via `onScrollGeometryChange`/`onScrollPhaseChange`).
Sessions record AAC audio (Application Support/SessionRecordings), keep listening in the background
(`UIBackgroundModes: audio`), auto-stop after 5 min of silence, survive interruptions (call → clean
stop+save), and land in History as `RequestResult.liveTranslation(original:ru:audioFileName:duration:)`
— JSON-blob persistence, so NO schema migration. History: swipe-left delete
(`HistoryRepository.delete` + audio-file cleanup in `RequestHistoryInteractor`; pruning also deletes
orphaned audio) and in-detail playback (`SessionRecordingsManaging`). New Domain ports:
`LiveTranslating`, `SessionRecordingsManaging`; new use case `LiveTranslateInteractor` (saves the
session best-effort, even on a mid-session failure). Soniox key + Settings health row landed in the
same release. 175/175 tests green. **The live streaming path needs on-device verification** (mic +
real WebSocket; the Simulator run only proves UI/wiring).

**Notes / trade-offs** (v1 build history: `docs/02-v1-development.md`, `CHANGELOG.md`):
- **Speech recognition:** iOS 26 `SpeechAnalyzer`/`SpeechTranscriber` has NO on-device Russian model
  (`AssetInventory.status` = `.unsupported`), so `NativeSpeechRecognizer` uses `SFSpeechRecognizer`
  (server-backed, needs network). Engine swap = one line in `AppContainer.bootLive`.
- **Liquid Glass vs readability:** all glass goes through `glassPanel`, which swaps to a SOLID
  surface under Reduce Transparency; `MicButton` rings/`symbolEffect` disable under Reduce Motion.
- **Iconography:** using SF Symbols (the design's icon names were SF-Symbol-style) for native
  Dynamic Type + VoiceOver + variable-color effects, rather than porting the custom thin-line set.
- **Save = sticky toggle in Voice:** bookmark saves (enrich→store) / unsaves (delete); no per-card
  spinner during the enrich call yet.
- `NativeSpeechRecognizer` compiles against the real iOS 26 API but its live mic→STT path needs
  on-device verification (no mic in CI); the stream contract is covered by `Stub*`.
- `XMLDocument` is macOS-only → the exporter uses a dedicated escaping `XMLWriter` + `XMLParser` validation.
- SDK name collisions handled by qualification: `Domain.Expression` vs `Foundation.Expression`,
  `Domain.RecognizedText`/`NormalizedRect` vs Vision's; Data layer module is `Adapters` (not `Data`).
