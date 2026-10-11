// Minimal CBOR (RFC 8949) decoder — just what App Attest attestation and assertion objects use:
// unsigned/negative ints, byte and text strings, arrays, maps, tags, true/false/null.
// Indefinite-length items and floats are rejected: Apple never emits them here.

export function decodeCbor(buffer) {
  const reader = { buf: buffer, pos: 0 };
  const value = readItem(reader, 0);
  if (reader.pos !== buffer.length) throw new Error('cbor: trailing bytes');
  return value;
}

const MAX_DEPTH = 16;

function readItem(r, depth) {
  if (depth > MAX_DEPTH) throw new Error('cbor: nesting too deep');
  const initial = readUInt(r, 1);
  const major = initial >> 5;
  const info = initial & 0x1f;
  if (major === 7) {
    if (info === 20) return false;
    if (info === 21) return true;
    if (info === 22) return null;
    throw new Error(`cbor: unsupported simple/float value ${info}`);
  }
  const arg = readArgument(r, info);
  switch (major) {
    case 0: return arg;
    case 1: return -1 - arg;
    case 2: return readBytes(r, arg);
    case 3: return readBytes(r, arg).toString('utf8');
    case 4: {
      const out = [];
      for (let i = 0; i < arg; i++) out.push(readItem(r, depth + 1));
      return out;
    }
    case 5: {
      const out = {};
      for (let i = 0; i < arg; i++) {
        const key = readItem(r, depth + 1);
        out[String(key)] = readItem(r, depth + 1);
      }
      return out;
    }
    case 6: return readItem(r, depth + 1);   // tag: return the tagged item itself
    default: throw new Error(`cbor: unsupported major type ${major}`);
  }
}

function readArgument(r, info) {
  if (info < 24) return info;
  if (info === 24) return readUInt(r, 1);
  if (info === 25) return readUInt(r, 2);
  if (info === 26) return readUInt(r, 4);
  if (info === 27) {
    const big = r.buf.readBigUInt64BE(advance(r, 8));
    if (big > BigInt(Number.MAX_SAFE_INTEGER)) throw new Error('cbor: integer too large');
    return Number(big);
  }
  throw new Error('cbor: indefinite lengths are not supported');
}

function readUInt(r, size) {
  const at = advance(r, size);
  return r.buf.readUIntBE(at, size);
}

function readBytes(r, length) {
  const at = advance(r, length);
  return r.buf.subarray(at, at + length);
}

function advance(r, size) {
  if (r.pos + size > r.buf.length) throw new Error('cbor: unexpected end of input');
  const at = r.pos;
  r.pos += size;
  return at;
}
