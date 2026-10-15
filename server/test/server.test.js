// Tests for the helper server. Run with `npm test` from server/.
// Real App Attest objects only come from an iPhone, so these tests build
// look-alike ones: a throwaway certificate chain with the same layout Apple
// uses, signed by a test root instead of Apple's.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { APPLE_ROOT, concat, parseCertificate, sha256, toBase64, utf8, verifyAttestation } from '../src/attest.js';
import worker, { Install } from '../src/index.js';

const APP_ID = 'TEAMID.dev.polter.sedge';

// ---- Small encoders for building test objects ----

const hexBytes = (text) => Uint8Array.from(text.match(/../g), (pair) => parseInt(pair, 16));

function tlv(tag, ...parts) {
  const body = concat(...parts);
  const n = body.length;
  const length = n < 128 ? [n] : n < 256 ? [0x81, n] : [0x82, n >> 8, n & 255];
  return concat(Uint8Array.of(tag, ...length), body);
}
const seq = (...parts) => tlv(0x30, ...parts);
const oid = (hex) => tlv(0x06, hexBytes(hex));
function derInt(bytes) {
  let i = 0;
  while (i < bytes.length - 1 && bytes[i] === 0) i++;
  const value = bytes.subarray(i);
  return tlv(0x02, value[0] & 0x80 ? concat(Uint8Array.of(0), value) : value);
}
const rawToDer = (raw) => seq(derInt(raw.subarray(0, raw.length / 2)), derInt(raw.subarray(raw.length / 2)));
const utcTime = (ms) => tlv(0x17, utf8(new Date(ms).toISOString().replace(/[-:T]/g, '').slice(2, 14) + 'Z'));

function cbor(value) {
  const head = (major, n) => n < 24 ? Uint8Array.of((major << 5) | n)
    : n < 256 ? Uint8Array.of((major << 5) | 24, n)
      : Uint8Array.of((major << 5) | 25, n >> 8, n & 255);
  if (value instanceof Uint8Array) return concat(head(2, value.length), value);
  if (typeof value === 'string') return concat(head(3, utf8(value).length), utf8(value));
  if (Array.isArray(value)) return concat(head(4, value.length), ...value.map(cbor));
  const entries = Object.entries(value);
  return concat(head(5, entries.length), ...entries.flatMap(([k, v]) => [cbor(k), cbor(v)]));
}

const ecKeys = (curve) => crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: curve }, true, ['sign', 'verify']);
const exportKey = async (format, key) => new Uint8Array(await crypto.subtle.exportKey(format, key));
const HASH_OIDS = { 'SHA-256': '2a8648ce3d040302', 'SHA-384': '2a8648ce3d040303' };

async function makeCert(subjectPublic, issuerPrivate, hash, extensions = []) {
  const now = Date.now();
  const tbs = seq(
    tlv(0xa0, derInt(Uint8Array.of(2))), derInt(Uint8Array.of(1)), seq(oid(HASH_OIDS[hash])), seq(),
    seq(utcTime(now - 3600e3), utcTime(now + 3600e3)), seq(), await exportKey('spki', subjectPublic),
    ...(extensions.length ? [tlv(0xa3, seq(...extensions))] : []));
  const raw = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash }, issuerPrivate, tbs));
  return seq(tbs, seq(oid(HASH_OIDS[hash])), tlv(0x03, Uint8Array.of(0), rawToDer(raw)));
}

/** A look-alike attestation: root and intermediate on P-384, the app's key on P-256, like Apple's. */
async function makeAttestation({ challenge, appId = APP_ID, aaguid = utf8('appattestdevelop') }) {
  const [root, intermediate, leaf] = await Promise.all([ecKeys('P-384'), ecKeys('P-384'), ecKeys('P-256')]);
  const keyId = await sha256(await exportKey('raw', leaf.publicKey));
  const authData = concat(await sha256(utf8(appId)), Uint8Array.of(0x40), new Uint8Array(4), aaguid, Uint8Array.of(0, 32), keyId);
  const nonce = await sha256(concat(authData, await sha256(utf8(challenge))));
  const nonceExtension = seq(oid('2a864886f763640802'), tlv(0x04, seq(tlv(0xa1, tlv(0x04, nonce)))));
  const x5c = [
    await makeCert(leaf.publicKey, intermediate.privateKey, 'SHA-256', [nonceExtension]),
    await makeCert(intermediate.publicKey, root.privateKey, 'SHA-384'),
  ];
  return {
    keyId,
    root: await makeCert(root.publicKey, root.privateKey, 'SHA-384'),
    attestation: cbor({ fmt: 'apple-appattest', attStmt: { x5c, receipt: new Uint8Array() }, authData }),
  };
}

