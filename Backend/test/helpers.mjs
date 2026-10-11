// Test-only helpers: a minimal CBOR encoder and a fake App Attest certificate chain built with the
// openssl CLI (our own root → intermediate → credential cert carrying the nonce extension).

import { execFileSync } from 'node:child_process';
import { createHash, createSign, generateKeyPairSync } from 'node:crypto';
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

export function encodeCbor(value) {
  if (Buffer.isBuffer(value)) return Buffer.concat([head(2, value.length), value]);
  if (typeof value === 'string') {
    const bytes = Buffer.from(value, 'utf8');
    return Buffer.concat([head(3, bytes.length), bytes]);
  }
  if (Number.isInteger(value)) return value >= 0 ? head(0, value) : head(1, -1 - value);
  if (Array.isArray(value)) return Buffer.concat([head(4, value.length), ...value.map(encodeCbor)]);
  if (value && typeof value === 'object') {
    const entries = Object.entries(value);
    return Buffer.concat([head(5, entries.length), ...entries.flatMap(([k, v]) => [encodeCbor(k), encodeCbor(v)])]);
  }
  throw new Error(`cannot encode ${value}`);
}

function head(major, n) {
  if (n < 24) return Buffer.from([(major << 5) | n]);
  if (n < 0x100) return Buffer.from([(major << 5) | 24, n]);
  if (n < 0x10000) { const b = Buffer.alloc(3); b[0] = (major << 5) | 25; b.writeUInt16BE(n, 1); return b; }
  const b = Buffer.alloc(5); b[0] = (major << 5) | 26; b.writeUInt32BE(n, 1); return b;
}

export const sha256 = (...parts) => {
  const h = createHash('sha256');
  for (const p of parts) h.update(p);
  return h.digest();
};

export const AAGUID_PRODUCTION = Buffer.concat([Buffer.from('appattest'), Buffer.alloc(7)]);
export const AAGUID_DEVELOPMENT = Buffer.from('appattestdevelop');

export function authenticatorData({ appId, counter, aaguid, credentialId }) {
  const parts = [sha256(Buffer.from(appId)), Buffer.from([0x40]), u32(counter)];
  if (aaguid) {
    const len = Buffer.alloc(2);
    len.writeUInt16BE(credentialId.length);
    parts.push(aaguid, len, credentialId);
  }
  return Buffer.concat(parts);
}

const u32 = (n) => { const b = Buffer.alloc(4); b.writeUInt32BE(n); return b; };

/**
 * Builds a complete fake attestation for `challenge`. `tamper` lets a test corrupt one input.
 * Returns everything a test needs: the attestation, key id, root PEM, and the credential private key.
 */
