import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createSign } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { X509Certificate } from 'node:crypto';

import { verifyAttestation, verifyAssertion, AttestationError } from '../src/appattest.mjs';
import { makeAttestation, encodeCbor, authenticatorData, sha256, AAGUID_DEVELOPMENT } from './helpers.mjs';

const appId = 'TQJ35ER433.tech.10xt.englishhelper';
const challenge = 'c2VydmVyLWlzc3VlZC1jaGFsbGVuZ2U';

const verify = (a, overrides = {}) => verifyAttestation({
  attestation: a.attestation, keyId: a.keyId, challenge, appId, rootPem: a.rootPem,
  allowDevelopment: false, ...overrides,
});

test('accepts a well-formed production attestation', () => {
  const a = makeAttestation({ appId, challenge });
  const result = verify(a);
  assert.equal(result.environment, 'production');
  assert.equal(result.publicKeyPem, a.publicKeyPem);
});

test('rejects a different challenge (nonce mismatch)', () => {
  const a = makeAttestation({ appId, challenge });
  assert.throws(() => verify(a, { challenge: 'another-challenge' }), AttestationError);
});

test('rejects an attestation for another app', () => {
  const a = makeAttestation({ appId, challenge, tamper: { appId: 'XXXXXXXXXX.com.example.other' } });
  assert.throws(() => verify(a), /app id mismatch|nonce/);
});

test('rejects a key id that is not the credential key', () => {
  const a = makeAttestation({ appId, challenge });
  const other = makeAttestation({ appId, challenge });
  assert.throws(() => verify(a, { keyId: other.keyId }), /key identifier mismatch/);
});

test('rejects a chain that does not end at the trusted root', () => {
  const a = makeAttestation({ appId, challenge });
  const appleRoot = readFileSync(new URL('../src/apple-app-attestation-root-ca.pem', import.meta.url), 'utf8');
  assert.throws(() => verify(a, { rootPem: appleRoot }), /not signed by the App Attest root/);
});

test('rejects a non-zero attestation counter', () => {
  const a = makeAttestation({ appId, challenge, tamper: { counter: 1 } });
  assert.throws(() => verify(a), /counter must be zero/);
});

test('development environment only when allowed', () => {
  const a = makeAttestation({ appId, challenge, aaguid: AAGUID_DEVELOPMENT });
  assert.throws(() => verify(a), /environment/);
  assert.equal(verify(a, { allowDevelopment: true }).environment, 'development');
});

test('rejects expired certificates', () => {
  const a = makeAttestation({ appId, challenge });
  assert.throws(() => verify(a, { now: new Date(Date.now() + 10 * 86400_000) }), /validity/);
});

test('the bundled Apple root parses and is self-signed', () => {
  const pem = readFileSync(new URL('../src/apple-app-attestation-root-ca.pem', import.meta.url), 'utf8');
  const root = new X509Certificate(pem);
  assert.ok(root.subject.includes('Apple App Attestation Root CA'));
  assert.ok(root.verify(root.publicKey));
});

// ---- assertions ----

function makeAssertion(privateKey, { counter, appIdForData = appId, clientChallenge = challenge }) {
  const authData = authenticatorData({ appId: appIdForData, counter });
  const nonce = sha256(authData, sha256(Buffer.from(clientChallenge, 'utf8')));
  const signer = createSign('sha256');
  signer.update(nonce);
  return encodeCbor({ signature: signer.sign(privateKey), authenticatorData: authData }).toString('base64');
}

test('accepts a valid assertion and returns its counter', () => {
  const a = makeAttestation({ appId, challenge });
  const assertion = makeAssertion(a.privateKey, { counter: 1 });
  const { counter } = verifyAssertion({ assertion, challenge, publicKeyPem: a.publicKeyPem, previousCounter: 0, appId });
  assert.equal(counter, 1);
});

test('rejects a replayed (non-increasing) counter', () => {
  const a = makeAttestation({ appId, challenge });
  const assertion = makeAssertion(a.privateKey, { counter: 3 });
  assert.throws(() => verifyAssertion({ assertion, challenge, publicKeyPem: a.publicKeyPem, previousCounter: 3, appId }),
    /counter did not increase/);
});

test('rejects an assertion over a different challenge', () => {
  const a = makeAttestation({ appId, challenge });
  const assertion = makeAssertion(a.privateKey, { counter: 1, clientChallenge: 'old-challenge' });
  assert.throws(() => verifyAssertion({ assertion, challenge, publicKeyPem: a.publicKeyPem, previousCounter: 0, appId }),
    /bad assertion signature/);
});

test('rejects an assertion signed by another key', () => {
  const a = makeAttestation({ appId, challenge });
  const b = makeAttestation({ appId, challenge });
  const assertion = makeAssertion(b.privateKey, { counter: 1 });
  assert.throws(() => verifyAssertion({ assertion, challenge, publicKeyPem: a.publicKeyPem, previousCounter: 0, appId }),
    /bad assertion signature/);
});

test('rejects an assertion for another app', () => {
  const a = makeAttestation({ appId, challenge });
  const assertion = makeAssertion(a.privateKey, { counter: 1, appIdForData: 'XXXXXXXXXX.com.example.other' });
  assert.throws(() => verifyAssertion({ assertion, challenge, publicKeyPem: a.publicKeyPem, previousCounter: 0, appId }),
    /app id mismatch/);
});
