For python fake data generation

## How to use the question bank

Run these from `tools/`.

1. `uv run python eval/truth_db.py` rebuilds `eval/truth.db` (git ignores it) from `data/<persona>/`.
   Tables: `tx` (every transaction plus its answer-key labels and `category` from
   `eval/categories.csv`), `accounts` (Plaid fields plus starting and ending balance) and
   `daily_balance` (end-of-day balance per account, Jan 1 - Jun 30).
2. Add rows to `eval/questions.csv`, copying one of the examples. Write a `truth_sql` that
   returns one column, or leave it empty and type `expected` by hand.
3. `uv run python eval/fill_answers.py` checks every row and writes `expected`: numbers to
   the cent, lists sorted and joined with ` | `, yes_no as `yes` or `no`. On any problem it
   prints one line per bad row and changes nothing.
4. `uv run python eval/test_truth_db.py` checks truth.db against the answer keys.
