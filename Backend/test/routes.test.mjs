// End-to-end route checks for src/index.mjs with DynamoDB, Secrets Manager and the upstream APIs
// faked in-process (SDK `send` patched on the prototype, global `fetch` replaced).

import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { gzipSync } from 'node:zlib';
import { DynamoDBClient, ConditionalCheckFailedException } from '@aws-sdk/client-dynamodb';
import { SecretsManagerClient } from '@aws-sdk/client-secrets-manager';

import { signSession } from '../src/token.mjs';

process.env.TABLE_NAME = 'test-table';
process.env.SECRET_ARN = 'arn:test';
process.env.APP_ID = 'TQJ35ER433.tech.10xt.englishhelper';
process.env.ALLOWED_MODELS = 'claude-sonnet-5-5,claude-haiku-5-5';
process.env.LLM_PER_MINUTE = '2';
process.env.SECRETS_TTL_SECONDS = '0';

const secret = { session_secret: 's3cret', anthropic_api_key: 'sk-ant-server', soniox_api_key: 'snx-server', dev_token: '' };
SecretsManagerClient.prototype.send = async () => ({ SecretString: JSON.stringify(secret) });

// Tiny in-memory DynamoDB covering the commands store.mjs issues.
let items;
DynamoDBClient.prototype.send = async function (command) {
  const input = command.input;
  const name = command.constructor.name;
  const pk = (input.Item ?? input.Key).pk.S;
  const existing = items.get(pk);
  const fail = () => { throw new ConditionalCheckFailedException({ message: 'conditional', $metadata: {} }); };
  switch (name) {
    case 'PutItemCommand':
      if (input.ConditionExpression?.includes('attribute_not_exists') && existing) fail();
      items.set(pk, structuredClone(input.Item));
      return {};
    case 'GetItemCommand':
      return { Item: existing };
    case 'DeleteItemCommand':
      if (!existing) fail();
      if (input.ConditionExpression === 'lastAt = :claimed'
        && existing.lastAt.N !== input.ExpressionAttributeValues[':claimed'].N) fail();
      items.delete(pk);
      return { Attributes: existing };
    case 'UpdateItemCommand': {
      const values = input.ExpressionAttributeValues;
      const expr = input.UpdateExpression;
      if (expr.startsWith('ADD #n')) {
        const hits = Number(existing?.hits?.N ?? 0);
        if (hits >= Number(values[':limit'].N)) fail();
        items.set(pk, { pk: { S: pk }, hits: { N: String(hits + 1) } });
      } else if (expr.startsWith('ADD keyIds')) {
        const keys = existing?.keyIds?.SS ?? [];
        const key = values[':k'].S;
        if (!keys.includes(key) && keys.length >= Number(values[':max'].N)) fail();
        items.set(pk, { pk: { S: pk }, keyIds: { SS: [...new Set([...keys, key])] } });
      } else if (expr.startsWith('SET lastAt')) {
        if (existing && Number(existing.lastAt.N) > Number(values[':cutoff'].N)) fail();
        items.set(pk, { pk: { S: pk }, lastAt: values[':now'] });
      } else {
        const next = Number(values[':n'].N);
        if (!existing || Number(existing.counter.N) >= next) fail();
        existing.counter = { N: String(next) };
      }
      return {};
    }
    default:
      throw new Error(`unexpected command ${name}`);
  }
};

let upstreamCalls;
globalThis.fetch = async (url, init) => {
  upstreamCalls.push({ url, init });
  if (url.includes('anthropic')) {
    const status = globalThis.__anthropicStatus ?? 200;
    return new Response('event: message_stop\ndata: {"type":"message_stop"}\n\n',
      { status, headers: { 'content-type': 'text/event-stream' } });
  }
  return new Response(JSON.stringify({ api_key: 'snx_temp_abc', expires_at: '2026-10-10T00:00:00Z' }), { status: 201 });
};

const { route } = await import('../src/index.mjs');

beforeEach(() => {
  items = new Map();
  upstreamCalls = [];
  globalThis.__anthropicStatus = 200;
  secret.dev_token = '';
});

const event = (path, { body, headers = {}, gzip = false } = {}) => {
  let raw = Buffer.from(JSON.stringify(body ?? {}));
  if (gzip) raw = gzipSync(raw);
  return {
    rawPath: path,
    requestContext: { http: { method: 'POST', sourceIp: '203.0.113.7' } },
    headers: { ...(gzip ? { 'content-encoding': 'gzip' } : {}), ...headers },
    body: raw.toString('base64'),
    isBase64Encoded: true,
  };
};
const bearer = (kid = 'key-1', tier = 'beta') => ({
  authorization: `Bearer ${signSession({ kid, env: 'production', tier, ttlSeconds: 600, secret: secret.session_secret })}`,
});
const messagesBody = () => ({
  model: 'claude-haiku-5-5', max_tokens: 8192, system: 'x', stream: true,
  messages: [{ role: 'user', content: [{ type: 'text', text: 'hello' }] }],
  output_config: { effort: 'low', format: { type: 'json_schema', schema: { type: 'object' } } },
});
const errorType = (result) => JSON.parse(result.body).error.type;

