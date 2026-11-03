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
