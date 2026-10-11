// Gist It backend — one Lambda behind a streaming Function URL.
//
//   POST /v1/attest/challenge      → { challenge }                       one-time, 5 min
//   POST /v1/attest/register       { keyId, attestation, challenge }     App Attest key attestation
//   POST /v1/session               { keyId, assertion, challenge,        → { token, expiresIn, tier }
//                                    appTransaction?, subscription? }    StoreKit JWS → access tier
//   POST /v1/session/dev           header x-dev-token                    → { token, expiresIn } (only if configured)
//   POST /v1/messages              Bearer token; Anthropic Messages body, streamed back unchanged
//   POST /v1/soniox/temporary-key  Bearer token                          → { api_key, expires_at }
//
// The Anthropic and Soniox keys never leave this function: they live in Secrets Manager.
//
// Access tiers (src/storekit.mjs): beta (Xcode / TestFlight — unlimited), pro (App Store build with an
// active subscription — unlimited), free (translations unlimited; explanations and Say it share one
// request per 5 minutes; no live translation) — by scenario, whatever the model. A tier-gated refusal
// is HTTP 402 { error: { type: "subscription_required", retry_after? } }.

import { randomBytes, timingSafeEqual } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { pipeline } from 'node:stream/promises';
import { Readable } from 'node:stream';
import { gunzipSync } from 'node:zlib';
import { GetSecretValueCommand, SecretsManagerClient } from '@aws-sdk/client-secrets-manager';

import { verifyAttestation, verifyAssertion, AttestationError } from './appattest.mjs';
import { signSession, verifySession } from './token.mjs';
import { validateMessagesRequest, isFreeRequest, RequestError } from './validate.mjs';
import { resolveTier } from './storekit.mjs';
import * as store from './store.mjs';

const ROOT_CA = readFileSync(new URL('./apple-app-attestation-root-ca.pem', import.meta.url), 'utf8');
const STOREKIT_ROOTS = [readFileSync(new URL('./apple-root-ca-g3.pem', import.meta.url), 'utf8')];
const ANTHROPIC_URL = 'https://api.anthropic.com/v1/messages';
const SONIOX_TEMP_KEY_URL = 'https://api.soniox.com/v1/auth/temporary-api-key';
const MAX_BODY_BYTES = 8 * 1024 * 1024;

const env = (name, fallback) => process.env[name] ?? fallback;
const intEnv = (name, fallback) => Number.parseInt(env(name, ''), 10) || fallback;
const config = {
  appId: env('APP_ID'),
  allowDevelopment: env('ALLOW_DEVELOPMENT_ATTESTATION', 'false') === 'true',
  allowedModels: env('ALLOWED_MODELS', '').split(',').map((s) => s.trim()).filter(Boolean),
  maxTokensCap: intEnv('MAX_TOKENS_CAP', 16384),
  sessionTtl: intEnv('SESSION_TTL_SECONDS', 3600),
  llmPerMinute: intEnv('LLM_PER_MINUTE', 20),
  llmPerDay: intEnv('LLM_PER_DAY', 500),
  sonioxKeysPerDay: intEnv('SONIOX_KEYS_PER_DAY', 200),
  sonioxMaxSession: intEnv('SONIOX_MAX_SESSION_SECONDS', 10800),
  challengesPerMinutePerIp: intEnv('CHALLENGES_PER_MINUTE_PER_IP', 30),
  proProductIds: env('PRO_PRODUCT_IDS', '').split(',').map((s) => s.trim()).filter(Boolean),
  freeLimitCooldown: intEnv('FREE_LIMIT_COOLDOWN_SECONDS', 300),
  maxDevicesPerSubscription: intEnv('MAX_DEVICES_PER_SUBSCRIPTION', 5),
};
config.bundleId = (config.appId ?? '').split('.').slice(1).join('.');

// ---- secrets (cached per container for a few minutes, so a rotated key takes effect) -----------

