import { test } from 'node:test';
import assert from 'node:assert/strict';

import { decodeCbor } from '../src/cbor.mjs';
import { signSession, verifySession } from '../src/token.mjs';
import { validateMessagesRequest, RequestError } from '../src/validate.mjs';
import { encodeCbor } from './helpers.mjs';

// ---- CBOR ----

test('cbor round-trips the shapes App Attest uses', () => {
  const value = { fmt: 'apple-appattest', n: 300, neg: -5, list: [Buffer.from([1, 2, 3]), 'x'], nested: { ok: 1 } };
  const decoded = decodeCbor(encodeCbor(value));
  assert.equal(decoded.fmt, 'apple-appattest');
  assert.equal(decoded.n, 300);
  assert.equal(decoded.neg, -5);
  assert.deepEqual([...decoded.list[0]], [1, 2, 3]);
  assert.equal(decoded.nested.ok, 1);
});

test('cbor rejects truncated and trailing input', () => {
  const bytes = encodeCbor({ a: Buffer.alloc(10) });
  assert.throws(() => decodeCbor(bytes.subarray(0, bytes.length - 1)), /unexpected end/);
  assert.throws(() => decodeCbor(Buffer.concat([bytes, Buffer.from([0])])), /trailing/);
});

// ---- session tokens ----

test('session tokens verify, expire, and resist tampering', () => {
  const secret = 'test-secret';
  const now = Date.now();
  const token = signSession({ kid: 'key-1', env: 'production', ttlSeconds: 60, secret, now });
  assert.equal(verifySession(token, secret, now)?.kid, 'key-1');
  assert.equal(verifySession(token, secret, now + 61_000), null);
  assert.equal(verifySession(token, 'other-secret', now), null);
  const [payload, sig] = token.split('.');
  const forged = Buffer.from(JSON.stringify({ kid: 'key-2', env: 'production', exp: 9e9 })).toString('base64url');
  assert.equal(verifySession(`${forged}.${sig}`, secret, now), null);
  assert.equal(verifySession(`${payload}.${sig}.x`, secret, now), null);
  assert.equal(verifySession(undefined, secret, now), null);
});

// ---- request validation ----

const limits = { allowedModels: ['claude-sonnet-5-5', 'claude-haiku-5-5'], maxTokensCap: 16384 };
const validBody = () => ({
  model: 'claude-haiku-5-5',
  max_tokens: 8192,
  system: 'You translate.',
  stream: true,
  messages: [{ role: 'user', content: [
    { type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: 'AAAA' } },
    { type: 'text', text: 'hello' },
  ] }],
  output_config: { effort: 'low', format: { type: 'json_schema', schema: { type: 'object' } } },
});

test('accepts exactly what the app sends', () => {
  assert.doesNotThrow(() => validateMessagesRequest(validBody(), limits));
});

test('rejects anything that widens the proxy beyond the app', () => {
  const cases = [
    (b) => { b.model = 'claude-opus-5-5'; },
    (b) => { b.max_tokens = 100000; },
    (b) => { b.tools = [{ name: 'x' }]; },
    (b) => { b.messages.push({ role: 'assistant', content: [{ type: 'text', text: 'hi' }] }); },
    (b) => { b.messages[0].role = 'assistant'; },
    (b) => { b.messages[0].content.push({ type: 'document', source: {} }); },
    (b) => { b.messages[0].content.push({ type: 'image', source: { type: 'url', url: 'https://x' } }); },
    (b) => { b.output_config.effort = 'max'; },
    (b) => { b.output_config.task_budget = { type: 'tokens', total: 1 }; },
    (b) => { b.thinking = { type: 'enabled', budget_tokens: 9000 }; },
    (b) => { b.system = [{ type: 'text', text: 'x' }]; },
  ];
  for (const mutate of cases) {
    const body = validBody();
    mutate(body);
    assert.throws(() => validateMessagesRequest(body, limits), RequestError, JSON.stringify(body).slice(0, 120));
  }
});
