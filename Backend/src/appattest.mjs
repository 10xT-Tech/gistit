// Apple App Attest verification, following "Validating apps that connect to your server":
// https://developer.apple.com/documentation/devicecheck/validating-apps-that-connect-to-your-server
//
// Client data convention (shared with the iOS BackendSession): the client data the app hashes is the
// server-issued challenge string's UTF-8 bytes, for both the attestation and every assertion.

import { X509Certificate, createHash, createVerify, timingSafeEqual } from 'node:crypto';
import { decodeCbor } from './cbor.mjs';

// 1.2.840.113635.100.8.2 — the credential certificate extension that carries the nonce.
const NONCE_OID = Buffer.from([0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x08, 0x02]);
const AAGUID_PRODUCTION = Buffer.concat([Buffer.from('appattest'), Buffer.alloc(7)]);
const AAGUID_DEVELOPMENT = Buffer.from('appattestdevelop');

export class AttestationError extends Error {}

const sha256 = (...parts) => {
  const h = createHash('sha256');
  for (const p of parts) h.update(p);
  return h.digest();
};

const same = (a, b) => a.length === b.length && timingSafeEqual(a, b);

/**
 * Verifies a one-time key attestation. Returns the key's public key (PEM) and its environment.
 * @param {object} p
 * @param {string} p.attestation  base64 attestation object from DCAppAttestService.attestKey
 * @param {string} p.keyId        base64 key identifier from DCAppAttestService.generateKey
 * @param {string} p.challenge    the server-issued challenge the app hashed as client data
 * @param {string} p.appId        "<TeamID>.<bundle id>"
 * @param {string} p.rootPem      Apple App Attestation Root CA
 * @param {boolean} p.allowDevelopment  accept the development App Attest environment
 * @param {Date} [p.now]
 */
export function verifyAttestation({ attestation, keyId, challenge, appId, rootPem, allowDevelopment, now = new Date() }) {
  let obj;
  try {
    obj = decodeCbor(Buffer.from(attestation, 'base64'));
  } catch (e) {
    throw new AttestationError(`malformed attestation: ${e.message}`);
  }
  if (obj?.fmt !== 'apple-appattest') throw new AttestationError('unexpected attestation format');
  const x5c = obj.attStmt?.x5c;
  const authData = obj.authData;
  if (!Array.isArray(x5c) || x5c.length < 2 || !Buffer.isBuffer(authData)) {
    throw new AttestationError('attestation is missing its certificates or authenticator data');
  }

  // 1. Certificate chain: credential cert → intermediate → Apple App Attestation Root CA.
  const leaf = new X509Certificate(x5c[0]);
  const intermediate = new X509Certificate(x5c[1]);
  const root = new X509Certificate(rootPem);
  if (!leaf.checkIssued(intermediate) || !leaf.verify(intermediate.publicKey)) {
    throw new AttestationError('credential certificate is not signed by the intermediate');
  }
  if (!intermediate.checkIssued(root) || !intermediate.verify(root.publicKey)) {
    throw new AttestationError('intermediate certificate is not signed by the App Attest root');
  }
  for (const cert of [leaf, intermediate]) {
    if (now < new Date(cert.validFrom) || now > new Date(cert.validTo)) {
      throw new AttestationError('certificate outside its validity period');
    }
  }

  // 2–4. nonce = SHA256(authData ‖ SHA256(clientData)) must equal the certificate's nonce extension.
  const nonce = sha256(authData, sha256(Buffer.from(challenge, 'utf8')));
  if (!same(extractNonce(leaf.raw), nonce)) throw new AttestationError('nonce mismatch');

  // 5. The key identifier is the SHA256 of the credential certificate's public key (uncompressed point).
  const keyIdBytes = Buffer.from(keyId, 'base64');
  if (!same(sha256(rawPublicKey(leaf)), keyIdBytes)) throw new AttestationError('key identifier mismatch');

  // 6–9. Authenticator data: app identity, fresh counter, environment, credential id.
  const auth = parseAuthenticatorData(authData, true);
  if (!same(auth.rpIdHash, sha256(Buffer.from(appId, 'utf8')))) throw new AttestationError('app id mismatch');
  if (auth.signCount !== 0) throw new AttestationError('attestation counter must be zero');
  let environment;
  if (same(auth.aaguid, AAGUID_PRODUCTION)) environment = 'production';
  else if (same(auth.aaguid, AAGUID_DEVELOPMENT) && allowDevelopment) environment = 'development';
  else throw new AttestationError('unexpected App Attest environment');
  if (!same(auth.credentialId, keyIdBytes)) throw new AttestationError('credential id mismatch');

  return { publicKeyPem: leaf.publicKey.export({ type: 'spki', format: 'pem' }), environment };
}

