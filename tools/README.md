For python fake data generation

`uv run python fake_gen.py` writes every persona under `data/`: maya and daniel (dev), jordan and elena (held-out test),
and nia and otis (validation, used to choose models and settings before the single test run; see `personas.md`).
It checks each answer key's invariants before writing and then records seeds and file hashes in `data/manifest.json`.
`uv run python checks.py` regenerates the data in memory and checks it against that manifest, counts merchant names
shared between the splits, and compares the validation questions' type mix with dev's. `uv run pytest` runs all the tests.

## The question bank

`eval/questions.csv` holds the questions, one per row. Add rows by copying one of the examples.

Run these from `tools/`:

1. `uv run python eval/truth_db.py` rebuilds `eval/truth.db` (git ignores it) from every persona's data.
   `--personas maya,daniel` builds it from just those, so the held-out personas stay unopened.
2. `uv run python eval/fill_answers.py` checks every row and writes `expected` from its `truth_sql`.
   Rows for a persona not in truth.db are listed as skipped and keep their `expected`.
3. `uv run python eval/test_truth_db.py` checks truth.db against the answer keys of the personas it holds.

## Plaid Sandbox round trip

`plaid_sandbox.py` reruns the evaluation on data that came back through Plaid (see `personas.md`):

- `uv run python plaid_sandbox.py configs` writes `data/<persona>/plaid_user.json`, one custom Sandbox user per
  persona, and says whether each fits Plaid's limits (250 transactions, 55 KB, 10 accounts).
- `uv run python plaid_sandbox.py check <persona> <pulled.json>` matches a saved `/api/all_transactions` reply to the
  persona's rows and checks transactions, totals, daily balances and every question's `expected` against the fixtures.
- `uv run python plaid_sandbox.py dry-run` does the same on a made-up Plaid reply for the dev and validation personas.

To pull one persona (Plaid keys loaded in the shell, the quickstart server running; for jordan and elena, read only
the PASS/FAIL lines and keep the pulled file outside the repo):

```sh
P=maya
jq -n --arg id "$PLAID_CLIENT_ID" --arg secret "$PLAID_SECRET" --rawfile pw data/$P/plaid_user.json \
  '{client_id: $id, secret: $secret, institution_id: "ins_109508", initial_products: ["transactions"],
    options: {override_username: "user_custom", override_password: ($pw | rtrimstr("\n")), transactions: {days_requested: 730}}}' \
  | curl -s https://sandbox.plaid.com/sandbox/public_token/create -H 'Content-Type: application/json' -d @- \
  | jq -r .public_token > "$TMPDIR/pt"
curl -s -X POST localhost:8000/api/set_access_token --data-urlencode "public_token=$(cat "$TMPDIR/pt")" > /dev/null
curl -s localhost:8000/api/all_transactions > "$TMPDIR/$P-pulled.json"
uv run python plaid_sandbox.py check $P "$TMPDIR/$P-pulled.json"
```
