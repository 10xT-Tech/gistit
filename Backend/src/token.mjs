// Short-lived session tokens: base64url(JSON payload) "." base64url(HMAC-SHA256). Issued after a
// verified App Attest assertion, so per-request calls don't need an assertion each time.

import { createHmac, timingSafeEqual } from 'node:crypto';

export function signSession({ kid, env, tier = 'free', ttlSeconds, secret, now = Date.now() }) {
  const payload = Buffer.from(JSON.stringify({ kid, env, tier, exp: Math.floor(now / 1000) + ttlSeconds }))
    .toString('base64url');
  return `${payload}.${mac(payload, secret)}`;
}

/** The payload `{ kid, env, tier, exp }` of a valid, unexpired token — otherwise null. */
export function verifySession(token, secret, now = Date.now()) {
  if (typeof token !== 'string') return null;
  const [payload, signature, extra] = token.split('.');
  if (!payload || !signature || extra !== undefined) return null;
  const expected = Buffer.from(mac(payload, secret));
  const given = Buffer.from(signature);
  if (expected.length !== given.length || !timingSafeEqual(expected, given)) return null;
  let claims;
  try {
    claims = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
  } catch {
    return null;
  }
  if (typeof claims?.kid !== 'string' || typeof claims.exp !== 'number') return null;
  if (claims.exp <= Math.floor(now / 1000)) return null;
  return claims;
}

const mac = (payload, secret) => createHmac('sha256', secret).update(payload).digest('base64url');