const secretsClient = new SecretsManagerClient({});
const secretsTtlMs = Number.parseInt(env('SECRETS_TTL_SECONDS', '300'), 10) * 1000;
let secretsCache;   // { promise, loadedAt }
function secrets() {
  if (!secretsCache || Date.now() - secretsCache.loadedAt >= secretsTtlMs) {
    const promise = secretsClient
      .send(new GetSecretValueCommand({ SecretId: env('SECRET_ARN') }))
      .then(({ SecretString }) => JSON.parse(SecretString))
      .catch((e) => { secretsCache = undefined; throw e; });
    secretsCache = { promise, loadedAt: Date.now() };
  }
  return secretsCache.promise;
}

// ---- responses ----------------------------------------------------------------------------------

class HttpError extends Error {
  constructor(status, type, message) {
    super(message);
    this.status = status;
    this.type = type;
  }
}

const json = (status, body) => ({
  status,
  headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
  body: JSON.stringify(body),
});
const errorBody = (status, type, message) => json(status, { error: { type, message } });

// ---- routes -------------------------------------------------------------------------------------

export async function route(event) {
  const method = event.requestContext?.http?.method;
  const path = event.rawPath;
  try {
    if (method !== 'POST') throw new HttpError(405, 'method_not_allowed', 'use POST');
    switch (path) {
      case '/v1/attest/challenge': return await issueChallenge(event);
      case '/v1/attest/register': return await registerKey(event);
      case '/v1/session': return await openSession(event);
      case '/v1/session/dev': return await openDevSession(event);
      case '/v1/messages': return await relayMessages(event);
      case '/v1/soniox/temporary-key': return await sonioxTemporaryKey(event);
      default: throw new HttpError(404, 'not_found', 'unknown route');
    }
  } catch (e) {
    if (e instanceof HttpError) return errorBody(e.status, e.type, e.message);
    if (e instanceof RequestError) return errorBody(400, 'invalid_request', e.message);
    if (e instanceof AttestationError) {
      console.warn('attestation rejected:', e.message);
      return errorBody(401, 'attestation_failed', e.message);
    }
    console.error('unhandled error', e);
    return errorBody(500, 'internal_error', 'internal error');
  }
}

async function issueChallenge(event) {
  const ip = event.requestContext?.http?.sourceIp ?? 'unknown';
  if (!(await store.hit(`ip#${ip}`, config.challengesPerMinutePerIp, 60))) {
    throw new HttpError(429, 'rate_limited', 'too many challenges');
  }
  const challenge = randomBytes(32).toString('base64url');
  await store.putChallenge(challenge, 300);
  return json(200, { challenge });
}

async function registerKey(event) {
  const { keyId, attestation, challenge } = readJson(event);
  requireStrings({ keyId, attestation, challenge });
  if (!(await store.consumeChallenge(challenge))) throw new HttpError(401, 'bad_challenge', 'challenge unknown or expired');
  const verified = verifyAttestation({
    attestation, keyId, challenge,
    appId: config.appId, rootPem: ROOT_CA, allowDevelopment: config.allowDevelopment,
  });
  // Never replace a registered key's public key; the app generates a new key id instead.
  if (!(await store.putKey(keyId, verified))) throw new HttpError(409, 'key_exists', 'key already registered');
  return json(201, { ok: true, environment: verified.environment });
}

