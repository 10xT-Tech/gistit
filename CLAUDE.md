# EnglishHelper (ships publicly as **Gist It**)

Personal-use iOS app for living in a studied language (six languages, configurable studied/native
pair; originally EN-from-RU). Five tabs: **Say it** (thought → 3 phrasings / situation → phrases),
**Get it** (Translate / Explain / **Online** — a live interpreter that listens to surrounding speech
and translates it in real time via Soniox), **See it** (photo → explain or translate), **Study**
(a learning dashboard + in-app **flashcards** with FSRS spaced repetition (Pro); saved phrases — and
cards generated from a phrase or caught from photos — wait in **Caught** until moved into flashcards;
export to AlgoApp/Anki), **History** (every request;
live sessions keep their audio; swipe-to-delete).

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
`TranscriptionServiceChecking` (Soniox health probe), `ExpressionRepository`, `ReviewCardRepository`
(flashcard SRS state), `HistoryRepository` (append/recent/delete), `TranslationCache`, `DeckExporting`,
`AnalyticsTracking`, `SubscriptionManaging`. The media ports
are backend-agnostic (on-device OR cloud) and leak no SDK/transport types.

### Prompt templates (Domain)
`PromptTemplate` owns a system prompt + output JSON schema + typed decoder. Templates (all in
`Domain/Prompts/Templates.swift`): `howToSay` (3 variants), `whatToSay`, `explainExpression`,
`understand`, `photoBlocks`, `photoExplain`, `enrichCard`, `photoCards`, `fixCards`, `dedupeCards`, `healthCheck`. Adding a use case = adding
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
**Subscription (App Store + TestFlight).** One monthly auto-renewable product
(`AppConfig.subscriptionProductID`). Free plan, by SCENARIO not model: translations (Get it/See it →
Translate, card enrichment) unlimited; explanations + Say it share 1 request / 5 min; no Online mode,
no flashcards (on-device, so the APP is the only gate: `AccessTier.canUseFlashcards`).
Subscribers and Xcode builds (`AppDistribution.local`): no paywall; the backend still caps every device
at 20 model requests/min and per UTC day 500 (free) / 3000 (pro, beta) — a spent day is
`LLMError.dailyLimitReached(retryAfter:)` (backend 429 `daily_limit`, never retried; the message says when
it resets). TestFlight shows the
REAL plan + paywall because App Review runs in the same sandbox and can't be told apart — 1.5.3 was
rejected (2.1(b)) when the reviewer saw an unlocked "test build"; testers subscribe for free. The
backend still treats sandbox as `beta`, so TestFlight explanations aren't metered (only the app's
Online gate applies). The backend recognises
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

