// StoreKit 2 signed data (JWS) verification and the access tier it grants. Mirrors Apple's
// app-store-server-library: x5c chain leaf → intermediate → trusted Apple Root CA - G3, Apple's
// marker OIDs on leaf and intermediate, ES256 signature, cert dates checked at the signed date.
//
// Tiers:
//   beta  — Xcode builds (App Attest development) and TestFlight (AppTransaction "Sandbox"/"Xcode"):
//           everything unlimited; the subscription only exists for the App Store version.
//   pro   — App Store build with an active, unrevoked subscription transaction.
//   free  — everything else.

import { X509Certificate, verify as verifySignature } from 'node:crypto';

const LEAF_OID = Buffer.from([0x06, 0x0a, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x06, 0x0b, 0x01]);         // 1.2.840.113635.100.6.11.1
const INTERMEDIATE_OID = Buffer.from([0x06, 0x0a, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x06, 0x02, 0x01]); // 1.2.840.113635.100.6.2.1
const MAX_SKEW_MS = 60_000;

export class SignedDataError extends Error {}

/** Verifies an Apple-signed JWS and returns its decoded payload. */
export function verifyAppleJws(jws, { rootPems, dateOf = (payload) => payload.signedDate ?? payload.receiptCreationDate }) {
  if (typeof jws !== 'string') throw new SignedDataError('not a JWS');
  const parts = jws.split('.');
  if (parts.length !== 3) throw new SignedDataError('not a compact JWS');
  const [headerB64, payloadB64, signatureB64] = parts;
  let header, payload;
  try {
    header = JSON.parse(Buffer.from(headerB64, 'base64url').toString('utf8'));
    payload = JSON.parse(Buffer.from(payloadB64, 'base64url').toString('utf8'));
  } catch {
    throw new SignedDataError('malformed JWS');
  }
  if (header.alg !== 'ES256') throw new SignedDataError('unexpected JWS algorithm');
  if (!Array.isArray(header.x5c) || header.x5c.length < 2) throw new SignedDataError('JWS has no certificate chain');

  const leaf = new X509Certificate(Buffer.from(header.x5c[0], 'base64'));
  const intermediate = new X509Certificate(Buffer.from(header.x5c[1], 'base64'));
  const root = rootPems.map((pem) => new X509Certificate(pem))
    .find((r) => intermediate.issuer === r.subject && intermediate.verify(r.publicKey));
  if (!root) throw new SignedDataError('chain does not end at a trusted Apple root');
  if (leaf.issuer !== intermediate.subject || !leaf.verify(intermediate.publicKey)) {
    throw new SignedDataError('leaf certificate is not signed by the intermediate');
  }
  if (!leaf.raw.includes(LEAF_OID) || !intermediate.raw.includes(INTERMEDIATE_OID)) {
    throw new SignedDataError('certificates lack the Apple StoreKit markers');
  }
  const effective = new Date(dateOf(payload) ?? Date.now());
  for (const cert of [leaf, intermediate, root]) {
    if (new Date(cert.validFrom).getTime() > effective.getTime() + MAX_SKEW_MS
      || new Date(cert.validTo).getTime() < effective.getTime() - MAX_SKEW_MS) {
      throw new SignedDataError('certificate outside its validity period');
    }
  }
  const ok = verifySignature('sha256', Buffer.from(`${headerB64}.${payloadB64}`),
    { key: leaf.publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(signatureB64, 'base64url'));
  if (!ok) throw new SignedDataError('bad JWS signature');
  return payload;
}

/**
 * The access tier for a session. Never throws: unverifiable proofs just mean `free` (and a log line).
 * @returns {{ tier: 'beta'|'pro'|'free', expiresAt?: number, originalTransactionId?: string }}
 */
export function resolveTier({ attestEnvironment, appTransaction, subscription, bundleId, productIds, rootPems, now = Date.now(), log = console }) {
  if (attestEnvironment === 'development') return { tier: 'beta' };
  if (!appTransaction) return { tier: 'free' };
  let app;
  try {
    app = verifyAppleJws(appTransaction, { rootPems });
  } catch (e) {
    log.warn('app transaction rejected:', e.message);
    return { tier: 'free' };
  }
  if (app.bundleId !== bundleId) {
    log.warn('app transaction for another bundle:', app.bundleId);
    return { tier: 'free' };
  }
  if (app.receiptType === 'Sandbox' || app.receiptType === 'Xcode') return { tier: 'beta' };
  if (app.receiptType !== 'Production' || !subscription) return { tier: 'free' };

  let tx;
  try {
    tx = verifyAppleJws(subscription, { rootPems });
  } catch (e) {
    log.warn('subscription transaction rejected:', e.message);
    return { tier: 'free' };
  }
  const active = tx.bundleId === bundleId
    && productIds.includes(tx.productId)
    && tx.environment === 'Production'
    && !tx.revocationDate
    && typeof tx.expiresDate === 'number' && tx.expiresDate > now;
  if (!active) return { tier: 'free' };
  return { tier: 'pro', expiresAt: tx.expiresDate, originalTransactionId: String(tx.originalTransactionId) };
}