export function makeAttestation({ appId, challenge, aaguid = AAGUID_PRODUCTION, tamper = {} }) {
  const dir = mkdtempSync(join(tmpdir(), 'appattest-'));
  try {
    const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
    const jwk = publicKey.export({ format: 'jwk' });
    const rawPoint = Buffer.concat([Buffer.from([4]), Buffer.from(jwk.x, 'base64url'), Buffer.from(jwk.y, 'base64url')]);
    const keyIdBytes = sha256(rawPoint);
    const authData = authenticatorData({
      appId: tamper.appId ?? appId, counter: tamper.counter ?? 0, aaguid, credentialId: keyIdBytes,
    });
    const nonce = tamper.nonce ?? sha256(authData, sha256(Buffer.from(challenge, 'utf8')));

    const run = (...args) => execFileSync('openssl', args, { cwd: dir, stdio: 'pipe' });
    writeFileSync(join(dir, 'leaf.key'), privateKey.export({ type: 'pkcs8', format: 'pem' }));
    writeFileSync(join(dir, 'ext.cnf'), [
      '[ca]', 'basicConstraints=critical,CA:true', 'keyUsage=critical,keyCertSign,cRLSign', '',
      '[leaf]', 'basicConstraints=critical,CA:false',
      `1.2.840.113635.100.8.2=DER:30:22:a1:20:04:20:${[...nonce].map((b) => b.toString(16).padStart(2, '0')).join(':')}`,
    ].join('\n'));
    run('ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', 'root.key');
    run('req', '-x509', '-new', '-key', 'root.key', '-subj', '/CN=Test Root', '-days', '2',
      '-extensions', 'ca', '-config', 'ext.cnf', '-out', 'root.pem');
    run('ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', 'int.key');
    run('req', '-new', '-key', 'int.key', '-subj', '/CN=Test Intermediate', '-out', 'int.csr', '-config', 'ext.cnf');
    run('x509', '-req', '-in', 'int.csr', '-CA', 'root.pem', '-CAkey', 'root.key', '-CAcreateserial',
      '-days', '2', '-extfile', 'ext.cnf', '-extensions', 'ca', '-out', 'int.pem');
    run('req', '-new', '-key', 'leaf.key', '-subj', '/CN=Test Credential', '-out', 'leaf.csr', '-config', 'ext.cnf');
    run('x509', '-req', '-in', 'leaf.csr', '-CA', 'int.pem', '-CAkey', 'int.key', '-CAcreateserial',
      '-days', '2', '-extfile', 'ext.cnf', '-extensions', 'leaf', '-out', 'leaf.pem');

    const der = (file) => Buffer.from(
      readFileSync(join(dir, file), 'utf8').replace(/-----[^-]+-----/g, '').replace(/\s+/g, ''), 'base64');
    const attestation = encodeCbor({
      fmt: 'apple-appattest',
      attStmt: { x5c: [der('leaf.pem'), der('int.pem')], receipt: Buffer.from('receipt') },
      authData,
    }).toString('base64');
    return {
      attestation,
      keyId: keyIdBytes.toString('base64'),
      rootPem: readFileSync(join(dir, 'root.pem'), 'utf8'),
      privateKey,
      publicKeyPem: publicKey.export({ type: 'spki', format: 'pem' }),
    };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

/**
 * A fake StoreKit signing chain (root → intermediate → leaf) with Apple's marker OIDs, plus a
 * signer that produces ES256 compact JWS exactly like StoreKit's `jwsRepresentation`.
 */
export function makeStoreKitSigner({ markers = true } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'storekit-'));
  try {
    const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' });
    const run = (...args) => execFileSync('openssl', args, { cwd: dir, stdio: 'pipe' });
    writeFileSync(join(dir, 'leaf.key'), privateKey.export({ type: 'pkcs8', format: 'pem' }));
    writeFileSync(join(dir, 'ext.cnf'), [
      '[ca]', 'basicConstraints=critical,CA:true', 'keyUsage=critical,keyCertSign,cRLSign',
      ...(markers ? ['1.2.840.113635.100.6.2.1=ASN1:NULL'] : []), '',
      '[root]', 'basicConstraints=critical,CA:true', 'keyUsage=critical,keyCertSign,cRLSign', '',
      '[leaf]', 'basicConstraints=critical,CA:false',
      ...(markers ? ['1.2.840.113635.100.6.11.1=ASN1:NULL'] : []),
    ].join('\n'));
    run('ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', 'root.key');
    run('req', '-x509', '-new', '-key', 'root.key', '-subj', '/CN=Fake Apple Root', '-days', '3',
      '-extensions', 'root', '-config', 'ext.cnf', '-out', 'root.pem');
    run('ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', 'int.key');
    run('req', '-new', '-key', 'int.key', '-subj', '/CN=Fake WWDR', '-out', 'int.csr', '-config', 'ext.cnf');
    run('x509', '-req', '-in', 'int.csr', '-CA', 'root.pem', '-CAkey', 'root.key', '-CAcreateserial',
      '-days', '3', '-extfile', 'ext.cnf', '-extensions', 'ca', '-out', 'int.pem');
    run('req', '-new', '-key', 'leaf.key', '-subj', '/CN=Fake StoreKit', '-out', 'leaf.csr', '-config', 'ext.cnf');
    run('x509', '-req', '-in', 'leaf.csr', '-CA', 'int.pem', '-CAkey', 'int.key', '-CAcreateserial',
      '-days', '3', '-extfile', 'ext.cnf', '-extensions', 'leaf', '-out', 'leaf.pem');
    const b64der = (file) => readFileSync(join(dir, file), 'utf8').replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
    const x5c = [b64der('leaf.pem'), b64der('int.pem'), b64der('root.pem')];
    const rootPem = readFileSync(join(dir, 'root.pem'), 'utf8');
    const sign = (payload) => {
      const header = Buffer.from(JSON.stringify({ alg: 'ES256', x5c })).toString('base64url');
      const body = Buffer.from(JSON.stringify(payload)).toString('base64url');
      const signature = createSign('sha256').update(`${header}.${body}`)
        .sign({ key: privateKey, dsaEncoding: 'ieee-p1363' }).toString('base64url');
      return `${header}.${body}.${signature}`;
    };
    return { rootPem, sign };
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}
