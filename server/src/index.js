// Sedge's helper server, a Cloudflare Worker. It holds every secret the app
// must not ship with: Plaid's keys, each install's Plaid access token, and the
// Anthropic key. It stores no transactions; it passes them straight through.

import { DurableObject } from 'cloudflare:workers';
import { concat, fromBase64, toBase64, utf8, verifyAssertion, verifyAttestation } from './attest.js';

/**
 * One app install's saved state. Cloudflare runs one copy of this object per
 * install id and runs its calls one at a time, so read-then-write steps like
 * "is this counter newer?" can't race each other.
 */
export class Install extends DurableObject {
  /** { publicKey, counter, token?, itemId? } or null when the install isn't registered. */
  async read() {
    return (await this.ctx.storage.get('install')) ?? null;
  }

  /** Saves a newly attested install. Refuses an id that is already registered. */
  async create(record) {
    if (await this.read()) return false;
    await this.ctx.storage.put('install', record);
    return true;
  }

  async update(fields) {
    const record = await this.read();
    await this.ctx.storage.put('install', { ...record, ...fields });
  }

  /** Accepts an assertion counter only if it is higher than the last one. */
  async advanceCounter(counter) {
    const record = await this.read();
    if (!record || counter <= record.counter) return false;
    await this.ctx.storage.put('install', { ...record, counter });
    return true;
  }

  /** Counts one cloud model request against today's cap. False once the cap is reached. */
  async takeMessage(day, cap) {
    const usage = await this.ctx.storage.get('usage');
    const used = usage?.day === day ? usage.used : 0;
    if (used >= cap) return false;
    await this.ctx.storage.put('usage', { day, used: used + 1 });
    return true;
  }

  async destroy() {
    await this.ctx.storage.deleteAll();
  }
}

const json = (data, status = 200) => Response.json(data, { status });

const refused = () => json({
  error: 'attestation_required',
  message: 'This request must come from the Sedge app with a valid App Attest assertion.',
}, 401);

/** A Plaid API error, carrying Plaid's own error code (never any token). */
class PlaidError extends Error {
  constructor(code) {
    super(`Plaid error ${code}`);
    this.code = code;
  }
}

