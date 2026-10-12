# What's New

Release notes for **Gist It** (formerly EnglishHelper), written for the people who use it.

## 1.5.1 — 2026-10-12

The first release with Gist It Pro. Version 1.5.0 went to TestFlight only; everything it brought is
listed here.

**Swipe between screens.** Swipe left or right anywhere on Study, See it, Say it, Get it or History
to move to the neighbouring screen, in the same order as the tab bar. Swipes that already meant
something keep working as before: swipe left on a History item still deletes it, the swipe actions
on Study cards still appear, and dragging inside a text field still moves the cursor. Scrolling up
and down is never mistaken for a swipe.

**Gist It Pro.** Gist It now has a free plan and a monthly subscription. **Translation stays free
for everyone, with no limits**: Get it → Translate, See it → Translate, and the cards you save to
Study. On the free plan, **explanations and Say it** (both phrasings and phrases for a situation)
share **one request every 5 minutes**. When you hit that limit, the screen says so and offers
**Subscribe** instead of Retry. **Online translation** (the live interpreter) is part of the
subscription. Gist It Pro removes every limit. The offer comes from the App Store itself, with the
price, the renewal period, **Restore Purchases** and the terms right there. Settings has a new
**Subscription** card showing your plan and renewal date, with **Manage subscription** and
**Restore purchases**. TestFlight testers keep every feature unlocked, with no subscription needed.

**Your requests go through Gist It's own server.** Explanations, translations and the live
interpreter now reach Claude and the speech service through our server, and the app proves it's
the genuine Gist It on a real iPhone before it's let in. The app no longer carries any service
keys, so nobody can lift them from it. You won't see any difference in how the app works.

**Screens no longer drift sideways.** A wide photo, a long word with nowhere to break, or a long
status line could make a page slightly wider than the screen, and it would then slide left and right
under your thumb. Every screen now scrolls only up and down.

**Answers are better formed.** Answers are now constrained to the exact shape the app expects
before they leave the model, so "Couldn't parse the response" should be a thing of the past. Long
photo explanations also get more room before they're cut off.

**Settings show how fast each model answers.** The **Service connections** card now lists the
**Translation model**, the **Explanation model** and the **Voice model** by what they do, not by
technical model names. Next to each one, signal-style bars and a word (**Fast** / **Medium** /
**Slow**) show how quickly it answered a test request, and the exact time in seconds is shown too.
Tap the refresh arrow to measure again. The **Models by scenario** section is gone: each task now
always uses the model that suits it best (the quick one for translation, the stronger one for
explanations and Say it), so there is nothing to tune.