/**
 * Verifies an assertion made with a previously attested key. Returns the new counter value.
 * @param {object} p
 * @param {string} p.assertion       base64 assertion from DCAppAttestService.generateAssertion
 * @param {string} p.challenge       the server-issued challenge the app hashed as client data
 * @param {string} p.publicKeyPem    stored at attestation time
 * @param {number} p.previousCounter stored counter; the assertion's must be strictly greater
 * @param {string} p.appId
 */
export function verifyAssertion({ assertion, challenge, publicKeyPem, previousCounter, appId }) {
  let obj;
  try {
    obj = decodeCbor(Buffer.from(assertion, 'base64'));
  } catch (e) {
    throw new AttestationError(`malformed assertion: ${e.message}`);
  }
  const { signature, authenticatorData } = obj ?? {};
  if (!Buffer.isBuffer(signature) || !Buffer.isBuffer(authenticatorData)) {
    throw new AttestationError('assertion is missing its signature or authenticator data');
  }
  const nonce = sha256(authenticatorData, sha256(Buffer.from(challenge, 'utf8')));
  const verifier = createVerify('sha256');
  verifier.update(nonce);
  if (!verifier.verify(publicKeyPem, signature)) throw new AttestationError('bad assertion signature');

  const auth = parseAuthenticatorData(authenticatorData, false);
  if (!same(auth.rpIdHash, sha256(Buffer.from(appId, 'utf8')))) throw new AttestationError('app id mismatch');
  if (auth.signCount <= previousCounter) throw new AttestationError('assertion counter did not increase');
  return { counter: auth.signCount };
}

function parseAuthenticatorData(data, withCredential) {
  if (data.length < 37) throw new AttestationError('authenticator data too short');
  const out = {
    rpIdHash: data.subarray(0, 32),
    signCount: data.readUInt32BE(33),
  };
  if (withCredential) {
    if (data.length < 55) throw new AttestationError('authenticator data lacks credential data');
    out.aaguid = data.subarray(37, 53);
    const idLength = data.readUInt16BE(53);
    if (data.length < 55 + idLength) throw new AttestationError('credential id truncated');
    out.credentialId = data.subarray(55, 55 + idLength);
  }
  return out;
}

function rawPublicKey(cert) {
  const jwk = cert.publicKey.export({ format: 'jwk' });
  if (jwk.kty !== 'EC' || jwk.crv !== 'P-256') throw new AttestationError('unexpected credential key type');
  return Buffer.concat([Buffer.from([0x04]), Buffer.from(jwk.x, 'base64url'), Buffer.from(jwk.y, 'base64url')]);
}

/** The nonce from extension 1.2.840.113635.100.8.2: OCTET STRING { SEQUENCE { [1] { OCTET STRING } } }. */
export function extractNonce(certDer) {
  const at = certDer.indexOf(NONCE_OID);
  if (at < 0) throw new AttestationError('certificate has no App Attest nonce extension');
  let tlv = readTLV(certDer, at + NONCE_OID.length);
  if (tlv.tag === 0x01) tlv = readTLV(certDer, tlv.end);   // optional "critical" BOOLEAN
  if (tlv.tag !== 0x04) throw new AttestationError('malformed nonce extension');
  const sequence = readTLV(certDer, tlv.start);
  if (sequence.tag !== 0x30) throw new AttestationError('malformed nonce extension');
  const tagged = readTLV(certDer, sequence.start);
  if (tagged.tag !== 0xa1) throw new AttestationError('malformed nonce extension');
  const octets = readTLV(certDer, tagged.start);
  if (octets.tag !== 0x04) throw new AttestationError('malformed nonce extension');
  return certDer.subarray(octets.start, octets.end);
}

function readTLV(buf, offset) {
  if (offset + 2 > buf.length) throw new AttestationError('truncated DER');
  const tag = buf[offset];
  let length = buf[offset + 1];
  let start = offset + 2;
  if (length & 0x80) {
    const n = length & 0x7f;
    if (n === 0 || n > 4 || start + n > buf.length) throw new AttestationError('bad DER length');
    length = buf.readUIntBE(start, n);
    start += n;
  }
  const end = start + length;
  if (end > buf.length) throw new AttestationError('truncated DER');
  return { tag, start, end };
}