async function makeAssertion(privateKey, counter, clientData, appId = APP_ID) {
  const authenticatorData = concat(await sha256(utf8(appId)), Uint8Array.of(0x40),
    Uint8Array.of(counter >>> 24, (counter >> 16) & 255, (counter >> 8) & 255, counter & 255));
  const nonce = await sha256(concat(authenticatorData, await sha256(clientData)));
  const raw = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, privateKey, nonce));
  return toBase64(cbor({ signature: rawToDer(raw), authenticatorData }));
}

// ---- A fake Cloudflare environment ----

function makeEnv(overrides = {}) {
  const stores = new Map(); // install id -> its storage Map, so tests can look inside
  const objects = new Map();
  const INSTALLS = {
    idFromName: (name) => name,
    get(id) {
      if (!objects.has(id)) {
        const data = new Map();
        stores.set(id, data);
        const storage = {
          get: async (key) => structuredClone(data.get(key)),
          put: async (key, value) => void data.set(key, structuredClone(value)),
          deleteAll: async () => data.clear(),
        };
        objects.set(id, new Install({ storage }, {}));
      }
      return objects.get(id);
    },
  };
  const env = {
    INSTALLS, PLAID_ENV: 'sandbox', APP_ID, APP_ATTEST_ENV: 'development', ALLOWED_MODELS: 'claude-sonnet-5-5',
    DAILY_MESSAGE_CAP: '2', PLAID_REDIRECT_URI: '', PLAID_CLIENT_ID: 'test-client', PLAID_SECRET: 'test-plaid-secret',
    ANTHROPIC_API_KEY: 'test-anthropic-key', SERVER_KEY: toBase64(new Uint8Array(32).fill(7)), ...overrides,
  };
  return { env, stores };
}

const call = (env, method, path, { headers = {}, body } = {}) =>
  worker.fetch(new Request(`https://server.test${path}`, { method, headers, body }), env);

/** A registered install that signs its requests the way the app will. */
async function makeDevice(env) {
  const keys = await ecKeys('P-256');
  const id = toBase64(await sha256(await exportKey('raw', keys.publicKey)));
  await env.INSTALLS.get(id).create({ publicKey: toBase64(await exportKey('spki', keys.publicKey)), counter: 0 });
  let counter = 0;
  return {
    id,
    keys,
    async request(method, path, body = '', { assertionCounter, signedPath = path } = {}) {
      const assertion = await makeAssertion(keys.privateKey, assertionCounter ?? ++counter, concat(utf8(signedPath), utf8(body)));
      return call(env, method, path, { headers: { 'X-Install-Id': id, 'X-Assertion': assertion }, body: method === 'GET' ? undefined : body });
    },
  };
}

/** Replaces fetch with fake Plaid and Anthropic endpoints, and records every call. */
function stubUpstream(handlers) {
  const calls = [];
  globalThis.fetch = async (url, init) => {
    const body = JSON.parse(new TextDecoder().decode(typeof init.body === 'string' ? utf8(init.body) : init.body));
    calls.push({ url: String(url), headers: init.headers, body });
    const handler = handlers[new URL(url).pathname];
    return handler ? handler(body) : Response.json({ error_code: 'NOT_STUBBED' }, { status: 400 });
  };
  return calls;
}

// ---- App Attest ----