/** Calls one Plaid endpoint, adding the server's Plaid keys. */
async function plaid(env, path, body) {
  // The environment is one config value; refusing anything else stops a typo
  // from sending the keys to some other host.
  if (!['sandbox', 'production'].includes(env.PLAID_ENV)) throw new Error('PLAID_ENV must be sandbox or production');
  const response = await fetch(`https://${env.PLAID_ENV}.plaid.com${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ client_id: env.PLAID_CLIENT_ID, secret: env.PLAID_SECRET, ...body }),
  });
  const data = await response.json();
  if (!response.ok) throw new PlaidError(data.error_code ?? 'UNKNOWN');
  return data;
}

/**
 * Two keys derived from the one SERVER_KEY secret: one encrypts Plaid access
 * tokens, the other signs attestation challenges. Deriving them keeps each key
 * to one job while Marcus only has to manage one secret.
 */
async function serverKeys(env) {
  const secret = fromBase64(env.SERVER_KEY ?? '');
  if (secret.length < 32) throw new Error('SERVER_KEY must be at least 32 random bytes, base64');
  const base = await crypto.subtle.importKey('raw', secret, 'HKDF', false, ['deriveKey']);
  const derive = (info, algorithm, uses) => crypto.subtle.deriveKey(
    { name: 'HKDF', hash: 'SHA-256', salt: new Uint8Array(), info: utf8(info) }, base, algorithm, false, uses);
  return {
    token: await derive('plaid-token', { name: 'AES-GCM', length: 256 }, ['encrypt', 'decrypt']),
    challenge: await derive('attest-challenge', { name: 'HMAC', hash: 'SHA-256', length: 256 }, ['sign', 'verify']),
  };
}

/** Encrypts a Plaid access token. Tying it to the install id means it only decrypts for that install. */
async function seal(env, installId, token) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const { token: key } = await serverKeys(env);
  const data = await crypto.subtle.encrypt({ name: 'AES-GCM', iv, additionalData: utf8(installId) }, key, utf8(token));
  return `${toBase64(iv)}.${toBase64(new Uint8Array(data))}`;
}

async function unseal(env, installId, sealed) {
  const [iv, data] = sealed.split('.').map(fromBase64);
  const { token: key } = await serverKeys(env);
  const plain = await crypto.subtle.decrypt({ name: 'AES-GCM', iv, additionalData: utf8(installId) }, key, data);
  return new TextDecoder().decode(plain);
}

const CHALLENGE_LIFETIME_MS = 5 * 60 * 1000;

/**
 * A challenge is "<time>.<signature>": the server can check it later without
 * storing it. A challenge can be reused until it expires, but replaying an
 * attestation still fails: an install id can only be registered once, and only
 * the one exact spelling of the key id is accepted (see isInstallId).
 */
async function makeChallenge(env) {
  const time = String(Date.now());
  const { challenge: key } = await serverKeys(env);
  const signature = new Uint8Array(await crypto.subtle.sign('HMAC', key, utf8(time)));
  return `${time}.${toBase64(signature)}`;
}

async function isFreshChallenge(env, challenge) {
  const [time, signature] = String(challenge).split('.');
  if (!(Date.now() - Number(time) < CHALLENGE_LIFETIME_MS)) return false;
  const { challenge: key } = await serverKeys(env);
  return crypto.subtle.verify('HMAC', key, fromBase64(signature), utf8(time));
}

// An install id is the App Attest key id: base64 of a 32-byte hash, so it is
// anonymous and unique per install. Checking the shape first keeps junk ids
// from ever reaching storage. The round trip refuses the 3 other spellings of
// the same 32 bytes (the last character has 2 bits base64 ignores), so one key
// can't be registered under several ids.
const INSTALL_ID = /^[A-Za-z0-9+/]{43}=$/;
const isInstallId = (id) => INSTALL_ID.test(id) && toBase64(fromBase64(id)) === id;

const installFor = (env, installId) => env.INSTALLS.get(env.INSTALLS.idFromName(installId));

/**
 * Checks the App Attest assertion on a request. The app signs the request path
 * followed by the request body, so a signature can't be moved to another
 * request. Returns the install, or null when the request must be refused.
 */
async function authenticate(request, env, path, body) {
  const installId = request.headers.get('X-Install-Id') ?? '';
  const assertion = request.headers.get('X-Assertion');
  if (!isInstallId(installId) || !assertion) return null;
  const install = installFor(env, installId);
  const record = await install.read();
  if (!record) return null;
  try {
    const counter = await verifyAssertion({
      assertion: fromBase64(assertion),
      clientData: concat(utf8(path), body),
      publicKey: fromBase64(record.publicKey),
      appId: env.APP_ID,
    });
    if (!(await install.advanceCounter(counter))) return null;
  } catch {
    return null;
  }
  return { installId, install, record };
}

/** Registers a new install from its App Attest attestation. */
async function attest(env, body) {
  let input;
  try {
    input = JSON.parse(new TextDecoder().decode(body));
  } catch {
    return json({ error: 'bad_request' }, 400);
  }
  const { keyId, attestation, challenge } = input ?? {};
  if (!isInstallId(keyId ?? '') || typeof attestation !== 'string') return json({ error: 'bad_request' }, 400);
  try {
    if (!(await isFreshChallenge(env, challenge))) return refused();
    const publicKey = await verifyAttestation({
      attestation: fromBase64(attestation),
      keyId: fromBase64(keyId),
      clientData: utf8(challenge),
      appId: env.APP_ID,
      environment: env.APP_ATTEST_ENV,
    });
    const created = await installFor(env, keyId).create({ publicKey: toBase64(publicKey), counter: 0 });
    return created ? json({ installId: keyId }) : refused();
  } catch {
    return refused();
  }
}

/** Every transaction and account for the install, read from Plaid and passed straight back. */
async function allTransactions(env, installId, record) {
  if (!record.token) return json({ error: 'no_bank_linked', message: 'Link a bank first.' }, 409);
  const access_token = await unseal(env, installId, record.token);
  let cursor;
  let added = [];
  let hasMore = true;
  let waits = 0;
  while (hasMore) {
    const page = await plaid(env, '/transactions/sync', { access_token, cursor, count: 500 });
    // An empty cursor means Plaid hasn't prepared the history yet (same check as the quickstart).
    if (!page.next_cursor) {
      if (++waits > 10) return json({ error: 'transactions_not_ready', message: 'Plaid is still preparing transactions. Try again in a minute.' }, 503);
      await new Promise((resolve) => setTimeout(resolve, 2000));
      continue;
    }
    cursor = page.next_cursor;
    added = added.concat(page.added);
    hasMore = page.has_more;
  }
  const { accounts } = await plaid(env, '/accounts/get', { access_token });
  return json({ accounts, transactions: added });
}

/** A whole number above zero from a setting, or null when the setting is missing or garbled. */
function positiveSetting(value) {
  const number = Number(value);
  return Number.isInteger(number) && number > 0 ? number : null;
}

/** Forwards one Messages API request to Anthropic, within the model allow-list, the output cap and the daily cap. */
async function relayMessage(env, install, body) {
  let request;
  try {
    request = JSON.parse(new TextDecoder().decode(body));
  } catch {
    return json({ error: 'bad_request' }, 400);
  }
  if (typeof request !== 'object' || request === null || Array.isArray(request)) return json({ error: 'bad_request' }, 400);

  // A missing or garbled limit must stop the relay, not quietly remove the limit.
  const cap = positiveSetting(env.DAILY_MESSAGE_CAP);
  const maxTokens = positiveSetting(env.MAX_OUTPUT_TOKENS);
  if (!cap || !maxTokens) {
    console.error('DAILY_MESSAGE_CAP and MAX_OUTPUT_TOKENS must be whole numbers above zero');
    return json({
      error: 'server_misconfigured',
      message: 'The server\'s request limits are not set up, so cloud requests are off for now.',
    }, 503);
  }

  const allowed = String(env.ALLOWED_MODELS).split(',').map((name) => name.trim());
  if (!allowed.includes(request.model)) {
    return json({ error: 'model_not_allowed', message: `Allowed models: ${allowed.join(', ')}` }, 400);
  }
  // max_tokens bounds what one reply (thinking included) can cost, so the daily cap limits spend, not just request count.
  if (!(Number.isInteger(request.max_tokens) && request.max_tokens > 0 && request.max_tokens <= maxTokens)) {
    return json({ error: 'max_tokens_too_high', message: `max_tokens must be a whole number from 1 to ${maxTokens}.` }, 400);
  }

  // The cap is a server limit, not data logic, so the real clock (UTC day) is right here.
  const today = new Date().toISOString().slice(0, 10);
  if (!(await install.takeMessage(today, cap))) {
    return json({
      error: 'daily_limit_reached',
      message: `This install has used all ${cap} cloud requests for today. The limit resets at midnight UTC.`,
    }, 429);
  }
  const headers = { 'content-type': 'application/json', 'x-api-key': env.ANTHROPIC_API_KEY, 'anthropic-version': '2023-06-01' };
  // Send the body as this server read it, not the raw bytes: if the JSON repeats a key
  // (two "model"s), another parser might pick the other one and skip the checks above.
  const upstream = await fetch('https://api.anthropic.com/v1/messages', { method: 'POST', headers, body: JSON.stringify(request) });
  // Pass the reply through untouched, so streamed replies keep streaming.
  return new Response(upstream.body, {
    status: upstream.status,
    headers: { 'content-type': upstream.headers.get('content-type') ?? 'application/json' },
  });
}

async function route(request, env) {
  const { pathname: path } = new URL(request.url);
  const method = request.method;

  // Public routes: no attestation needed.
  if (method === 'GET' && path === '/health') return json({ ok: true, plaid_env: env.PLAID_ENV });
  if (method === 'GET' && path === '/.well-known/apple-app-site-association') {
    // Lets iOS open the app when a bank's OAuth page sends the user back to /plaid/oauth.
    return json({ applinks: { details: [{ appIDs: [env.APP_ID], components: [{ '/': '/plaid/*' }] }] } });
  }
  if (method === 'GET' && path === '/plaid/oauth') {
    // Only seen if the app isn't installed; otherwise iOS opens the app instead.
    return new Response('<!doctype html><meta name="viewport" content="width=device-width"><p>Open the Sedge app to finish linking your bank.</p>',
      { headers: { 'content-type': 'text/html; charset=utf-8' } });
  }
  if (method === 'GET' && path === '/api/challenge') return json({ challenge: await makeChallenge(env) });

  const body = new Uint8Array(await request.arrayBuffer());
  if (method === 'POST' && path === '/api/attest') return attest(env, body);

  const routes = ['POST /api/create_link_token', 'POST /api/set_access_token', 'GET /api/all_transactions', 'POST /api/messages', 'DELETE /api/install'];
  const name = `${method} ${path}`;
  if (!routes.includes(name)) return json({ error: 'not_found' }, 404);

  const auth = await authenticate(request, env, path, body);
  if (!auth) return refused();
  const { installId, install, record } = auth;

  switch (name) {
    case 'POST /api/create_link_token': {
      const config = {
        client_name: 'Sedge',
        user: { client_user_id: installId },
        products: ['transactions'],
        country_codes: ['US'],
        language: 'en',
      };
      // Set once the redirect URI is registered in the Plaid dashboard (needed for OAuth banks).
      if (env.PLAID_REDIRECT_URI) config.redirect_uri = env.PLAID_REDIRECT_URI;
      const { link_token } = await plaid(env, '/link/token/create', config);
      return json({ link_token });
    }
    case 'POST /api/set_access_token': {
      // Same form body as the quickstart: public_token=...
      const publicToken = new URLSearchParams(new TextDecoder().decode(body)).get('public_token');
      if (!publicToken) return json({ error: 'bad_request', message: 'public_token is required' }, 400);
      const { access_token, item_id } = await plaid(env, '/item/public_token/exchange', { public_token: publicToken });
      await install.update({ token: await seal(env, installId, access_token), itemId: item_id });
      // Linking again replaces the old bank login, so remove the old one at Plaid too.
      if (record.token) {
        await plaid(env, '/item/remove', { access_token: await unseal(env, installId, record.token) })
          .catch((error) => console.error('Could not remove replaced item', record.itemId, error.message));
      }
      // The access token never leaves the server.
      return json({ ok: true });
    }
    case 'GET /api/all_transactions':
      return allTransactions(env, installId, record);
    case 'POST /api/messages':
      return relayMessage(env, install, body);
    case 'DELETE /api/install': {
      if (record.token) {
        let accessToken;
        try {
          accessToken = await unseal(env, installId, record.token);
        } catch {
          // The token can't be read (for example, SERVER_KEY changed), so the bank link
          // can't be removed at Plaid. Deleting the user's data here must still work.
          console.error('Could not decrypt token; Plaid item not removed', record.itemId);
          await install.destroy();
          return json({
            deleted: true,
            plaid_item_removed: false,
            message: 'Your data on this server is deleted, but the bank link at Plaid could not be removed. You can also remove Sedge from your bank\'s connected apps.',
          });
        }
        try {
          await plaid(env, '/item/remove', { access_token: accessToken });
        } catch (error) {
          // Already gone at Plaid is fine; anything else keeps the token so the user can retry.
          if (!['ITEM_NOT_FOUND', 'INVALID_ACCESS_TOKEN'].includes(error.code)) throw error;
        }
      }
      await install.destroy();
      return json({ deleted: true });
    }
  }
}

export default {
  async fetch(request, env) {
    try {
      return await route(request, env);
    } catch (error) {
      if (error instanceof PlaidError) return json({ error: 'plaid_error', plaid_error_code: error.code }, 502);
      console.error(error.message);
      return json({ error: 'server_error' }, 500);
    }
  },
};