async function openSession(event) {
  const { keyId, assertion, challenge, appTransaction, subscription } = readJson(event);
  requireStrings({ keyId, assertion, challenge });
  for (const [name, value] of Object.entries({ appTransaction, subscription })) {
    if (value !== undefined && (typeof value !== 'string' || value.length > 32768)) {
      throw new RequestError(`${name} must be a JWS string`);
    }
  }
  if (!(await store.consumeChallenge(challenge))) throw new HttpError(401, 'bad_challenge', 'challenge unknown or expired');
  const key = await store.getKey(keyId);
  if (!key) throw new HttpError(404, 'unknown_key', 'key not registered');
  if (key.revoked) throw new HttpError(403, 'key_revoked', 'key revoked');
  const { counter } = verifyAssertion({
    assertion, challenge, publicKeyPem: key.publicKeyPem, previousCounter: key.counter, appId: config.appId,
  });
  if (!(await store.advanceCounter(keyId, counter))) throw new HttpError(401, 'replayed_assertion', 'stale assertion');

  const access = resolveTier({
    attestEnvironment: key.environment, appTransaction, subscription,
    bundleId: config.bundleId, productIds: config.proProductIds, rootPems: STOREKIT_ROOTS,
  });
  let { tier } = access;
  let ttl = config.sessionTtl;
  if (tier === 'pro') {
    // One purchase, a handful of devices — not a key to hand around.
    if (!(await store.bindSubscriptionDevice(access.originalTransactionId, keyId, config.maxDevicesPerSubscription))) {
      console.warn('subscription used on too many devices:', access.originalTransactionId);
      tier = 'free';
    } else {
      ttl = Math.max(60, Math.min(ttl, Math.floor((access.expiresAt - Date.now()) / 1000)));
    }
  }
  const { session_secret: secret } = await secrets();
  const token = signSession({ kid: keyId, env: key.environment, tier, ttlSeconds: ttl, secret });
  return json(200, { token, expiresIn: ttl, tier });
}

/** Simulator / debug builds only: App Attest isn't available there. Off unless dev_token is set. */
async function openDevSession(event) {
  const { session_secret: secret, dev_token: devToken } = await secrets();
  const given = Buffer.from(event.headers?.['x-dev-token'] ?? '');
  const expected = Buffer.from(devToken ?? '');
  if (expected.length === 0 || given.length !== expected.length || !timingSafeEqual(given, expected)) {
    throw new HttpError(401, 'unauthorized', 'dev sessions are disabled or the token is wrong');
  }
  const token = signSession({ kid: 'dev', env: 'dev', tier: 'beta', ttlSeconds: config.sessionTtl, secret });
  return json(200, { token, expiresIn: config.sessionTtl, tier: 'beta' });
}

async function authorize(event) {
  const header = event.headers?.authorization ?? '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : '';
  const { session_secret: secret } = await secrets();
  const claims = verifySession(token, secret);
  if (!claims) throw new HttpError(401, 'invalid_session', 'session missing or expired');
  return claims;
}

const subscriptionRequired = (message, retryAfter) => ({
  status: 402,
  headers: {
    'content-type': 'application/json', 'cache-control': 'no-store',
    ...(retryAfter ? { 'retry-after': String(retryAfter) } : {}),
  },
  body: JSON.stringify({ error: { type: 'subscription_required', message, ...(retryAfter ? { retry_after: retryAfter } : {}) } }),
});

async function relayMessages(event) {
  const { kid, tier = 'free' } = await authorize(event);
  if (!(await store.hit(`llm-min#${kid}`, config.llmPerMinute, 60))) {
    throw new HttpError(429, 'rate_limited', 'too many requests this minute');
  }
  if (!(await store.hit(`llm-day#${kid}`, config.llmPerDay, 86400))) {
    throw new HttpError(429, 'rate_limited', 'daily request limit reached');
  }
  const body = validateMessagesRequest(readJson(event), config);

  // Free tier: translations are free; everything else (explanations, Say it) once per cooldown.
  let cooldown;
  if (tier === 'free' && !isFreeRequest(body)) {
    cooldown = await store.claimCooldown(`free-limit#${kid}`, config.freeLimitCooldown);
    if (!cooldown.ok) return subscriptionRequired('free plan: one explanation or Say it request per 5 minutes', cooldown.retryAfter);
  }
  const giveBack = () => cooldown?.ok && store.releaseCooldown(`free-limit#${kid}`, cooldown.claimedAt);
  const { anthropic_api_key: apiKey } = await secrets();

  let upstream;
  try {
    upstream = await fetch(ANTHROPIC_URL, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-api-key': apiKey, 'anthropic-version': '2023-06-01' },
      body: JSON.stringify(body),
    });
  } catch (e) {
    console.error('anthropic unreachable', e);
    await giveBack();
    throw new HttpError(502, 'upstream_unreachable', 'model service unreachable');
  }
  if (!upstream.ok) await giveBack();   // a failed call shouldn't cost the free use
  // Our own key failing is a server problem, not the app's session: never pass a 401/403 through,
  // or the app would throw away a perfectly good session.
  if (upstream.status === 401 || upstream.status === 403) {
    console.error('anthropic rejected the server key', upstream.status, await upstream.text());
    throw new HttpError(502, 'upstream_auth', 'model service rejected the server credentials');
  }
  const headers = { 'content-type': upstream.headers.get('content-type') ?? 'application/json', 'cache-control': 'no-store' };
  const retryAfter = upstream.headers.get('retry-after');
  if (retryAfter) headers['retry-after'] = retryAfter;
  return { status: upstream.status, headers, stream: upstream.body };
}

