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

## How to work here

- **Finish the job.** Carry every task through to the end — code, tests, docs (`CLAUDE.md`,
  `CHANGELOG.md`), a green test run, the commit — so that nothing is left undone when the task is
  reported finished. Don't stop at "the main part works" and hand the rest back as next steps: if
  something can be done now, do it; leave open only what truly needs the user (a decision, an
  account, a device), and say so plainly.
- **This codebase is yours — decide for yourself how to build it.** Refactor as you go: when the
  task touches code that is awkward, duplicated or no longer fits, reshape it rather than working
  around it, keeping the architecture below and the tests green.

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
`AnalyticsTracking`, `SubscriptionManaging`, `BackgroundTimeHolding` (a short stretch of running
time behind the screen → `BackgroundTimeKeeper`, App). The media ports
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
everything ON THE DEVICE is free (the user's rule: only what calls a model is Pro) — flashcards with any
goal and extra sets, lists, the duplicate search + exact merges, card files; Fix cards and cards from
photos are within the free request limit like explanations (backend-metered: their prompts aren't free
openings); only the duplicates Check → paywall (`AccessTier.canCheckDuplicates`, app-side).
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

**What enters Caught (2.0.2, the user's rule).** A phrase is NOT added to Caught only when Caught already
holds the very same studied-language phrase (`Expression.matchKey`: letter case and end spaces aside,
nothing else); one already in FLASHCARDS is added all the same. `CaughtPhrases` (Domain) answers
`inCaught` / `inFlashcards` for `SaveExpressionInteractor` (every save — Say it, Get it, See it, History,
"Generate from a phrase") and `CatchCardsFromPhotosInteractor` (`CatchProgress.alreadyInCaught` — not
added — and `.inFlashcards` — added, reported). The form checks the list first and says "already in
Caught" (`addError`). Every Caught row carries a mark (`StudyListViewModel.mark` → `CaughtMark`, worked
out on each load by `lookAlikesInFlashcards`, off the main actor; no mark until it answered): `.new` —
green frame (`Tokens.Signal.success`) + "New" tag; `.inFlashcards` — the very same phrase is there;
`.lookAlike` — a `PhraseKey` look-alike is. MOVING (the user's rule): a `.new` phrase moves at once — one (`moveToFlashcards`) or all
(`moveNewToFlashcards`, "Move new to flashcards (N)", no confirmation; marked phrases are left). A
look-alike moves only one at a time and only by a merge: `moveToFlashcards` finds its look-alikes and
opens `mergeOffer` (`MergeOfferSheet`) with the merged card worked out AT ONCE —
`DuplicatesUseCase.caughtMerge` (exact on the device, else the model's merge holding it, else
`forcedMerge`; nothing written) — then Merge (`confirmMerge` → `merge`) or "Add as a separate card"
(`addSeparately`: `FixCardsUseCase.fix` writes it afresh, `enroll`, then `keepApart` links it to each
look-alike as `NotDuplicatePair` — those pairs only); a failed check shows why, with Try again (or
Subscribe) and still "separate".

**v2.0.2 (on `main` — PR #13 merged `caught-marks`; 2.0.2 (1) uploaded to TestFlight 2026-11-19, 2.0.2 (2) — "Check all for merge (N)" — the same day) — the
Caught marks / moving by merge / strict verb-noun / duplicate statistics above, and the Paste slot.** Say it / Get it show ONE slot next to the mic: the mode's action,
or — empty field + text on the clipboard — Paste (`PasteAction`, Presentation/Support, shared by both
screens). Paste is normally the SYSTEM control (`EHPasteButton` = `UIPasteControl`: its tap is the consent,
iOS never asks "Allow Paste?"). THAT CONTROL IS DRAWN BY ANOTHER PROCESS, iOS's
`com.apple.UIKit.SecureControlService`, and once that service has died under a running app the app never
gets the picture again: every control created afterwards — a tab switch, back from Online, a cleared
field, new text on the clipboard — is an EMPTY, DEAD rectangle (accessibility still says "Paste,
enabled") on both screens until the app is relaunched; the control already on screen keeps its picture
and still pastes. A user's screenshot showed it; reproduced on the Simulator by `kill -9` of that service
(`xcrun simctl spawn <id> launchctl list | grep SecureControl` gives the pid) — ~100 combinations of tab
switches, modes, backgrounding and clipboard contents WITHOUT the kill never produced it, and restarting
the service / going behind and back don't bring it back in-process. Apple's forums describe the same
("UIPasteControl sometimes disappears", "restart helps"), no fix. So the control CHECKS ITSELF
(`PasteControlCheck`: on screen and app active, `intrinsicContentSize` is zero when no picture came — two
looks 150 ms apart) → `SystemPasteControl.shared.markUnavailable()`, kept for the process → the slot is
the app's own `EHButton` "Paste", which READS the clipboard (`PasteboardReading.readText` →
`pasteFromClipboard()`, asynchronous through the item provider — `UIPasteboard.string` holds the main
thread until the question is answered); iOS then asks "Allow Paste?" for content from another app (not for content the
user already pasted with the system control). A refused read = nothing usable. `ClipboardWatch`
(Presentation/Support/Pasteboard.swift) is the one owner of "may the slot offer Paste", used by both view
models: `hasText` goes by the types the control ACCEPTS (`EHPasteButton.acceptedTypeIdentifiers`, any
item) — not `hasStrings`, which is also true for rich text with no plain-text form, where the control
greys itself out (the slot held a dead Paste and no Translate) — and content that gave nothing usable
(empty, spaces, a refused read) keeps Paste OFF until `changeCount` changes (it used to come back a second
later, with the next look at the clipboard). The control takes its colors once, when made:
`EHPasteButton` is re-made on a light/dark switch (`.id(colorScheme)`) — it used to stay a black pill on a
dark screen. XCUI `PasteAffordanceUITests`: DEBUG launch argument `-uiTestPasteControlUnavailable` forces
the app's own button; the iOS 27.0 Simulator can't show "Allow Paste?" at all (its `pasted` isn't
entitled to post the alert — the read is refused at once), the iOS 26.4 Simulator and devices do, so
those tests accept both ends. Unit: `PasteControlTests`, the paste tests in `InViewModelTests` /
`VoiceViewModelTests`. NOT verified on a device: that iOS's service death is what happened on the user's
phone (the app was running there with no such service process — consistent, not proof).

**v2.0.1 (on `main` — PR #12 merged `code_review_2.0.0-2`; 2.0.1 (1), uploaded to TestFlight 2026-11-16, is the build chosen for the App Store — submitting it to App Review is done by the user in App Store Connect)** — the code review of
2.0.0 (2) and what came after that build: every fix is described in place in the 2.0.0 text below (look for
"the review"), user-facing in `CHANGELOG.md` → 2.0.1. The landing (`docs/marketing/landing`) marks what
needs Gist It Pro — Online translation and the duplicates Check (`AccessTier.canUseLiveTranslation` /
`canCheckDuplicates`) — with a `Pro` badge and a Free / Pro block; keep it and `support/index.html` in step
with `AccessTier` when a gate changes.

**v2.0.0 (in the App Store since 2026-11-14; 2.0.0 (2) uploaded 2026-11-13; branch `feat/2.0.0-flashcards`) — Study dashboard, Caught,
flashcards.** Saving (Say it / Get it / See it) stores an `Expression` = **Caught** (`StudyListView` +
`StudyListViewModel`, scope `.caught`, pushed from the dashboard; swipe-left delete, swipe-right or the
stack icon → move: a phrase that lacks a translation / example / synonyms / note is COMPLETED by the model
first (`FixCardsUseCase.complete` — `FixCardsTemplate`, groups of 20, metered on the free plan; complete
phrases cost no request), then `FlashcardsUseCase.enroll`, and ONLY THEN its row leaves (`movingIDs`
shows a spinner meanwhile — no optimistic removal); "Move all" → oldest first in groups of 20, each phrase
leaving as it moves (`bulkMove` progress + Stop); the first failure (offline, the plan's limit, no answer)
stops it: "The move stopped: X of Y moved" + the reason, and when it was the free plan's limit
(`actionNeedsSubscription`) a `ConfirmSheet` with Subscribe → paywall instead of the plain alert (XCUI:
`-uiTestLimitReached` = `LimitReachedLLMClient`). Every way into flashcards stores cards through
`ReviewCardRepository.addMissing` (check + insert in one actor step: a phrase moved twice at once, or moved
while a file with it is imported, keeps ONE card per direction); share menu → "Delete all" → `ConfirmSheet` →
`StudyListViewModel.deleteAll()`, optimistic, reload + error on a failed delete).
"+" = Generate from a phrase (`EnrichCardTemplate`, now `.fast` = the translation model) or From
photos (`PhotosPicker` ≤10 → `ImagePreparation` → `CatchCardsFromPhotosInteractor`: ONE request per
photo — the backend allows one image — via `PhotoCardsTemplate`, skipping ONLY a phrase Caught already holds (`CaughtPhrases.inCaught` — see below);
a bad photo is skipped, offline / plan limit / no key stop the batch; `CatchFromPhotosView` shows the
progress — `ProgressLine`, then a green check + `DoneChime` (DesignSystem: our `Resources/done.caf` as a
system sound — follows the silent switch, touches no audio session — plus the success haptic; not after Stop); DEBUG `-uiTestCatchPhotos` fakes two images for XCUI). `PhotoCardsTemplate`'s opening is NOT
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
one retry per batch. A phrase is DONE only when the model ANSWERED for it. What a failed request means
for a RUN OF MANY is decided once, in `Domain/UseCases/RunRequest.swift` (`RunFailure` + `RunRequest.send`,
shared by Fix cards, the duplicates Check and cards from photos): `stopsRun` (offline / plan or day limit /
no key / cancelled → the run ends at once), `service` (`.timedOut` / `.overloaded` / `.requestFailed` — one
more try, and the next request would hit it too), `rejected` (`LLMError.requestRejected`, a 4xx about THIS
request — no second try, the next may pass; `ClaudeLLMClient` maps 4xx except 401/402/403/408/429 to it),
`answer` (`.invalidOutput` / `.responseTooLong` — one more try, this request's trouble). In Fix cards: the
SERVICE not answering → the run STOPS, the position BEFORE the batch (going on walked a whole deck through
a dead service and marked it all as passed — the review found it); no ANSWER for phrases (unusable twice,
rejected, or a card missing from a good answer) → the run goes on, they get letter case only, are counted
(`FixProgress.failed`) and REMEMBERED in the checkpoint (`CardFixCheckpoint.unanswered`; `remaining` /
`survey` count them as left). The next run asks about each of them ALONE, first: answered → done; no
answer even alone → GIVEN UP (`givenUp`, `FixProgress.givenUp`: left as it is, not left to do, not sent
again until "start over" / the incomplete scope's own restart) — so a phrase the model can't take neither
holds others back nor is asked about forever. A phrase is given up only on EVIDENCE that the model answers:
another request of the same run got an answer, or it went unanswered alone in two runs (`askedAlone` marks
the first); until a run has that evidence, after `barrenLimit` (3) unanswered in a row the phrases asked
alone wait behind the batches. `barrenLimit` requests in a row without ONE answer stop the run with the
last error (nothing answers: not "this request's trouble") — the phrases gone past stay remembered, nobody
is given up. `complete` (Caught → flashcards) asks once more about what an answer left out, then throws — a
phrase never moves unseen by the model; what was answered is stored. The duplicates Check stops when the
service doesn't answer (a batch without an answer just stays unchecked); cards from photos skip a photo
without an answer and stop after two photos in a row the service didn't answer for (`unansweredLimit`).
The "Fix cards" sheet (`FixCardsView`/`FixCardsViewModel`) does it all: `survey()` reads the
phrases with progress and counts each mode, the modes are buttons there, and the run shows a two-part
`ProgressLine` (DesignSystem: `sent` grey — breathing while it waits — `processed` green;
`FixProgress.sent`) and three counts — Changed (`changed`), No changes needed (`unchanged`: answered, left
as it was), With an error (`failed` + `givenUp`). NOTHING TO ADD: a phrase the model ANSWERED for and still
left incomplete (no synonyms fit "an elbow" — on the user's phone all 34 "to fix" cards lacked only
synonyms, and the real model left 33 of them empty again) is remembered (`CardFixProgressStoring
.nothingToAdd`, UserDefaults `flashcardsFixNothingToAdd`) and left out of `FixScope.incomplete` and the
survey's count — "Only incomplete (34)" offered the same cards forever. "Show incomplete cards" pushes
`IncompleteCardsView` / `IncompleteCardsViewModel` (`FixCardsUseCase.incompleteCards()` →
`IncompleteCard`: what it lacks — `CardField` —, `nothingToAdd`): "To fix" / "Nothing to add", a Fix button
per card (`fix` — a card the model fills leaves "nothing to add"), and what came of it: filled, nothing to
add, or the error with its detail (`IncompleteCardsViewModel.detail`, selectable); `ActivityLine` (a gliding segment) while the cards are read and the total is unknown.
The position after each batch is kept per scope (`CardFixProgressStoring`, UserDefaults; the all-cards
key predates scopes; `unanswered` / `askedAlone` / `givenUp` are optional in the stored JSON) — Stop and resume without sending an answered card twice; "start over" resets it; "Only
incomplete" restarts by itself once its run went through them all. Review cards are never touched. Enrolling creates two stored `.new` `ReviewCard`s (recognition:
studied→native; recall: native→studied); "in flashcards" ⇔ has cards, so 1.x users' whole old list
lands in Caught. The `learned` flag is legacy (no UI). Scheduling: `FSRS`
(Domain/Scheduling — FSRS-5, default weights, learning steps 1m/10m, relearning 10m, 90% retention, no
fuzz). Storage: `ReviewCardModel` (schema **V3**) + `ReviewLogModel` (every answer — daily counts,
future FSRS fitting; schema **V4**), lightweight stages. NEVER change a schema version's models once a
build has used it — a store matching no version fails with `unknownDataStoreSchema` and the app runs
on the in-memory fallback ("Saved data is unavailable"); add the next version instead
(`PersistenceMigrationTests` opens a store of every version, incl. the dev-build variants); cards link by `expressionID` and are deleted with
their expression in `StudyListInteractor`. THE DECK IS KEPT IN MEMORY: `SwiftDataExpressionRepository` and
`SwiftDataReviewCardRepository` read the store once and answer `all()` from memory, kept in step with every
write they make (after the save succeeded) — reading 9.6k phrases + 19k cards out of SwiftData took ~1 s and
happened on every dashboard appearance, practice start / end and list load (measured on a store that size:
stats 940 → 126 ms, session start 1820 → 198 ms, list load 1180 → 28 ms; the first read is still ~0.9 s,
done by RootView's launch preload). ONE instance of each per store (`bootLive` creates them once): a second
instance or another process writing the table would leave the copy stale. `DeckCacheTests` compares the
repository's answer with a FRESH instance's after every kind of write. Settings → "Disk and memory usage" →
"Phrases and flashcards" shows the counts, the content on disk and the estimated memory
(`DeckFootprintReporting` → `StorageUsageReader`; `DeckStorageUsageReader` in the stub boot). Sets are sized by the DAILY GOAL (Settings 25/50/75/100/150, `DailyGoal`
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
`PracticeDay.maxAnswersPerCard` (3) times a day (counted from the review log), across sessions. TODAY'S ANSWERS
ARE THE LOG ENTRIES OF TODAY'S CALENDAR DAY, midnight to midnight (`calendarDay(of:)`; the port reads a closed
period only — `ReviewCardRepository.logs(in:)`, there is no "since"): counted "since midnight", answers
stamped on a later day (the phone's clock was ahead when they were given, then put right) were today's on
every day until theirs came — the goal read reached with nothing answered, Start gave an empty set, cards
answered three times stayed over the limit, and the 7-day bars said 0 for the same day (the review found
it). The end is the day's, not "now": a clock put back by an hour leaves answers later than now that were
given today. The cards' own due dates stay as that clock wrote them. THE REVIEW LOG OUTLIVES ITS CARD, on purpose (the
review asked to delete it with the phrase): the 7-day bars are the work done, an answer given isn't taken
back by deleting or merging the phrase (past days would change after the fact), and the log is the data for
fitting FSRS. The goal follows the same rule — `studied` = every card answered today, in the deck or not
(it counted only the cards still there: deleting a phrase turned "5 of 5, reached" into "4 of 5" and Start
drew one more card, while the bars' "today" still said 5). `stats(now:)` feeds
`StudyDashboardView`/`StudyDashboardViewModel` (Study tab root): practice tile (due / new / in study;
Start — free plan → lock + paywall), Caught + In-flashcards rows, reviews per day (7 bars, today emphasised),
cards by stage (new/learning/young/mature at 21 d) — `Tokens.Chart.stage`: grey for not yet learned,
green for learned (mature only), validated with the dataviz validator for both modes; "N of M
learned". The dashboard layout is FIXED (the user asked): every block keeps its size in every state —
GoalProgress and the status line always present (an empty status keeps its room), captions one line
(`lineLimit(1)` + `minimumScaleFactor`, never wrapping), the stage legend always the 2 × 2 `Grid`. Duplicates (`DuplicatesInteractor`): `PhraseKey` (Domain — lower case, accents,
apostrophes, leading "to"/articles per language, glosses in brackets, punctuation; SLOTS ARE KEPT, only
their spellings unified (sb/smb/somebody → someone, sth → something, one's → someone's, jdn → jemanden,
qqn → quelqu'un; "(someone)" in brackets too; English "+ -ing" → "doing") — the user's rule: a slot
changes the expression, "fuck about" ≠ "fuck somebody about"; then lemmas — for PHRASES of several words
only: a single word keeps its form ("dashing" ≠ "a dash"; lemmas grouped such forms with pairs already
marked "not duplicates", and they came back); a group that joins marked cards with a new look-alike shows
the marked ones as one line of context (`DuplicatesView` `settledMembers`); a verb and a noun are
never look-alikes — the leading marker gives the class (`PhraseKey.wordClass`: "to"/"zu"/"sich"/"se"/"s'"
→ verb, an article → noun, none → either; `PhraseKey.alike`), so "to drain" / "a drain" NEVER share a
group, a bare "drain" included (the user's rule: a verb and a noun are two words): when both meet, the
verbs and the nouns make groups of their own, keyed `key|verb` / `key|noun`, and a bare phrase is in BOTH
(`lookAlikeSets`); merged away in one, it leaves the other (`DuplicatesViewModel.dropGone`). `merges(_:among:)`
drops a model's merge naming a verb and a noun; `lookAlikesInFlashcards` and `exactMerges` follow the rule; lemmas through the `Lemmatizing` port → `NaturalLanguageLemmatizer`
(NLTagger; `prepare` requests the lemma assets — the iOS Simulator may have none, so lemmas are
identity there)) groups phrases in flashcards — LOOK-ALIKE CANDIDATES, not verdicts ("pick on sb" in two
meanings). Inside a group, merges are proposed (`DuplicateMerge`): exact duplicates on the
device (`exactMerges`: PhraseKey without lemmas + the same translation; a group of only those
(`isExactOnly`) never goes to the model), and `DuplicatesTemplate` (`.standard`; `DuplicatesUseCase.check`
is ONE request for one batch — the SHEET keeps the line: batches of `batchSize` 5 groups, `inFlight` 3
requests at once; Sonnet answers take tens of seconds, small parallel batches keep the line moving)
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
proposes a linked pair (`DuplicateGroup.excluded`). THE MARKS ARE FINAL (the user's rule): no search and no
Check touches a linked group — "Full re-check" is GONE (it put the marked groups to the model again and
left the user looking at "Check (23)" over an empty list); the sheet has "Search again" (`searchAgain`, a
normal scan). After a scan the sheet shows statistics (`ScanStatistics`: phrases read = `scan.total`, candidate groups /
phrases, groups already marked): the scan reports the all-linked groups it left out
(`DuplicateScanStep.settled` → `DuplicatesViewModel.settled`), and their line opens `SettledGroupsView` —
"Unmark" (`unmark`: `DuplicatesUseCase.unmarkNotDuplicates` drops the links AMONG those phrases only,
`NotDuplicateMarking.unmark(_ pairs:)`; the group joins the candidates with its exact merges recomputed)
and "Merge" (`mergeSettled`: unmark, then an exact merge at once, else `checkGroup` — Pro, the view gates
it via `needsModel(toMerge:)`). The first builds' UserDefaults sets (`DuplicateDismissalStoring`) are adopted once and cleared.
Caught → flashcards (2.0.2 — see "What enters Caught" at the top): new phrases move at once, a look-alike
only by a merge shown first (`mergeOffer`, `caughtMerge`) or as a separate card linked "not duplicates";
`mergeCaught` (= `caughtMerge` + `merge`) stays for callers that merge without asking. In flashcards menu → "Find duplicates" sheet (`DuplicatesView`): scan with
progress → exact proposals at once → Check (unchecked, non-exact-only groups) → two-part progress,
two buttons per group — Merge (all its proposals; Check for an unchecked group) / Don't merge —,
"Merge all duplicates" (never a linked pair), "Search again". EVERY WRITE TO A GROUP IS ONE AT A TIME
(`DuplicatesViewModel`; the review found two taps on "Merge all" making each merge twice, a merge during
the Check leaving a proposal that names a deleted phrase, a full re-check making it skip the rest, and
the merging going on behind a closed sheet): "Merge all" is ONE tracked run (`mergeAll` progress shown in
place of the button, Stop in the toolbar, ends on the first failed merge; its groups stay in `busy` until
merged, so their own buttons, a second tap, a full re-check and a new Check wait — `isBusy` covers it; each
merge runs in a task of its own, so Stop / closing never cut one in the middle). ONE LINE TO THE MODEL per
sheet (`line` + `requests`): "Check" puts every unchecked group on it, a group's own Check puts that group
at its head (after `gatherDelay`, 1 s, so the next taps ride in the same request) — sent 5 a request, 3
requests at once, WHOEVER asked (each group's Check used to be its own request outside the ceiling: 12
taps = 12 requests at once, a group could be asked about twice, Stop and closing didn't reach them); one
progress (`check`: sent / answered / total / failed), one Stop (cancels the requests out), `RunFailure`'s
rule (the service not answering ends the run; a batch without an answer stays unchecked — `notAsked`
feeds "Check the rest"). A group put to the model (`awaiting`: on the line or out) keeps Merge / Check off
until its answer and is left out of `duplicateMerges`; a group being merged isn't put on the line; `adopt`
drops an answer about a group whose phrases changed since it was sent (it stays unchecked as it is now);
closing the sheet goes through `StudyListViewModel.endDuplicates` on
every path (a custom sheet binding — SwiftUI clears the item before `onDismiss`): `stop()`, then
`settle()` waits for the merge under way BEFORE the list is reloaded. After a merge a checked group with
nothing left proposed is done and its rest linked as not duplicates. Today's goal line is green
(`ProgressLine`, `Tokens.Chart.progressDone`).
Say it / Get it — A SENT REQUEST OUTLIVES THE TAB (the review asked to cancel it on leaving; that is the
design, not a bug: the view models live in `RootView`, `withBackgroundCompletion` keeps the same request
alive behind the whole app, and the backend claims the free plan's request before the model call and
returns it only on an upstream error — a cancel from the phone would spend it for nothing).
`screenDisappeared` stops the mic and playback only. What the screen's state is ABOUT is one notion,
`askedSource` / `askedIntent`: the text of the request out (`sentSource` / `sentIntent`, `.processing`) or
of the result shown (`generatedSource` / `generatedIntent`); an edit never submitted is dropped back to it
on leaving, and a mode / tone change re-runs it, in BOTH states (it used to hold for a result only: an
edit typed while the request was out stayed above the answer to the old text until the next leave).
Online — THE END OF A SESSION (`SonioxLiveTranslator` `stopGracefully`; the review asked about its 5 s
limit: what was RECEIVED is always saved, the provisional tail included, and the recording is whole —
only words the service never answered for can be missing). The stream says `.ending` (the microphone goes
off; also when the session ends itself — silence, a call, a lost mic — so the screen shows "stopping"),
maybe `.cutShort(.sending | .waiting)`, then `.finished`. Two limits, one per part: `tailSendLimit` 10 s
for the audio not sent yet to reach the service, then `tailAnswerLimit` 5 s FROM THE END-OF-AUDIO FRAME for
its answer (one 5 s limit from the stop itself left a backlog on a slow uplink no time to be answered);
running out of either ends the session with what it has and is reported (`Live.tailNotSent` /
`Live.tailNotAnswered`). `LiveStopPlan` (pure): a stop during a direction switch lets the rotation finish
and sends the tail on the NEW socket (it ended at once, dropping what was said after the switch); the
microphone never started / the first socket never came up → the stop is immediate. `LiveTranslateInteractor`
holds `BackgroundTimeHolding` from `.ending` (or `.finished`, on a failure) until the History row is
written: behind the screen the microphone is the app's reason to run, and it goes off BEFORE the last
words are collected — a session stopped from the Lock Screen, by silence or by a call could be suspended
unsaved. None of this is verifiable on the Simulator — check on a device.
Online — A LONG SESSION ON SCREEN (the review: "the final text only grows — a long session inflates
memory"). The text is small (≈150 KB an hour for both panes, 1.2 MB for eight) and must grow — the user
scrolls back to the start; what grew with it was the SCREEN's work: each pane was ONE `Text` with the whole
transcript, laid out and drawn again on every update, several times a second. A pane is now a plain
(non-lazy — the scroll sync of the two panes works on the real content height; never make it lazy) stack of
`Text`s, one per BLOCK of whole paragraphs (`TranscriptBlocks`, `LiveTranscriptView.swift`: a block closes
at the first "\n\n" after `blockSize` 2,000 UTF-8 bytes and never changes afterwards; it keeps the first of
the two line breaks, so the stack measures as the single `Text` did; cut incrementally — `take` reads only
what came after the last closed block). Hosted measurement on the Simulator, per update of one pane:
11–200 ms → 1–3 ms for one to three hours of speech, 32 → 10 ms for eight. One `Text` per PARAGRAPH was
tried first and was no better than blocks (hundreds of small views cost as much to walk). `LiveTranscriptTests`
pins the cut and the height against the single `Text`.
Lists (Caught / In flashcards) have `.searchable` over every field (`Expression.matches`,
case- and diacritic-insensitive); Move all hides while searching. Session: full-screen `FlashcardSessionView`.
Fix ONE card (`Presentation/Flashcards/CardFix.swift`): a wand next to the speaker — in `CardPreviewView`
and in practice once the answer is shown (never before: the prompt mustn't change under a user recalling
it) — sends that card to the model again, `FixCardsUseCase.fix` (ALWAYS sent, complete or not; fixed and
filled in like a Fix cards batch, stored; throws and changes nothing on a failure or an answer without the
card; review cards untouched). `CardFixModel` (owned by `StudyListViewModel` and
`FlashcardSessionViewModel`) holds the status of one card at a time — fixing (set synchronously on the tap) /
updated / unchanged / failed(+needsSubscription) — and `status(for:)` returns it for THAT card only;
`FixCardButton` + `CardFixStatusLine` are the shared views. The session swaps the fixed texts into `current`
and the rest of the queue; the card view reads the live row. Metered on the free plan → the line offers
Subscribe; the paywall is presented from the card sheet / the session cover themselves (the root can't
present over them). XCUI
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