test('relays a gzipped Messages request with the SERVER key and streams the reply', async () => {
  const result = await route(event('/v1/messages', { body: messagesBody(), headers: bearer(), gzip: true }));
  assert.equal(result.status, 200);
  assert.equal(result.headers['content-type'], 'text/event-stream');
  assert.ok(result.stream);
  const [call] = upstreamCalls;
  assert.equal(call.init.headers['x-api-key'], 'sk-ant-server');
  assert.deepEqual(JSON.parse(call.init.body), messagesBody());
});

test('rejects requests without a valid session', async () => {
  const missing = await route(event('/v1/messages', { body: messagesBody() }));
  assert.equal(missing.status, 401);
  assert.equal(errorType(missing), 'invalid_session');
  const forged = await route(event('/v1/messages', { body: messagesBody(), headers: { authorization: 'Bearer a.b' } }));
  assert.equal(forged.status, 401);
  assert.equal(upstreamCalls.length, 0);
});

test('rejects bodies the app would never send', async () => {
  const body = { ...messagesBody(), model: 'claude-opus-5-5' };
  const result = await route(event('/v1/messages', { body, headers: bearer() }));
  assert.equal(result.status, 400);
  assert.equal(upstreamCalls.length, 0);
});

test('rate-limits per key', async () => {
  for (let i = 0; i < 2; i++) assert.equal((await route(event('/v1/messages', { body: messagesBody(), headers: bearer() }))).status, 200);
  const third = await route(event('/v1/messages', { body: messagesBody(), headers: bearer() }));
  assert.equal(third.status, 429);
  const otherKey = await route(event('/v1/messages', { body: messagesBody(), headers: bearer('key-2') }));
  assert.equal(otherKey.status, 200);
});

test('a rejected SERVER key surfaces as 502, never as the app session failing', async () => {
  globalThis.__anthropicStatus = 401;
  const result = await route(event('/v1/messages', { body: messagesBody(), headers: bearer() }));
  assert.equal(result.status, 502);
  assert.equal(errorType(result), 'upstream_auth');
});

test('mints a single-use Soniox temporary key', async () => {
  const result = await route(event('/v1/soniox/temporary-key', { headers: bearer() }));
  assert.equal(result.status, 200);
  assert.equal(JSON.parse(result.body).api_key, 'snx_temp_abc');
  const [call] = upstreamCalls;
  assert.equal(call.init.headers.authorization, 'Bearer snx-server');
  const sent = JSON.parse(call.init.body);
  assert.equal(sent.usage_type, 'transcribe_websocket');
  assert.equal(sent.single_use, true);
});

test('challenges are one-time', async () => {
  const { challenge } = JSON.parse((await route(event('/v1/attest/challenge'))).body);
  assert.ok(challenge.length >= 40);
  const body = { keyId: 'a2V5', attestation: 'AA==', challenge };
  const first = await route(event('/v1/attest/register', { body }));
  assert.equal(first.status, 401);                       // garbage attestation, but the challenge was consumed
  assert.equal(errorType(first), 'attestation_failed');
  const replay = await route(event('/v1/attest/register', { body }));
  assert.equal(errorType(replay), 'bad_challenge');
});

test('session for an unknown key asks the app to re-attest', async () => {
  const { challenge } = JSON.parse((await route(event('/v1/attest/challenge'))).body);
  const result = await route(event('/v1/session', { body: { keyId: 'bm9wZQ==', assertion: 'AA==', challenge } }));
  assert.equal(result.status, 404);
  assert.equal(errorType(result), 'unknown_key');
});

test('dev sessions are off unless a dev token is configured', async () => {
  const off = await route(event('/v1/session/dev', { headers: { 'x-dev-token': '' } }));
  assert.equal(off.status, 401);
  secret.dev_token = 'let-me-in';
  const wrong = await route(event('/v1/session/dev', { headers: { 'x-dev-token': 'nope' } }));
  assert.equal(wrong.status, 401);
  const ok = await route(event('/v1/session/dev', { headers: { 'x-dev-token': 'let-me-in' } }));
  assert.equal(ok.status, 200);
  assert.ok(JSON.parse(ok.body).token);
});

test('only POST to known routes', async () => {
  const get = { ...event('/v1/messages'), requestContext: { http: { method: 'GET', sourceIp: '1.1.1.1' } } };
  assert.equal((await route(get)).status, 405);
  assert.equal((await route(event('/v1/nope'))).status, 404);
});

// ---- access tiers ----