async function sonioxTemporaryKey(event) {
  const { kid, tier = 'free' } = await authorize(event);
  if (tier !== 'pro' && tier !== 'beta') return subscriptionRequired('live translation needs a subscription');
  if (!(await store.hit(`soniox-day#${kid}`, config.sonioxKeysPerDay, 86400))) {
    throw new HttpError(429, 'rate_limited', 'daily live-session limit reached');
  }
  const { soniox_api_key: apiKey } = await secrets();
  let response;
  try {
    response = await fetch(SONIOX_TEMP_KEY_URL, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: `Bearer ${apiKey}` },
      body: JSON.stringify({
        usage_type: 'transcribe_websocket',
        expires_in_seconds: 60,
        single_use: true,
        max_session_duration_seconds: config.sonioxMaxSession,
        client_reference_id: kid.slice(0, 64),
      }),
    });
  } catch (e) {
    console.error('soniox unreachable', e);
    throw new HttpError(502, 'upstream_unreachable', 'speech service unreachable');
  }
  if (!response.ok) {
    console.error('soniox temporary key failed', response.status, await response.text());
    throw new HttpError(502, 'upstream_error', 'speech service refused the request');
  }
  const { api_key: key, expires_at: expiresAt } = await response.json();
  return json(200, { api_key: key, expires_at: expiresAt });
}

// ---- request parsing ----------------------------------------------------------------------------

function readJson(event) {
  let raw = Buffer.from(event.body ?? '', event.isBase64Encoded ? 'base64' : 'utf8');
  if ((event.headers?.['content-encoding'] ?? '').toLowerCase() === 'gzip') {
    try {
      raw = gunzipSync(raw, { maxOutputLength: MAX_BODY_BYTES });
    } catch {
      throw new RequestError('body is not valid gzip or is too large');
    }
  }
  if (raw.length > MAX_BODY_BYTES) throw new RequestError('body too large');
  try {
    return JSON.parse(raw.toString('utf8'));
  } catch {
    throw new RequestError('body is not valid JSON');
  }
}

function requireStrings(fields) {
  for (const [name, value] of Object.entries(fields)) {
    if (typeof value !== 'string' || value.length === 0 || value.length > 16384) {
      throw new RequestError(`${name} must be a non-empty string`);
    }
  }
}

// ---- Lambda entry point (streaming Function URL) ------------------------------------------------

// `awslambda` is a global of the Lambda Node.js runtime; outside it (tests) only `route` is used.
const lambda = globalThis.awslambda;
export const handler = typeof lambda?.streamifyResponse !== 'function' ? undefined : lambda.streamifyResponse(async (event, responseStream) => {
  const result = await route(event);
  const out = lambda.HttpResponseStream.from(responseStream, {
    statusCode: result.status,
    headers: result.headers,
  });
  if (result.stream) {
    await pipeline(Readable.fromWeb(result.stream), out);
  } else {
    out.write(result.body ?? '');
    out.end();
  }
});
