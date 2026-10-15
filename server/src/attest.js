// Apple App Attest checks: proof that a request comes from the real Sedge app
// on a real iPhone. The steps follow Apple's article "Validating apps that
// connect to your server". Signatures are checked with the built-in Web Crypto
// API; the two small readers below only pull fields out of Apple's binary
// formats (CBOR and DER), so a reading mistake makes a check fail, not pass.

const encoder = new TextEncoder();

// ---- Byte helpers ----

export const sha256 = async (bytes) => new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
export const utf8 = (text) => encoder.encode(text);
export const equal = (a, b) => a.length === b.length && a.every((value, i) => value === b[i]);
const hex = (bytes) => Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');

export function concat(...parts) {
  const out = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
  let at = 0;
  for (const part of parts) {
    out.set(part, at);
    at += part.length;
  }
  return out;
}

/** Standard base64 (what Swift's `base64EncodedString()` produces) to bytes. Throws on bad input. */
export const fromBase64 = (text) => Uint8Array.from(atob(text), (c) => c.charCodeAt(0));

export function toBase64(bytes) {
  let binary = '';
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary);
}

// ---- CBOR: the binary format Apple wraps attestations and assertions in ----

/** Reads the CBOR subset Apple uses: numbers, byte and text strings, arrays and maps. */
export function decodeCbor(bytes) {
  let at = 0;
  const take = (count) => {
    if (at + count > bytes.length) throw new Error('truncated CBOR');
    const slice = bytes.subarray(at, at + count);
    at += count;
    return slice;
  };
  const readItem = () => {
    const [first] = take(1);
    const major = first >> 5;
    const info = first & 31;
    let length = info;
    if (info >= 24) {
      const size = { 24: 1, 25: 2, 26: 4 }[info];
      if (!size) throw new Error('unsupported CBOR length');
      length = take(size).reduce((n, b) => n * 256 + b, 0);
    }
    // Every array or map entry needs at least one byte, so a bigger count is a lie.
    if ((major === 4 || major === 5) && length > bytes.length) throw new Error('bad CBOR length');
    switch (major) {
      case 0: return length;
      case 2: return take(length);
      case 3: return new TextDecoder().decode(take(length));
      case 4: return Array.from({ length }, readItem);
      case 5: {
        const map = {};
        for (let i = 0; i < length; i++) map[readItem()] = readItem();
        return map;
      }
      default: throw new Error('unsupported CBOR type');
    }
  };
  return readItem();
}

// ---- DER: the binary format of X.509 certificates ----

/** Reads one DER element: its tag byte, its contents, and the whole element. */
function readTlv(bytes) {
  if (bytes.length < 2) throw new Error('truncated DER');
  let length = bytes[1];
  let at = 2;
  if (length & 0x80) {
    const count = length & 0x7f;
    if (count < 1 || count > 3 || bytes.length < 2 + count) throw new Error('bad DER length');
    length = 0;
    for (let i = 0; i < count; i++) length = length * 256 + bytes[at++];
  }
  if (at + length > bytes.length) throw new Error('truncated DER');
  return { tag: bytes[0], body: bytes.subarray(at, at + length), full: bytes.subarray(0, at + length) };
}

/** Splits a DER element's contents into its child elements. */
function children(bytes) {
  const out = [];
  while (bytes.length) {
    const node = readTlv(bytes);
    out.push(node);
    bytes = bytes.subarray(node.full.length);
  }
  return out;
}

// Object identifiers, compared in their encoded (hex) form.
const HASH_FOR_SIGNATURE = { '2a8648ce3d040302': 'SHA-256', '2a8648ce3d040303': 'SHA-384' };
const CURVES = { '2a8648ce3d030107': { name: 'P-256', size: 32 }, '2b81040022': { name: 'P-384', size: 48 } };
const NONCE_EXTENSION = '2a864886f763640802'; // 1.2.840.113635.100.8.2, Apple's nonce field

/** "YYMMDDHHMMSSZ" (UTCTime) or "YYYYMMDDHHMMSSZ" (GeneralizedTime) to milliseconds. */
function readTime({ tag, body }) {
  let text = new TextDecoder().decode(body);
  if (tag === 0x17) text = (Number(text.slice(0, 2)) < 50 ? '20' : '19') + text;
  const [y, mo, d, h, mi, s] = [0, 4, 6, 8, 10, 12].map((i, n) => Number(text.slice(i, n ? i + 2 : 4)));
  return Date.UTC(y, mo - 1, d, h, mi, s);
}

/** Pulls the fields the checks need out of one DER certificate. */
export function parseCertificate(der) {
  const [tbs, signatureAlgorithm, signatureValue] = children(readTlv(der).body);
  const fields = children(tbs.body);
  const i = fields[0].tag === 0xa0 ? 1 : 0; // the version field is optional
  const validity = children(fields[i + 3].body);
  const spki = fields[i + 5];
  const [algorithm, bitString] = children(spki.body);
  const extensions = fields.find((field) => field.tag === 0xa3);
  return {
    tbs: tbs.full,
    hash: HASH_FOR_SIGNATURE[hex(children(signatureAlgorithm.body)[0].body)],
    signature: signatureValue.body.subarray(1), // skip the BIT STRING's "unused bits" byte
    notBefore: readTime(validity[0]),
    notAfter: readTime(validity[1]),
    spki: spki.full,
    curve: CURVES[hex(children(algorithm.body)[1].body)],
    publicKey: bitString.body.subarray(1),
    /** The raw value of the extension with this OID, or undefined. */
    extension(oid) {
      if (!extensions) return undefined;
      const match = children(readTlv(extensions.body).body)
        .map((ext) => children(ext.body))
        .find((parts) => hex(parts[0].body) === oid);
      return match?.at(-1).body;
    },
  };
}

