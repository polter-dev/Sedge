# Sedge helper server

A small Cloudflare Worker that release builds of Sedge talk to instead of the
local Plaid quickstart. It keeps every secret off the phone: Plaid's keys, each
install's Plaid access token, and the Anthropic key.

## What the server stores, in plain English

The server does **not** store transactions, balances, account details,
questions, or answers. When the app asks for its transactions, the server asks
Plaid for them and passes them straight back to the phone without saving them.
Cloud model requests are passed to Anthropic and the replies passed straight
back, also without saving them.

For each app install, the server keeps only:

- an **install id**: a random-looking id the phone makes with Apple's App
  Attest. It doesn't contain a name, email, phone number or device id.
- the install's **Plaid access token**, encrypted, and Plaid's id for that bank
  link (needed to remove it). The token is never sent to the phone.
- the install's App Attest **public key** and a request counter, used to check
  that requests really come from the Sedge app.
- **how many cloud requests** the install made today, for the daily limit.

"Disconnect bank and delete my data" in the app calls `DELETE /api/install`,
which removes the bank link at Plaid and deletes everything above for that
install. Removing the bank link at Plaid is best effort in one case: if the
saved token can't be decrypted (for example, after `SERVER_KEY` changed), the
server can't ask Plaid to remove it. It still deletes everything it stores and
replies `{"deleted": true, "plaid_item_removed": false, "message": ...}`; the
user can also remove Sedge from their bank's connected apps.

Cloudflare keeps its own request logs for a few days: the time, path, status
and request headers (which include the install id). Request and reply bodies
are not logged.

## Routes