**A new analytics service, and crash reports.** Feature counts ("translation completed", "phrase
saved") now go to [Amplitude](https://amplitude.com), stored in the EU, instead of TelemetryDeck.
The rule hasn't changed: bare event names only, **never** what you type, say or photograph, and no
advertising identifier, so there is still no tracking-consent pop-up. Gist It now also sends
**crash reports** through [Sentry](https://sentry.io), so crashes and freezes get fixed without you
having to report them. A crash report contains the technical trace, the device model and the iOS
version. It never contains screenshots or your content. Both now tell the App Store version apart
from test builds, so test runs never skew the numbers.

**Ready for iOS 27.** Built with the iOS 27 SDK, and still runs on iOS 26.

## 1.4.3 — 2026-09-08

**Your live session stays on the Lock Screen.** Start **Get it → Online**, lock the phone, and the
session shows up as a Live Activity banner (and in the Dynamic Island on phones that have one), the
way Voice Memos shows a recording: a pulsing record indicator, the translation direction
(**EN → RU**), a running timer, and **Pause** / **Stop** buttons that work right there — no unlock,
no switching apps. Pause turns the indicator orange; Stop ends the session and saves it to History
as usual. Flipping the direction mid-session updates the banner, and a session that ends on its own
(silence auto-stop, a call, an error) takes the banner down with it. Tapping the banner opens the
Online screen. Live Activities can be switched off for Gist It in iOS Settings; the session itself
is unaffected either way.

**Clean up the Study list in one go.** Next to **+** there is a new **Clean up** button (an
eraser). Tap it and, after a confirmation that shows how many cards are affected, every card you
have marked as **learned** is removed from the list at once — no more swiping them away one by one
after an export. The button is greyed out while nothing is marked learned, and the confirmation is
there because this can't be undone.

**The Paste button no longer gets stuck.** On Say it and Get it the action button turns into
**Paste** while the field is empty and the clipboard holds text. If the clipboard then changed
*outside* the app while it was on screen — you copied something on your Mac (Universal Clipboard),
a password manager wiped it, a Shortcut ran — the app didn't notice: the greyed-out Paste stayed
put with **no Explain / Translate button anywhere**, or, the other way round, the button stayed a
disabled Explain although text was one tap away. The screen now keeps an eye on the clipboard while
it's visible and follows three simple rules: text in the field → Explain / Translate; empty field
and text on the clipboard → Paste; nothing in either → a disabled Explain / Translate. As before,
it only checks *whether* there is text — the clipboard is read solely when you tap Paste.

**See it → Explain no longer fails on photos that deserve a long answer.** When a photo had a lot
to explain (a landmark on a banner, a shop front, an interior with several objects), the explanation
came back in several paragraphs — and the app answered **"Couldn't parse the response. Try again."**
every single time, retries included. The model was separating those paragraphs with raw line breaks
inside its structured reply, and the app's strict reader rejected the whole thing. The reader now
repairs exactly that before decoding, and the prompt asks for properly escaped line breaks up front.
The same fix protects every other answer type (Say it, Get it, cards), which use the same reader.
The photo itself was never the problem: HEIC from the camera roll, orientation, and size were all
handled correctly.

## 1.4.2 — 2026-08-15

**Paste without the pop-up.** The **Paste** button (on Say it and Get it, whenever the field is
empty and your clipboard holds text) is now the system's own paste control — your tap on it *is*
the permission, so iOS no longer asks **"Allow Paste?"** every time you bring text over from
another app. Same one-tap flow, no dialog, ever. The app still never reads your clipboard on its
own: it only checks *whether* there's text until the moment you tap.

**See it remembers what it already did.** Switch a processed photo between **Explain** and
**Translate** freely: each mode's result is now kept for the current photo, so switching back
shows the earlier result **instantly** instead of recognizing the whole photo again (and again).
Bookmarks on translated blocks survive the round-trip. A new photo starts fresh, and switching
modes after an error still retries — that behavior hasn't changed.

**See how much space the app uses.** Settings has a new **Disk usage** card: how much the
translation cache, your history, and the session recordings take on disk, with a total. Text
sizes are estimated from the stored content; audio is the actual size of the recording files.

**Buttons read properly in all six languages.** Button labels no longer break words across lines
(«Удержива-йте» is gone — the hint now reads «Зажмите и говорите») and two-line labels are
centered. The German, Spanish, French, and Italian labels that were too long for the half-width
buttons got shorter wording, and the hold-to-talk and "Listening…" hints are now translated in
French, Spanish, German, and Italian instead of falling back to English.

## 1.4.1 — 2026-07-18

**Online: your live interpreter.** Get it has a third mode — **Online**. Tap **Listen** and the
phone starts translating the speech around you in real time: a lecture, a tour guide, an
announcement, the person across the counter. What's being said appears in a small window in the
original language, and the running **translation streams into the big window** below it, word by
word, without waiting for sentences to finish. Both texts break into **paragraphs at natural
pauses** in the speech, so a long session reads like a conversation, not a wall of words. Tap the
button again (it shows a live sound diagram while listening) to stop.

**Scroll back without losing the thread.** Both windows follow the newest words on their own. Scroll
up to re-read something — the text keeps arriving below in the meantime — and the moment you pull
back down to the bottom, the auto-follow picks up again. The two windows also scroll **together**,
so the original and its translation stay side by side wherever you are in the session.

**Keeps listening when you look away.** Lock the screen or switch to another app — the session keeps
translating until you stop it. If nobody has spoken for **5 minutes**, it stops itself (and saves),
so a forgotten microphone never runs all day.

**Pause without hanging up.** A **Pause** button sits next to Listen: it instantly mutes the
session (nothing is recognized or recorded while you talk privately) and resumes just as
instantly — the connection stays warm the whole time.

**Flip the direction mid-conversation.** A **direction toggle** (EN→RU / RU→EN) sits next to the
buttons — by default the session listens to the language you're learning and translates into your
own. Tap it to answer back: on a running session it draws a **divider line** in both windows and
keeps going in the opposite direction — same session, same recording. Tapped while idle, it just
sets the direction for the next session.

**Copy what you heard.** Both text windows have a copy button — the recognized speech and the
running translation are one tap away from the clipboard.

**Every session is kept — with the sound.** Each listening session lands in **History** with the
full original text, the full translation, and the **original audio**, so you can replay exactly
what was said. And History entries can now be **swiped left to delete** — removing a session also
removes its recording.

**Start it from the Lock Screen.** A seventh widget — **Get it · Online** — joins the six: one tap
and the app opens with a live-translation session **already listening**. (On very first use it asks
for the microphone once, like the other mic widgets.)

**Small things.** Photo **explanations** now land in History too (See it already logged
translations — now both modes do), the photo screen's recognition errors offer a one-tap **Retry**
of the same photo, and the mic button across the app was redesigned into the same pill shape as the
action buttons — with its hint right inside.

## 1.3.3 — 2026-07-12

**Hold to talk.** The mic button now works like a walkie-talkie: **press and hold**, speak, and
**let go** — your words are translated, explained, or turned into phrasings the moment you release,
with no extra tap. The button answers your touch with a small **vibration**, then plays the familiar
recording **chime** — speak after it — and a closing chime confirms the mic is off when you let go.
(The chimes follow the ring/silent switch; the vibration always comes through.)

**Only a deliberate release sends.** If something interrupts the hold — a phone call, a permission
pop-up, Control Center, switching away, or the page scrolling under your finger — the mic simply
turns off and your half-finished sentence is **dropped, not sent**. What's in the field stays there,
so you can hold again and finish the thought.

**Still hands-free from the Lock Screen.** Opening the mic from a widget works as before: it starts
listening on its own (on very first use, right after you allow the microphone), and a single tap on
the button finishes and sends what you said. With **VoiceOver**, the button works as a toggle — one
activation starts listening, the next stops and sends — and its hints now say exactly that, in all
six interface languages.

**Paste in one tap.** Copied something in another app? On **Get it**, while the input field is
empty and your clipboard holds text, the Translate/Explain button becomes **Paste** — one tap drops
the copied text into the field (with a small vibration), and the button turns back into
Translate/Explain for you to fire when ready. Clearing the field brings Paste back; with nothing
typed and nothing copied, the button simply waits, disabled. The app never peeks at your clipboard's
contents on its own — it only checks *whether* there's text (which iOS allows silently) and reads it
solely when you tap Paste.

## 1.3.2 — 2026-07-07

**Anonymous usage insights.** Gist It now counts how often its features are used — a translation
finished, a phrase saved, a deck exported — so future updates can focus on what actually gets used.
What you type, say, or photograph is **never** part of it: the app sends bare event names only
("translation completed"), with no text, no photos, and no way to attach them. Analytics run
through [TelemetryDeck](https://telemetrydeck.com), a privacy-first service that keeps no personal
profiles and uses no advertising identifiers — which is why there's no tracking-consent pop-up:
there is simply nothing to consent to.

## 1.3.1 — 2026-07-02

**A new name: Gist It.** EnglishHelper is now **Gist It** — a name that finally fits what the app
does: help you catch the gist of the world around you and say what you mean, in any of its six
languages, not just English. It's the same app underneath — your saved phrases, history, and
settings are untouched; only the name on your Home screen changes.

**Screens keep their state.** Switch tabs freely: every screen now comes back exactly as you left
it — the generated phrases or translation still on screen, the text they were made from, and your
chosen mode (How to say / What to say, Explain / Translate) and tone. Modes now also survive an app
restart, like the tone always has — and only the mode you pick on the screen itself is remembered:
opening something via a widget, the Share sheet, or an "Explain" button doesn't change your saved
choice. If you edited the input but never pressed the button, the edit is dropped when you leave —
so what's in the field always matches the results below it, and a new set is generated only when
you actually ask for one. Leaving a screen mid-dictation now also switches the microphone off.

**Much steadier on a weak mobile signal.** The connection layer was reworked around bad-network
reality: answers now **stream** from the model, so a long answer is never cut off just for taking
its time (previously a slow photo translation could hit a timeout and be retried at full cost); a
connection that drops right as you ask now fails fast with a clear message — no more sitting on
"processing" for minutes — and the app **re-checks the network before every retry** instead of
retrying into a dead link. The moment you're back online, your last request still re-runs itself.

**Faster app start.** The app's storage now opens in the background during launch instead of
blocking the first screen — startup stays instant even as your history and study list grow.

**Model switch respects the cache.** If you change the model for a scenario in Settings, repeated
requests are answered by that model — not by cached results from the previous one.

**Lock Screen widgets.** Add Gist It to your Lock Screen for one-tap access to a scenario — no
unlocking and tapping through tabs. There are six, one per scenario: **See it · Explain**, **See it ·
Translate**, **Get it · Explain**, **Get it · Translate**, **Say it · How to say**, and **Say it ·
What to say**. Tapping one opens the app straight into that scenario with the **camera ready** (See
it) or the **mic already listening** (Get it / Say it). Each carries its own icon — the scenario's
camera / speech-bubble / mic glyph plus a small badge (a lightbulb for Explain and What-to-say, a
globe for Translate and How-to-say) — so the six are easy to tell apart. The look is yours to pick —
**Standard**, **Bordered**, or **Filled** — when you add or edit a widget. To add them: lock the
phone, touch and hold the Lock Screen, tap **Customize**, tap a widget slot, and pick **Gist It**.

**Any photo works now, including HEIC.** A photo shared or picked in **See it** could fail with an
error when it was in iPhone's default HEIC format. Every photo is now converted to a supported format
(and downscaled, so it uploads faster) before it's sent — so recognition and translation work no
matter where the photo came from.

**Walk away during a long request.** When a recognition or explanation takes a while, you no longer
have to keep the app open and wait. Leave it, and you'll get a notification the moment the result is
ready — tap it to come back to the result on the same screen.

**Smarter translation variants.** **Get it → Translate** now gives more than one translation only when
a word or phrase genuinely has different meanings depending on context (like an idiom that's both
literal and figurative), each with a short note on which sense it is — instead of padding the list
with near-synonyms.

**Instant repeat translations.** Translate or ask for phrasings of text you've already done — **Get
it · Translate**, **Say it · How to say**, **Say it · What to say** — and the result now comes
straight from the app instead of the model: instant, and it doesn't use your connection. Asking for
fresh variants ("other options") still goes to the model. A new **Translation cache** section in
**Settings** shows how much is stored and how often it's been reused, with a button to clear it.

**A newer, sharper model.** Everything except plain translation now runs on Anthropic's latest
**Claude Sonnet 5** — so the phrasings in **Say it**, the explanations, and photo translations come
back more natural and more accurate. Plain **Translate** still uses the faster model for speed. And
**Settings → About** now lists that **fast model** next to the main one, so you can see exactly which
models are in play.

**Fixes**

- **Switching Explain ↔ Translate after an error now retries** the same photo or text, instead of
  leaving the screen stuck on the error.
- **Explaining a phrase from a "See it" card** now explains just that phrase on its own, not the whole
  photo it came from.
- **Your per-scenario model choices now take effect** — plain Translate runs on the faster model as
  intended, and long photo translations are no longer cut short.
- **Sharing into the app** is more reliable at bringing Gist It to the front.

## 1.3.0 — 2026-06-21

**Share straight into the app.** EnglishHelper now shows up in the iOS Share sheet, so you can send
things to it from anywhere. **Share a photo** (from Photos, Safari, a chat…) and it opens in
**See it → Explain** — what the picture shows and the local or cultural context behind it. **Share
text** and it opens in **Get it → Explain** — the meaning, tone, and a familiar comparison for that
phrase. No copy-pasting or switching apps.

**Ask "why this one?" on "Say it".** Every phrasing you get now has a lightbulb. Tap it to learn why
that particular wording works — and how it differs from the other options you were given (for
example, "where have you been" vs. "where were you"). It opens the full Explain breakdown.

**Choose the model for each scenario.** A new section in Settings lets you pick which Claude model
powers **Say it**, **Translate**, and **Explain** separately. **Translate** now uses the faster
**Haiku** by default, so plain translations come back quicker; **Say it** and **Explain** stay on
**Sonnet** for depth. Settings also shows the live connection status of both models.

**Steadier on a weak mobile connection.** On a flaky cellular signal the app now rides out brief
drops (tunnels, lifts, tower hand-offs) instead of failing the instant the connection blinks. When
you're genuinely offline you'll see a clear **"No connection — waiting for the network"** banner, and
the moment you're back online the app **retries your last request automatically** — no tapping
required. Photos are also compressed before upload so they go through faster on a slow link.

**One consistent row of actions on every card.** Play, **Explain**, Copy, and Save now sit together
as a single tidy row of icons on every card — across "Say it", "Get it", "See it", "Study", and
History — so the controls are the same everywhere and the Explain shortcut is always within reach.
The icons are a little smaller and card titles are sized to match the text below them, for a calmer,
cleaner look.

## 1.2.5 — 2026-06-07

**German and Italian, everywhere.** You can now pick **German** or **Italian** as your interface
language, your studied language, or your native language — the whole app is translated into both, and
they work as targets for translation, phrase generation, and explanations just like the existing
languages.

**A welcome screen on first launch.** The first time you open the app it greets you and lets you
choose your three languages — interface, studied, and native — before you start. It opens in your
system language (or English) and switches live as you pick.

**Tidier action buttons on every card.** Play, Copy, and Save (and Explain in History) now sit
together in one row at the top of each card — on "Say it", "Get it", and in History — so the controls
are consistent and easy to find. Tapping a phrase still starts and stops playback as before.

**A slightly more compact look.** On-screen text is one point smaller across the app for a denser,
cleaner layout. The tab bar stays as it was.

**Fixes**

- **"What to say" no longer fails with "Couldn't parse the response."** On broad situations the
  service sometimes wrapped its answer in extra text; the app now reads the real result reliably.
  (Same fix protects every other screen.)
- **The Retry button is no longer hidden behind the tab bar** when something goes wrong on "Say it",
  "Get it", or "See it".
- **No more stray "Request cancelled" message** when you change mode or re-run while a request is
  still in flight.

## 1.2.4 — 2026-06-06

**"Say it" now has two modes.** A selector at the top of the screen lets you choose how it works:

- **How to say** — type or say a thought and get **3** natural phrasings of it in the tone you
  picked (as before): "how do I say I agree with them?", "let me through, please", and so on.
- **What to say** (new) — describe a **situation** ("a doctor's appointment", "booking a car
  service") and get the **most useful phrases for it** — anywhere from 3 to 10, depending on how
  many the app finds genuinely helpful — in the same card format and your chosen tone.

The field hint and the on-screen guidance adapt to the selected mode so the difference is clear, and
the tone selector applies to both.

## 1.2.3 — 2026-06-05

**Copy anything, with a clear confirmation.** Every copy button across the app now flips to a
checkmark with a "Copied" confirmation (and a light haptic), so you always know it worked.

**See it: copy both languages.** On a recognized block, Play / Copy / Explain now sit together on
one row (no wrapping), and you can copy either the text in the language you're learning or its
translation.

**History: copy from your past results.** Translation entries now let you copy both the
studied-language text and the translation, right from the detail view.

**Explain: copy the explanation.** The full explanation can be copied with the same one-tap
confirmation.

## 1.2.2 — 2026-06-04

**Explain now handles whole passages.** When you sent a longer, multi-line text to **Explain** —
for example a photo translation from History with several lines — it used to latch onto a single
word or phrase and explain only that. Now Explain covers the entire text as one coherent whole:
the overall meaning, the overall tone, where such text appears, and a familiar comparison — without
dropping the rest.

## 1.2.1 — 2026-06-04

**Explain anything in a photo.** On the "See it" screen, each recognized block now has an **Explain**
button. Tap it and you jump straight to the **Get it** screen in Explain mode for that phrase — with
the photo sent along, so the explanation fits where the text actually appears (a sign, menu,
screenshot, …). You get the full Get-it screen: play it, save it, copy it, or switch to a plain
translation.

**Explain from History too.** Open any past translation and tap **Explain** on the request to get the
same full breakdown on the Get-it screen.

**Copy from photos.** Each recognized block can be copied to the clipboard in the language you're
learning.

**Snap another photo, faster.** After a photo is recognized you can take or pick a new one right
there, without backing out first.

**Easier to read in Light mode.** Cards now have clearly visible edges on a light background (they
were nearly invisible before).

**History, tidied up.** The request and its translation are now visually distinct, and rows show a
single, clean arrow.

**Polish.** Copying an explanation shows a "Copied ✓" confirmation; the main tabs read
**See it / Say it / Get it**; and the "Get it" field now says it expects text in the language you're
learning (matching the microphone).

## 1.2.0 — 2026-06-04

**Learn any of four languages.** EnglishHelper is no longer English-only. In Settings, pick the
language you're **learning** — **English, Russian, French, or Spanish**. Every screen now works in
that language: it's what you see on the cards, save to your list, and hear spoken aloud.

**Your language, your way.** Separately choose your **native language** (English, Russian, French,
or Spanish). All translations and explanations come back in it.

**Bring text in any language.** Type, dictate, or photograph something in *any* language and the app
figures it out:
- **See it** — snap a sign or menu in any language; read it in the language you're learning, with a
  translation you understand.
- **Say it** — say what you mean in any language; get natural phrasings in the language you're
  learning, with notes in your own.
- **Get it** — paste anything; see and hear it in the language you're learning, understand it in
  your own, and (in Explain mode) get the nuance with a familiar comparison.

**App in four languages.** The interface itself is now available in **French** and **Spanish**,
alongside Russian and English — switch any time in Settings and it changes instantly.

## 1.1.0 — 2026-06-03

**Explain any English expression.** The "Get it" screen now has two modes. Keep using
**Translate** to get the meaning in your language — or switch to the new **Explain** mode to
really understand a phrase: what it actually means, how formal, casual, or blunt it sounds,
when and where it's used, and a familiar comparison from your own language. Type it or say it,
and tap to switch modes any time.

**Pick the tone while you practice.** On the "Say it" screen you can now choose the tone —
**Polite**, **Casual**, or **Slang** — right under the button. Change it and you instantly get
fresh phrasings in that tone. (Tone moved out of Settings, so it's always one tap away.)

**Friendlier screen names.** The three main screens are now **Get it**, **Say it**, and
**See it**.

**Clearer Settings.** "Translate to" is now called **Native language** — the language used for
both translations and explanations.