/** Imports a certificate's (or a stored) public key for signature checks. */
function importKey(spki, curve) {
  if (!curve) throw new Error('unsupported key type');
  return crypto.subtle.importKey('spki', spki, { name: 'ECDSA', namedCurve: curve.name }, false, ['verify']);
}

/** Certificates hold ECDSA signatures as DER (r, s); Web Crypto wants r and s side by side. */
function derSignatureToRaw(signature, size) {
  const out = new Uint8Array(size * 2);
  children(readTlv(signature).body).forEach(({ body }, i) => {
    let value = body;
    while (value.length > size && value[0] === 0) value = value.subarray(1); // drop sign padding
    if (value.length > size || i > 1) throw new Error('bad signature');
    out.set(value, (i + 1) * size - value.length);
  });
  return out;
}

async function isSignedBy(child, parent) {
  if (!child.hash) throw new Error('unsupported signature algorithm');
  const key = await importKey(parent.spki, parent.curve);
  return crypto.subtle.verify(
    { name: 'ECDSA', hash: child.hash }, key, derSignatureToRaw(child.signature, parent.curve.size), child.tbs);
}

/** Apple's authenticator data: app id hash, flags, a counter, then (attestations only) device fields. */
function readAuthData(authData) {
  if (authData.length < 37) throw new Error('short authenticator data');
  const view = new DataView(authData.buffer, authData.byteOffset, authData.byteLength);
  const out = { rpIdHash: authData.subarray(0, 32), counter: view.getUint32(33) };
  if (authData.length >= 55) {
    const idLength = view.getUint16(53);
    out.aaguid = authData.subarray(37, 53);
    out.credentialId = authData.subarray(55, 55 + idLength);
  }
  return out;
}

// Which App Attest environment produced the key: Xcode builds use "development",
// TestFlight and App Store builds use "production".
const AAGUIDS = {
  development: utf8('appattestdevelop'),
  production: concat(utf8('appattest'), new Uint8Array(7)),
};

/** Apple's App Attestation root certificate, from apple.com/certificateauthority. */
export const APPLE_ROOT = fromBase64(
  'MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYwJAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTET' +
  'MBEGA1UECgwKQXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNaFw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFw' +
  'cGxlIEFwcCBBdHRlc3RhdGlvbiBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9ybmlhMHYwEAYHKoZIzj0CAQYFK4EE' +
  'ACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdhNbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9auYen1mMEvRq9Sk3Jm' +
  '5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYwCgYI' +
  'KoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKe' +
  'YnpqtijVoyFraWVIyd/dganmrduC1bmTBGwD');

/**
 * Checks a new key's attestation (sent once per install). Throws if anything is off.
 * Returns the key's public key (SPKI bytes) to store for checking later requests.
 * `clientData` is the server challenge the app hashed and passed to `attestKey`.
 */
export async function verifyAttestation({ attestation, keyId, clientData, appId, environment, root = APPLE_ROOT, now = Date.now() }) {
  const { fmt, attStmt, authData } = decodeCbor(attestation);
  if (fmt !== 'apple-appattest' || !Array.isArray(attStmt?.x5c) || !(authData instanceof Uint8Array)) {
    throw new Error('not an App Attest object');
  }
  const [leaf, intermediate] = attStmt.x5c.map(parseCertificate);
  const anchor = parseCertificate(root);

  // 1. The certificate chain leads to Apple's root and is in date.
  for (const cert of [leaf, intermediate]) {
    if (now < cert.notBefore || now > cert.notAfter) throw new Error('certificate out of date');
  }
  if (!(await isSignedBy(intermediate, anchor)) || !(await isSignedBy(leaf, intermediate))) {
    throw new Error('certificate chain does not lead to Apple');
  }

  // 2. The certificate's nonce matches this exact authenticator data and challenge.
  const nonce = await sha256(concat(authData, await sha256(clientData)));
  const field = leaf.extension(NONCE_EXTENSION);
  if (!field) throw new Error('missing nonce');
  const certNonce = readTlv(readTlv(readTlv(field).body).body).body; // SEQUENCE > [1] > OCTET STRING
  if (!equal(certNonce, nonce)) throw new Error('nonce mismatch');

  // 3. The certified key is the key the app says it made, for this app, and brand new.
  if (!equal(await sha256(leaf.publicKey), keyId)) throw new Error('key id mismatch');
  const auth = readAuthData(authData);
  if (!equal(auth.rpIdHash, await sha256(utf8(appId)))) throw new Error('wrong app');
  if (auth.counter !== 0) throw new Error('key already used');
  if (!AAGUIDS[environment] || !equal(auth.aaguid ?? [], AAGUIDS[environment])) throw new Error('wrong App Attest environment');
  if (!equal(auth.credentialId ?? [], keyId)) throw new Error('credential id mismatch');

  return leaf.spki;
}

/**
 * Checks one request's assertion against the key stored at attestation.
 * Returns the assertion's counter; the caller must refuse it unless it is
 * higher than the last one seen, which stops a captured request being replayed.
 */
export async function verifyAssertion({ assertion, clientData, publicKey, appId }) {
  const { signature, authenticatorData } = decodeCbor(assertion);
  if (!(signature instanceof Uint8Array) || !(authenticatorData instanceof Uint8Array)) throw new Error('not an assertion');
  const nonce = await sha256(concat(authenticatorData, await sha256(clientData)));
  const key = await importKey(publicKey, CURVES['2a8648ce3d030107']);
  const valid = await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, key, derSignatureToRaw(signature, 32), nonce);
  if (!valid) throw new Error('bad signature');
  const auth = readAuthData(authenticatorData);
  if (!equal(auth.rpIdHash, await sha256(utf8(appId)))) throw new Error('wrong app');
  return auth.counter;
}