test('a well-formed attestation passes, and every tampered part fails', async () => {
  const challenge = 'challenge-1';
  const good = await makeAttestation({ challenge });
  const check = (changes) => verifyAttestation({
    attestation: good.attestation, keyId: good.keyId, clientData: utf8(challenge),
    appId: APP_ID, environment: 'development', root: good.root, ...changes,
  });

  const publicKey = await check({});
  assert.ok(publicKey.length > 64, 'returns the key to store');

  await assert.rejects(check({ root: APPLE_ROOT }), /chain/, 'a chain that is not Apple\'s is refused');
  await assert.rejects(check({ clientData: utf8('other challenge') }), /nonce/);
  await assert.rejects(check({ keyId: new Uint8Array(32) }), /key id/);
  await assert.rejects(check({ appId: 'OTHER.app' }), /wrong app/);
  await assert.rejects(check({ environment: 'production' }), /environment/);
  await assert.rejects(check({ now: Date.now() + 2 * 3600e3 }), /out of date/);
});

test('Apple\'s root certificate is the one Apple publishes', async () => {
  const fingerprint = Array.from(await sha256(APPLE_ROOT), (b) => b.toString(16).padStart(2, '0')).join('');
  assert.equal(fingerprint, '1cb9823ba28ba6ad2d33a006941de2ae4f513ef1d4e831b9f7e0fa7b6242c932');
  // The certificate reader also handles a real Apple certificate, not just the test ones.
  const root = parseCertificate(APPLE_ROOT);
  assert.equal(root.curve.name, 'P-384');
  assert.equal(root.hash, 'SHA-384');
  assert.equal(new Date(root.notAfter).toISOString(), '2045-03-15T00:00:00.000Z');
});

test('/api/attest refuses stale challenges and fake attestations', async () => {
  const { env } = makeEnv();
  const { challenge } = await (await call(env, 'GET', '/api/challenge')).json();
  const fake = await makeAttestation({ challenge }); // signed by a test root, not Apple
  const attest = (body) => call(env, 'POST', '/api/attest', { body: JSON.stringify(body) });

  const real = { keyId: toBase64(fake.keyId), attestation: toBase64(fake.attestation), challenge };
  assert.equal((await attest(real)).status, 401, 'not Apple\'s chain');
  assert.equal((await attest({ ...real, challenge: `${Date.now()}.AAAA` })).status, 401, 'unsigned challenge');
  assert.equal((await attest({ ...real, challenge: `${Date.now() - 6 * 60e3}.${challenge.split('.')[1]}` })).status, 401, 'old challenge');
  assert.equal((await attest({ keyId: 'nope' })).status, 400);
});

// ---- Requests without valid attestation ----

test('requests without a valid assertion are refused', async () => {
  const { env } = makeEnv();
  const device = await makeDevice(env);
  const body = JSON.stringify({ model: 'claude-sonnet-5-5', max_tokens: 10, messages: [] });
  const calls = stubUpstream({ '/v1/messages': () => Response.json({ ok: true }) });

  const noHeaders = await call(env, 'POST', '/api/messages', { body });
  assert.equal(noHeaders.status, 401);
  assert.equal((await noHeaders.json()).error, 'attestation_required');

  const garbage = await call(env, 'POST', '/api/messages', { headers: { 'X-Install-Id': device.id, 'X-Assertion': 'AAAA' }, body });
  assert.equal(garbage.status, 401);

  const stranger = await ecKeys('P-256');
  const wrongKey = await makeAssertion(stranger.privateKey, 1, concat(utf8('/api/messages'), utf8(body)));
  assert.equal((await call(env, 'POST', '/api/messages', { headers: { 'X-Install-Id': device.id, 'X-Assertion': wrongKey }, body })).status, 401);

  assert.equal((await device.request('POST', '/api/messages', body, { signedPath: '/api/install' })).status, 401, 'signature for another route');
  assert.equal((await device.request('POST', '/api/messages', body, { assertionCounter: 5 })).status, 200);
  assert.equal((await device.request('POST', '/api/messages', body, { assertionCounter: 5 })).status, 401, 'replayed counter');

  const unknown = await makeAssertion(device.keys.privateKey, 9, concat(utf8('/api/messages'), utf8(body)));
  const unknownId = toBase64(new Uint8Array(32));
  assert.equal((await call(env, 'POST', '/api/messages', { headers: { 'X-Install-Id': unknownId, 'X-Assertion': unknown }, body })).status, 401);

  assert.equal(calls.length, 1, 'only the one valid request reached Anthropic');
});