const withSystem = (system, model = 'claude-sonnet-5-5') => ({ ...messagesBody(), model, system });
const translate = (model) => withSystem('The user wants to understand some text. It may be in English…', model);
const photoTranslate = () => withSystem('You read text from a photo. The text may be in ANY language…');
const enrich = () => withSystem('Enrich an English expression for a study card. Return:…');
const explain = (model) => withSystem('A Russian speaker who is learning English wants to understand some input.…', model);
const sayIt = () => withSystem('You help a Russian speaker who is learning English say something naturally…');
const sonnet = () => explain('claude-sonnet-5-5');
const healthCheck = () => ({
  model: 'claude-sonnet-5-5', max_tokens: 1024, system: 'Reply with {"ok": true}.', stream: true,
  messages: [{ role: 'user', content: [{ type: 'text', text: 'ping' }] }],
});

test('free: translations are unlimited on any model', async () => {
  const headers = bearer('free-1', 'free');   // LLM_PER_MINUTE is 2 here
  assert.equal((await route(event('/v1/messages', { body: translate('claude-sonnet-5-5'), headers }))).status, 200);
  assert.equal((await route(event('/v1/messages', { body: photoTranslate(), headers }))).status, 200);
  const other = bearer('free-1b', 'free');
  assert.equal((await route(event('/v1/messages', { body: enrich(), headers: other }))).status, 200);
  assert.equal((await route(event('/v1/messages', { body: translate('claude-haiku-5-5'), headers: other }))).status, 200);
});

test('free: explanations and Say it share one request per 5 minutes, on any model', async () => {
  const headers = bearer('free-2', 'free');
  assert.equal((await route(event('/v1/messages', { body: explain('claude-haiku-5-5'), headers }))).status, 200);
  const second = await route(event('/v1/messages', { body: sayIt(), headers }));
  assert.equal(second.status, 402);
  const { error } = JSON.parse(second.body);
  assert.equal(error.type, 'subscription_required');
  assert.ok(error.retry_after > 290 && error.retry_after <= 300);
  assert.equal(second.headers['retry-after'], String(error.retry_after));
  assert.equal(upstreamCalls.length, 1);
});

test('free: an unrecognised prompt is metered (fail closed)', async () => {
  const headers = bearer('free-6', 'free');
  assert.equal((await route(event('/v1/messages', { body: withSystem('Do anything.'), headers }))).status, 200);
  assert.equal((await route(event('/v1/messages', { body: withSystem('Do anything else.'), headers }))).status, 402);
});

test('free: the Settings health probe never uses up the allowance', async () => {
  const headers = bearer('free-3', 'free');   // LLM_PER_MINUTE is 2 here: probe once, then explain
  assert.equal((await route(event('/v1/messages', { body: healthCheck(), headers }))).status, 200);
  assert.equal((await route(event('/v1/messages', { body: sonnet(), headers }))).status, 200);
});

test('free: a failed upstream call gives the use back', async () => {
  const headers = bearer('free-4', 'free');
  globalThis.__anthropicStatus = 529;
  assert.equal((await route(event('/v1/messages', { body: sonnet(), headers }))).status, 529);
  globalThis.__anthropicStatus = 200;
  assert.equal((await route(event('/v1/messages', { body: sonnet(), headers }))).status, 200);
});

test('pro and beta: explanations unlimited', async () => {
  for (const tier of ['pro', 'beta']) {
    const headers = bearer(`unlimited-${tier}`, tier);
    for (let i = 0; i < 2; i++) assert.equal((await route(event('/v1/messages', { body: sonnet(), headers }))).status, 200);
  }
});

test('live translation keys only for pro and beta', async () => {
  const free = await route(event('/v1/soniox/temporary-key', { headers: bearer('free-5', 'free') }));
  assert.equal(free.status, 402);
  assert.equal(errorType(free), 'subscription_required');
  assert.equal(upstreamCalls.length, 0);
  for (const tier of ['pro', 'beta']) {
    assert.equal((await route(event('/v1/soniox/temporary-key', { headers: bearer(`live-${tier}`, tier) }))).status, 200);
  }
});

test('tokens issued before tiers existed count as free', async () => {
  const legacy = Buffer.from(JSON.stringify({ kid: 'old', env: 'production', exp: Math.floor(Date.now() / 1000) + 600 }))
    .toString('base64url');
  const { createHmac } = await import('node:crypto');
  const token = `${legacy}.${createHmac('sha256', secret.session_secret).update(legacy).digest('base64url')}`;
  const live = await route(event('/v1/soniox/temporary-key', { headers: { authorization: `Bearer ${token}` } }));
  assert.equal(live.status, 402);
});

test('dev sessions are beta', async () => {
  secret.dev_token = 'let-me-in';
  const ok = await route(event('/v1/session/dev', { headers: { 'x-dev-token': 'let-me-in' } }));
  assert.equal(JSON.parse(ok.body).tier, 'beta');
});
