# Gist It backend (AWS)

Keeps the Anthropic and Soniox API keys **off the device**. A shipped app holds no third-party
key; it proves it's a genuine copy of Gist It on a real iPhone with **Apple App Attest**, gets a
short-lived session token, and then:

- sends Claude requests through this backend (`POST /v1/messages`, streamed back unchanged), and
- gets a single-use, 60-second **Soniox temporary key** per WebSocket (`POST /v1/soniox/temporary-key`).
  Live audio still goes straight from the phone to Soniox.

```
iPhone ──App Attest──▶ Lambda (Function URL, streaming) ──▶ api.anthropic.com
   │                     │  Secrets Manager: API keys        ──▶ api.soniox.com (temp keys)
   └──── audio (temp key) ──────────────────────────────────▶ stt-rt.soniox.com
```

| Piece | What |
|---|---|
| `src/index.mjs` | Routes, Claude relay, Soniox temp keys, dev sessions |
| `src/appattest.mjs` | App Attest attestation + assertion verification (Apple's documented steps) |
| `src/token.mjs` | HMAC session tokens (1 h) |
| `src/validate.mjs` | Only the request shapes the app sends are relayed (models, `max_tokens`, one user turn) |
| `src/store.mjs` | DynamoDB: one-time challenges, attested keys + counters, rate limits |
| `template.yaml` | SAM stack: Lambda + Function URL, DynamoDB (TTL), Secrets Manager, logs |

Limits per App Attest key (stack parameters): 20 Claude requests/min, 500/day, 200 live sessions/day.
Only `claude-sonnet-5-5` and `claude-haiku-5-5` are forwarded (`AllowedModels`).

## Access tiers (subscription)

The monthly subscription exists **only in the App Store version**. Each session token carries a
tier the server decides — never the app:

| Tier | Who | Translations | Explanations + Say it | Live translation |
|---|---|---|---|---|
| `beta` | Xcode builds (App Attest *development*), TestFlight (`AppTransaction.receiptType` `Sandbox`) | unlimited | unlimited | yes |
| `pro` | App Store build + active subscription transaction | unlimited | unlimited | yes |
| `free` | App Store build without one | unlimited | 1 per 5 min, shared | no |

Limits follow the **scenario, not the model**. Translations (Get it → Translate, See it → Translate,
study-card enrichment) are recognised by the fixed opening of their template's system prompt
(`FREE_PROMPT_OPENINGS` in `src/validate.mjs`, pinned by `Tests/SubscriptionTierTests.swift`); every
other request — explanations, Say it, anything unrecognised — is metered for free users.

Opening a session the app sends StoreKit's signed `AppTransaction` and subscription transaction
(JWS). `src/storekit.mjs` verifies them like Apple's server library (x5c → **Apple Root CA - G3**,
Apple marker OIDs, ES256) and checks bundle id, product id (`ProProductIds`), `Production`
environment, expiry and revocation. A pro session never outlives the subscription's expiry, and one
subscription works on at most `MaxDevicesPerSubscription` (5) devices.

A plan refusal is **HTTP 402** `{ "error": { "type": "subscription_required", "retry_after": 240 } }`
(+ `Retry-After`). The free allowance is a sliding 5-minute window (`FreeLimitCooldownSeconds`);
a failed upstream call gives it back, and the Settings connection probe never uses it.

## Deploy

```sh
brew install aws-sam-cli            # once
aws configure                       # or `aws login` / SSO — any credentials that can deploy a stack
cd Backend
sam deploy --guided                 # stack name: gist-it-backend; accept the defaults; allow the
                                    # Function URL without auth (auth is App Attest, in the code)
scripts/set-secrets.sh              # paste the Anthropic + Soniox keys (input is hidden)
```

`sam deploy` prints `BackendUrl`. Put it in the repo-root `Secrets.xcconfig` (the `$()` stops
xcconfig from reading `//` as a comment):

```
BACKEND_URL = https:/$()/xxxxxxxxxxxx.lambda-url.eu-central-1.on.aws
```

With `BACKEND_URL` set the app ignores `CLAUDE_API_KEY` / `SONIOX_API_KEY`, and **Release builds
never contain them** (`Config/Base.xcconfig` blanks them for the Release configuration).

## Before the first public build

- **App Store Connect → Subscriptions:** a subscription group with one auto-renewable product,
  id `tech.10xt.englishhelper.pro.monthly`, duration 1 month, price, localized name/description and
  the review screenshot. The id must match `AppConfig.subscriptionProductID` and `ProProductIds`.
- **Paid Apps agreement** active (Business → Agreements), or the product won't load.
- **Privacy policy** published at `https://gistit.10xt.tech/privacy` (`AppConfig.privacyPolicyURL`) —
  the paywall links to it, as App Review requires. Terms of use link to Apple's standard EULA.

- **Rotate both API keys.** Earlier TestFlight builds embedded them in `Info.plist` — treat them as leaked.
- Give the backend its **own Anthropic workspace + key with a monthly spend limit** (Console →
  Workspaces → Limits), so even a compromised backend has a ceiling.
- The app's App ID needs the **App Attest** capability. The entitlement
  (`com.apple.developer.devicecheck.appattest-environment`) is in `App/EnglishHelper.entitlements`;
  automatic signing adds the capability. TestFlight and App Store builds always attest in the
  production environment, whatever the entitlement says.
- Once only TestFlight / App Store builds should get in, redeploy with
  `AllowDevelopmentAttestation=false` (Xcode-run builds will then be refused).

## Simulator / debug

App Attest doesn't exist on the Simulator. For DEBUG builds only:

1. `scripts/set-secrets.sh` → set a long random **dev token**.
2. `Secrets.xcconfig`: `BACKEND_DEV_TOKEN = <the same value>`.

Release builds never read or contain it, and an empty server-side `dev_token` disables the route.
Disable it (`-` in the script) when you don't need it.

## Test

```sh
cd Backend && npm install && npm test
```

The App Attest tests build a fake certificate chain with `openssl` (own root → intermediate →
credential cert with the nonce extension) and check that tampering with any input is rejected.
`routes.test.mjs` runs every route with DynamoDB, Secrets Manager and the upstream APIs faked.
Nothing here touches AWS.

## Cost

Pay-per-use: Lambda + DynamoDB on demand are cents at this volume; Secrets Manager is
$0.40/month for the one secret. Logs are kept 30 days.