| Route | Needs App Attest | What it does |
|---|---|---|
| `GET /health` | no | `{"ok": true, "plaid_env": "sandbox"}` |
| `GET /.well-known/apple-app-site-association` | no | Universal-link file for Plaid's OAuth redirect |
| `GET /plaid/oauth` | no | The OAuth redirect page (iOS opens the app instead when it's installed) |
| `GET /api/challenge` | no | A one-time challenge for attestation, valid 5 minutes |
| `POST /api/attest` | no (this *is* the attestation) | Registers a new install |
| `POST /api/create_link_token` | yes | Same reply as the quickstart: `{"link_token": ...}` |
| `POST /api/set_access_token` | yes | Same form body as the quickstart: `public_token=...`. Replies `{"ok": true}` |
| `GET /api/all_transactions` | yes | Same reply as the quickstart: `{"accounts": [...], "transactions": [...]}` |
| `POST /api/messages` | yes | A Claude Messages API request body, relayed to Anthropic. `model` must be in `ALLOWED_MODELS` and `max_tokens` at most `MAX_OUTPUT_TOKENS`. The server forwards the JSON as it read it, re-encoded, not the raw bytes. |
| `DELETE /api/install` | yes | Removes the Plaid item (best effort, see above) and everything stored for the install |

The Plaid routes keep the quickstart's paths and reply shapes, so the app only
needs a different base URL and two extra headers.

Errors are JSON with an `error` code and, where useful, a `message`:
`attestation_required` (401), `model_not_allowed` (400),
`max_tokens_too_high` (400), `daily_limit_reached` (429),
`server_misconfigured` (503, when `DAILY_MESSAGE_CAP` or `MAX_OUTPUT_TOKENS` is
missing or not a whole number above zero), `no_bank_linked` (409),
`transactions_not_ready` (503), `plaid_error` with `plaid_error_code` (502).

## How the app proves it's the app (App Attest)

Requests are checked with Apple's App Attest, so only the real Sedge app on a
real iPhone can use the server.

Once per install:

1. `DCAppAttestService.shared.generateKey()` gives a `keyId`. That is the install id.
2. `GET /api/challenge` gives `challenge` (a string).
3. `attestKey(keyId, clientDataHash: SHA256(utf8(challenge)))` gives the attestation.
4. `POST /api/attest` with JSON `{"keyId": ..., "attestation": <base64>, "challenge": ...}`.

On every other request, send two headers:

- `X-Install-Id`: the `keyId`
- `X-Assertion`: base64 of `generateAssertion(keyId, clientDataHash: SHA256(utf8(path) + body))`,
  where `path` is e.g. `/api/messages` and `body` is the exact request body bytes
  (empty for GET and DELETE).

The server refuses an assertion whose counter isn't higher than the last one,
so a captured request can't be replayed. Because of that, **send requests one
at a time**: wait for each reply before making the next assertion. Two requests
in flight together can arrive out of order, and the one with the lower counter
is then refused with 401. After `DELETE /api/install`, or if the
app is reinstalled, the app makes a new key and attests again.

App Attest doesn't work in the Simulator. Debug builds keep using the local
quickstart, which ignores these headers.

## Settings

Plain settings live in `wrangler.jsonc` under `vars`:

| Name | Meaning |
|---|---|
| `PLAID_ENV` | `sandbox` or `production`. The one switch for Plaid's environment. |
| `APP_ID` | `<Apple Team ID>.<bundle id>`, e.g. `ABCDE12345.dev.polter.sedge` |
| `APP_ATTEST_ENV` | `development` for builds run from Xcode, `production` for TestFlight and the App Store |
| `ALLOWED_MODELS` | Comma-separated model ids the relay accepts |
| `DAILY_MESSAGE_CAP` | Cloud requests per install per UTC day. Missing or not a whole number above zero: the relay refuses every request. |
| `MAX_OUTPUT_TOKENS` | Highest `max_tokens` a relayed request may ask for (16000, what the app sends). Larger requests are refused, not trimmed. Same rule as above when missing. |
| `PLAID_REDIRECT_URI` | Empty, or `https://<server>/plaid/oauth` once registered with Plaid |

Secrets live only in Cloudflare's secret store, never in this repo:
`PLAID_CLIENT_ID`, `PLAID_SECRET`, `ANTHROPIC_API_KEY`, `SERVER_KEY`
(32 random bytes, base64; it encrypts the stored Plaid tokens).

## Deploy (Cloudflare Workers, free plan)

From `server/`:

1. `npm install`
2. `npx wrangler login` (opens the browser to sign in to Cloudflare)
3. Set `APP_ID` and `APP_ATTEST_ENV` in `wrangler.jsonc`.
4. Add the secrets. Each command asks for the value; paste it in, don't type it on the command line.
   ```sh
   npx wrangler secret put PLAID_CLIENT_ID
   npx wrangler secret put PLAID_SECRET        # the Sandbox secret while PLAID_ENV is sandbox
   npx wrangler secret put ANTHROPIC_API_KEY
   openssl rand -base64 32 | npx wrangler secret put SERVER_KEY
   ```
   Keep `SERVER_KEY` the same from then on: changing it makes every saved Plaid token unreadable, and each user would have to link their bank again.
5. `npx wrangler deploy`. It prints the URL, e.g. `https://sedge-server.<account>.workers.dev`.
6. Check it: `curl https://sedge-server.<account>.workers.dev/health`

To move to Plaid production later: set `PLAID_ENV` to `production`, run
`npx wrangler secret put PLAID_SECRET` with the production secret, and deploy.

Live logs: `npx wrangler tail`.

## Plaid OAuth redirect (needed for big banks in production)

1. The app needs the Associated Domains capability with
   `applinks:sedge-server.<account>.workers.dev` (Xcode > target > Signing & Capabilities > + Capability > Associated Domains).
2. In the Plaid Dashboard: Developers > API > Allowed redirect URIs > add
   `https://sedge-server.<account>.workers.dev/plaid/oauth`, then save.
3. Set `PLAID_REDIRECT_URI` in `wrangler.jsonc` to that same URL and deploy.
   (Link token creation fails if the URI is set here but not registered with Plaid.)
4. Check the universal-link file: `curl https://sedge-server.<account>.workers.dev/.well-known/apple-app-site-association`

## Test

`npm test` runs the tests with Node's built-in test runner. Real attestations
only come from an iPhone, so the tests build look-alike ones signed by a
throwaway test root.

To run the server on your Mac: put placeholder values for the four secrets in
`server/.dev.vars` (git ignores it), then `npx wrangler dev`.

## Limits worth knowing

- Cloudflare's free plan allows 100,000 requests a day, plenty for TestFlight.
- The free plan also caps each request at 10 ms of CPU. Sandbox syncs fit easily;
  a real account with years of transactions may not, so move to Workers Paid
  ($5/month, much higher CPU limit) before switching `PLAID_ENV` to production.
- Each sync downloads the full history again (like the quickstart), because the
  server doesn't keep Plaid's sync cursor.
