import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { X509Certificate } from 'node:crypto';

import { verifyAppleJws, resolveTier, SignedDataError } from '../src/storekit.mjs';
import { makeStoreKitSigner } from './helpers.mjs';

const bundleId = 'tech.10xt.englishhelper';
const productIds = ['tech.10xt.englishhelper.pro.monthly'];
const signer = makeStoreKitSigner();
const rootPems = [signer.rootPem];
const quiet = { warn() {} };
const now = Date.now();

const appTx = (receiptType, extra = {}) => signer.sign({ bundleId, receiptType, receiptCreationDate: now, ...extra });
const subTx = (extra = {}) => signer.sign({
  bundleId, productId: productIds[0], environment: 'Production', originalTransactionId: '2000000123',
  expiresDate: now + 86400_000, signedDate: now, type: 'Auto-Renewable Subscription', ...extra,
});
const tier = (args) => resolveTier({ bundleId, productIds, rootPems, now, log: quiet, ...args });

test('verifies a StoreKit JWS and returns its payload', () => {
  const payload = verifyAppleJws(appTx('Production'), { rootPems });
  assert.equal(payload.bundleId, bundleId);
});

test('rejects tampering, foreign roots and unmarked chains', () => {
  const jws = appTx('Production');
  const [h, p, s] = jws.split('.');
  const forged = Buffer.from(JSON.stringify({ bundleId, receiptType: 'Sandbox' })).toString('base64url');
  assert.throws(() => verifyAppleJws(`${h}.${forged}.${s}`, { rootPems }), /bad JWS signature/);
  assert.throws(() => verifyAppleJws(jws, { rootPems: [makeStoreKitSigner().rootPem] }), /trusted Apple root/);
  const unmarked = makeStoreKitSigner({ markers: false });
  assert.throws(() => verifyAppleJws(unmarked.sign({ bundleId }), { rootPems: [unmarked.rootPem] }), /markers/);
  assert.throws(() => verifyAppleJws('a.b', { rootPems }), SignedDataError);
});

test('Xcode builds (App Attest development) are beta', () => {
  assert.equal(tier({ attestEnvironment: 'development' }).tier, 'beta');
});

test('TestFlight / Xcode receipts are beta — no subscription needed', () => {
  assert.equal(tier({ attestEnvironment: 'production', appTransaction: appTx('Sandbox') }).tier, 'beta');
  assert.equal(tier({ attestEnvironment: 'production', appTransaction: appTx('Xcode') }).tier, 'beta');
});

test('App Store build with an active subscription is pro', () => {
  const result = tier({ attestEnvironment: 'production', appTransaction: appTx('Production'), subscription: subTx() });
  assert.equal(result.tier, 'pro');
  assert.equal(result.originalTransactionId, '2000000123');
});

test('App Store build without a valid subscription is free', () => {
  const base = { attestEnvironment: 'production', appTransaction: appTx('Production') };
  assert.equal(tier(base).tier, 'free');
  assert.equal(tier({ ...base, subscription: subTx({ expiresDate: now - 1000 }) }).tier, 'free');
  assert.equal(tier({ ...base, subscription: subTx({ revocationDate: now - 1000 }) }).tier, 'free');
  assert.equal(tier({ ...base, subscription: subTx({ productId: 'other' }) }).tier, 'free');
  assert.equal(tier({ ...base, subscription: subTx({ environment: 'Sandbox' }) }).tier, 'free');
  assert.equal(tier({ ...base, subscription: subTx({ bundleId: 'com.other' }) }).tier, 'free');
  assert.equal(tier({ ...base, subscription: 'garbage' }).tier, 'free');
});

test('no or foreign app transaction is free', () => {
  assert.equal(tier({ attestEnvironment: 'production' }).tier, 'free');
  assert.equal(tier({ attestEnvironment: 'production', appTransaction: appTx('Sandbox', { bundleId: 'com.other' }) }).tier, 'free');
  assert.equal(tier({ attestEnvironment: 'production', appTransaction: 'x.y.z' }).tier, 'free');
});

test('the bundled Apple Root CA - G3 parses', () => {
  const pem = readFileSync(new URL('../src/apple-root-ca-g3.pem', import.meta.url), 'utf8');
  assert.ok(new X509Certificate(pem).subject.includes('Apple Root CA - G3'));
});