**v2.0.0 (in development, branch `feat/2.0.0-flashcards`) — Study dashboard, Caught,
flashcards.** Saving (Say it / Get it / See it) stores an `Expression` = **Caught** (`StudyListView` +
`StudyListViewModel`, scope `.caught`, pushed from the dashboard; swipe-left delete, swipe-right or the
stack icon → `FlashcardsUseCase.enroll`, "Move all" → enroll every one, oldest first, list empties).
"+" = Generate from a phrase (`EnrichCardTemplate`, now `.fast` = the translation model) or From
photos (`PhotosPicker` ≤10 → `ImagePreparation` → `CatchCardsFromPhotosInteractor`: ONE request per
photo — the backend allows one image — via `PhotoCardsTemplate`, skipping already-saved expressions;
a bad photo is skipped, offline / plan limit / no key stop the batch; `CatchFromPhotosView` shows the
progress; DEBUG `-uiTestCatchPhotos` fakes two images for XCUI). `PhotoCardsTemplate`'s opening is NOT
a backend free opening → metered like explanations on the free plan. Copy/Share on a card = 4-line
`Expression.cardText`; "Copy all cards" = `cardsText` joined by `---`. Scope `.studying` = "In
flashcards" (delete; per-card status tags = `ReviewCard.stage` + reps; card-file export/import).
Card files: `CardFile` (Domain, JSON `"format": "gist-it-cards"` v1; text fields + optional per-direction
FSRS `review`) via `CardTransferInteractor` — export = cards in flashcards with progress; import goes
STRAIGHT into flashcards (new → stored + two cards, restored from `review` if present; on Caught →
enrolled; already in flashcards → untouched; repeats/empty skipped), written with the batch
`ExpressionRepository.addAll` / `ReviewCardRepository.saveAll` (10k cards ≈ 2 s on the simulator).
`tools/algoapp_to_cards.py` converts an AlgoApp deck (.zip/.xml) into a card file.
"Fix cards" (In flashcards menu, Pro): `FixCardsInteractor` goes through the phrases in flashcards —
all, or `FixScope.incomplete` (empty example, synonyms or note: `isIncomplete`) — oldest-first in
batches of 20 (`FixCardsTemplate`, `.standard` = the explanation model — the fast one left a third of
the notes / synonyms empty on a 9.9k deck; metered on the free plan): grammar, verb marker / noun
article, missing example / synonyms / note; a field the model returns empty keeps the card's text
(`apply` never empties a field); letter case is applied locally
(`lettercase`: everything lower case except the English "I"/I'm/I've/I'll/I'd — simple word
boundaries, English text only, since Italian "i" is an article — and German left as is for its nouns);
one retry per batch, then letter case only; offline / plan limit / no key stop the run.
The "Fix cards" sheet (`FixCardsView`/`FixCardsViewModel`) does it all: `survey()` reads the
phrases with progress and counts each mode, the modes are buttons there, and the run shows a two-part
`ProgressLine` (DesignSystem: `sent` grey — breathing while it waits — `processed` green;
`FixProgress.sent`); `ActivityLine` (a gliding segment) while the cards are read and the total is unknown.
The position after each batch is kept per scope (`CardFixProgressStoring`, UserDefaults; the all-cards
key predates scopes) — Stop and resume without sending a card twice; "start over" resets it; "Only
incomplete" restarts by itself once its run went through them all. Review cards are never touched. Enrolling creates two stored `.new` `ReviewCard`s (recognition:
studied→native; recall: native→studied); "in flashcards" ⇔ has cards, so 1.x users' whole old list
lands in Caught. The `learned` flag is legacy (no UI). Scheduling: `FSRS`
(Domain/Scheduling — FSRS-5, default weights, learning steps 1m/10m, relearning 10m, 90% retention, no
fuzz). Storage: `ReviewCardModel` (schema **V3**) + `ReviewLogModel` (every answer — daily counts,
future FSRS fitting; schema **V4**), lightweight stages. NEVER change a schema version's models once a
build has used it — a store matching no version fails with `unknownDataStoreSchema` and the app runs
on the in-memory fallback ("Saved data is unavailable"); add the next version instead
(`PersistenceMigrationTests` opens a store of every version, incl. the dev-build variants); cards link by `expressionID` and are deleted with
their expression in `StudyListInteractor`. Sets are sized by the DAILY GOAL (Settings 25/50/75/100/150, `DailyGoal`
→ `FlashcardsInteractor.dailyGoal`): a set = what's left of the goal (distinct cards answered today),
"more" = an extra set of 25 (`DailyGoalOptions.extraSet`, whatever the goal; `DailyPlan.moreSize` labels it); `SetComposer.quotas` puts LEARNING cards first (up to the set size), then splits
the room among young / mature / new proportionally to today's available counts (new counted at most
the room); `compose` draws within a stage at random weighted by days overdue (Efraimidis–Spirakis;
injected RNG → `SplitMix64` in tests), READY RECALL cards before recognition among the new ones, one
direction per expression per set while others can fill it, then shuffles. Available today: learning
cards, reviews due before end of day, new — recall only once its recognition card is in REVIEW and was
last answered on an earlier day. A DAY is one practice: the first Start draws today's set and stores it (`PracticeDay`
via `PracticeDayStoring` — UserDefaults JSON in the live boot, in-memory otherwise); Start/Continue
later the same day returns the set's unanswered cards in order (+ learning cards coming back), tops up
if the goal was raised, and `extra` appends an extra set of 25. A card is answered at most
`PracticeDay.maxAnswersPerCard` (3) times a day (counted from the review log), across sessions. `stats(now:)` feeds
`StudyDashboardView`/`StudyDashboardViewModel` (Study tab root): practice tile (due / new / in study;
Start — free plan → lock + paywall), Caught + In-flashcards rows, reviews per day (7 bars, today emphasised),
cards by stage (new/learning/young/mature at 21 d) — `Tokens.Chart.stage`: grey for not yet learned,
green for learned (mature only), validated with the dataviz validator for both modes; "N of M
learned". Duplicates (`DuplicatesInteractor`): `PhraseKey` (Domain — lower case, accents,
apostrophes, leading "to"/articles per language, glosses in brackets, punctuation; SLOTS ARE KEPT, only
their spellings unified (sb/smb/somebody → someone, sth → something, one's → someone's, jdn → jemanden,
qqn → quelqu'un; "(someone)" in brackets too; English "+ -ing" → "doing") — the user's rule: a slot
changes the expression, "fuck about" ≠ "fuck somebody about"; then lemmas through the `Lemmatizing` port → `NaturalLanguageLemmatizer`
(NLTagger; `prepare` requests the lemma assets — the iOS Simulator may have none, so lemmas are
identity there)) groups phrases in flashcards — LOOK-ALIKE CANDIDATES, not verdicts ("pick on sb" in two
meanings). Inside a group, merges are proposed (`DuplicateMerge`): exact duplicates on the
device (`exactMerges`: PhraseKey without lemmas + the same translation; a group of only those
(`isExactOnly`) never goes to the model), and `DuplicatesTemplate` (`.standard`, batches of 5 groups, 3
requests in flight — Sonnet answers take tens of seconds, small parallel batches keep the line moving)
returns per group a list of merges (ids + duplicate / senses + `CardText`; a card in none stays apart;
`merges(_:among:)` sanitises ids). The merged expression is in dictionary form: verbs and verb phrases with
"to", nouns and noun phrases with the article (prompt), and `keepingMarker` restores a "to"/article one of
the merged cards had if the card drops it (exact merges too). Senses = one card numbered "1) … 2) …" (plain text in the existing
fields, no schema change); `merge`
keeps the oldest phrase in flashcards with the merged texts (lettercase), per direction ONE card —
duplicate: best known (review > learning, stability, reps), senses: least known among answered — card
ids kept (today's answers still count), the rest deleted (and their links). "Don't merge" =
`NotDuplicatePair` links between cards (`NotDuplicateMarking` → `SwiftDataNotDuplicateMarks`,
`NotDuplicatePairModel`, schema **V5**; shown in `CardPreviewView`; card files carry them as
`notDuplicateOf` expressions): a scan leaves out a group whose members are all linked and never
proposes a linked pair (`DuplicateGroup.excluded`); `scan(full: true)` ("Full re-check") ignores the
links. The first builds' UserDefaults sets (`DuplicateDismissalStoring`) are adopted once and cleared.
Caught: moving a phrase checks `lookAlikesInFlashcards`
→ dialog Merge (`proposals(for:)`: exact first, else the model; only the merge containing the caught
phrase is made; none → `notADuplicate` dialog "move separately?") / Move separately; Move all offers
"all but look-alikes". In flashcards menu → "Find duplicates" sheet (`DuplicatesView`): scan with
progress → exact proposals at once → Check (unchecked, non-exact-only groups) → two-part progress,
two buttons per group — Merge (all its proposals; Check for an unchecked group) / Don't merge —,
"Merge all duplicates" (never a linked pair), "Full re-check"; after a merge a checked group with
nothing left proposed is done and its rest linked as not duplicates. Today's goal line is green
(`ProgressLine`, `Tokens.Chart.progressDone`).
Lists (Caught / In flashcards) have `.searchable` over every field (`Expression.matches`,
case- and diacritic-insensitive); Move all hides while searching. Session: full-screen `FlashcardSessionView`. XCUI
`FlashcardsUITests` (`-uiTestFreePlan` = `StubSubscriptionManaging(.free)` in the stub boot). The tab bar (standalone `UITabBar`) and
sideways-only tab swipes from 1.5.3 (3) ship here too. Main screens put the large title in the
gear's row (`.toolbarTitleDisplayMode(.inlineLarge)`, set in `SettingsTrigger`).

**v1.5.1 (2026-10-12) — swipe between the main tabs.** NO system `TabView` any more: `RootView` mounts the
SELECTED screen only, under `GlassTabBar` (DesignSystem — a STANDALONE system `UITabBar`, so the real iOS 26 Liquid Glass bar
with its drag-to-select lens; frame runs into the bottom safe area like a `UITabBarController`'s;
buttons `tab.<id>`; hidden while the keyboard is up). A swipe (`Presentation/Root/TabSwipeGesture.swift`: UIKit pan via
`UIGestureRecognizerRepresentable`; pure decision table in `TabSwipe` — order MUST match `RootView.tabItems`;
per-tab row policy because List rows carry swipe actions; once a swipe begins, the scroll views under
the finger are held still so a diagonal swipe moves sideways only) mounts the neighbour underneath and slides the
screen (`TabPager.offset`) over it — the LIVE screen, from the very first swipe. Why mount-on-demand and not
"all five alive": SwiftUI vends the accessibility of every NavigationStack's nested hosting controller
regardless of `accessibilityHidden` / UIKit `isHidden`, so hidden-but-mounted screens leaked into VoiceOver.
Mounting keeps the normal `onAppear`/`onDisappear` lifecycle; screen state lives in the view models (scroll
position and a pushed History detail reset on leaving a tab). Study/History lists are pre-loaded at launch so
a swipe never uncovers "Loading…". Reduce Motion → instant switch. Unit `TabSwipeTests`; XCUI `TabSwipeUITests`
(incl. "only the selected screen is in the accessibility tree"); UI tests reach tabs via `app.tab("Get it")`
(`UITests/TabBarQuery.swift`). `VerticalScrollView` is PAGE-level only — never nest it in a card (it sizes
content to the screen; that broke the Online panes in 1.5.0 (4)).

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
- **No pop-up dialogs:** the app asks with `ConfirmSheet` (DesignSystem — a content-sized sheet: icon,
  title, message, optional details, full-width actions, Cancel; `EHButton.Kind.destructive` for deletes),
  never `confirmationDialog` (iOS 26 shows it as a popover bubble — the user doesn't want those).
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