// ---- Cloud model relay ----

test('the relay forwards allowed models and stops at the daily cap', async () => {
  const { env } = makeEnv({ DAILY_MESSAGE_CAP: '2' });
  const device = await makeDevice(env);
  const calls = stubUpstream({ '/v1/messages': () => Response.json({ content: [{ type: 'text', text: 'hi' }] }) });
  const ask = (model) => device.request('POST', '/api/messages', JSON.stringify({ model, max_tokens: 10, messages: [] }));

  const notAllowed = await ask('some-other-model');
  assert.equal(notAllowed.status, 400);
  assert.equal((await notAllowed.json()).error, 'model_not_allowed');

  const first = await ask('claude-sonnet-5-5');
  assert.equal(first.status, 200);
  assert.equal((await first.json()).content[0].text, 'hi');
  assert.equal(calls[0].headers['x-api-key'], 'test-anthropic-key', 'the key is added by the server');
  assert.equal((await ask('claude-sonnet-5-5')).status, 200);

  const capped = await ask('claude-sonnet-5-5');
  assert.equal(capped.status, 429);
  const error = await capped.json();
  assert.equal(error.error, 'daily_limit_reached');
  assert.match(error.message, /all 2 cloud requests for today/);
  assert.equal(calls.length, 2, 'the capped request never reached Anthropic');
});

// ---- Plaid ----

test('Plaid link, sync, and delete keep the access token on the server', async () => {
  const { env, stores } = makeEnv();
  const device = await makeDevice(env);
  const calls = stubUpstream({
    '/link/token/create': () => Response.json({ link_token: 'link-sandbox-1' }),
    '/item/public_token/exchange': () => Response.json({ access_token: 'access-sandbox-secret', item_id: 'item-1' }),
    '/transactions/sync': () => Response.json({ added: [{ transaction_id: 't1' }], next_cursor: 'c1', has_more: false }),
    '/accounts/get': () => Response.json({ accounts: [{ account_id: 'a1' }] }),
    '/item/remove': () => Response.json({}),
  });

  const link = await device.request('POST', '/api/create_link_token');
  assert.deepEqual(await link.json(), { link_token: 'link-sandbox-1' });
  assert.equal(calls[0].body.user.client_user_id, device.id);
  assert.equal(calls[0].body.secret, 'test-plaid-secret');

  const exchange = await device.request('POST', '/api/set_access_token', 'public_token=public-sandbox-1');
  const exchangeText = await exchange.text();
  assert.equal(exchange.status, 200);
  assert.ok(!exchangeText.includes('access-sandbox-secret'), 'the token is never sent to the app');
  const saved = JSON.stringify([...stores.get(device.id)]);
  assert.ok(!saved.includes('access-sandbox-secret'), 'the token is stored encrypted');

  const sync = await device.request('GET', '/api/all_transactions');
  assert.deepEqual(await sync.json(), { accounts: [{ account_id: 'a1' }], transactions: [{ transaction_id: 't1' }] });
  assert.equal(calls.find((c) => c.url.endsWith('/transactions/sync')).body.access_token, 'access-sandbox-secret');
  assert.ok(!JSON.stringify([...stores.get(device.id)]).includes('t1'), 'no transactions are stored');

  const removed = await device.request('DELETE', '/api/install');
  assert.deepEqual(await removed.json(), { deleted: true });
  assert.equal(calls.at(-1).url, 'https://sandbox.plaid.com/item/remove');
  assert.equal(stores.get(device.id).size, 0, 'nothing is left for this install');
  assert.equal((await device.request('POST', '/api/create_link_token')).status, 401, 'a deleted install must attest again');
});

test('public routes answer without attestation', async () => {
  const { env } = makeEnv();
  assert.deepEqual(await (await call(env, 'GET', '/health')).json(), { ok: true, plaid_env: 'sandbox' });
  const site = await (await call(env, 'GET', '/.well-known/apple-app-site-association')).json();
  assert.deepEqual(site.applinks.details[0].appIDs, [APP_ID]);
  assert.equal((await call(env, 'GET', '/nope')).status, 404);
});
