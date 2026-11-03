"""Fill the `expected` column of tools/eval/questions.csv from truth.db.

Run from tools/:  uv run python eval/fill_answers.py [questions.csv]
Every row is checked first. If any row has a problem, each one is printed as a
single line with its id and nothing is written, so a half-filled file never exists.
Rows for a persona that truth.db wasn't built with are skipped (listed, not errors),
so their `expected` stays as it is.
"""
import csv
import sqlite3
import sys
from pathlib import Path

EVAL = Path(__file__).resolve().parent
DB_PATH = EVAL / "truth.db"
QUESTIONS = EVAL / "questions.csv"

COLUMNS = ["id", "persona", "type", "split", "as_of", "question", "answer_type", "truth_sql", "expected",
           "tolerance", "expected_tool", "needs_clarification", "clarify_reply", "notes",
           "organizer_limited"]
ALLOWED = {
  "persona": {"maya", "daniel", "jordan", "elena", "nia", "otis"},
  "type": {"aggregation", "comparison", "recurring", "temporal", "whatif", "profile", "clarify", "out_of_scope"},
  "split": {"dev", "validation", "test"},
  "answer_type": {"number", "list", "yes_no", "text"},
  # "yes" marks a question the organizer can't get right by design; empty means it can.
  "organizer_limited": {"yes", ""},
}


def format_answer(answer_type, rows):
  """Turn query rows into the text stored in `expected`. Raises ValueError with a short reason."""
  if any(len(r) != 1 for r in rows):
    raise ValueError("truth_sql must return exactly one column")
  values = [r[0] for r in rows]
  if answer_type == "list":
    if not values:
      raise ValueError("truth_sql returned no rows")
    # Sorting makes the expected text independent of the query's row order.
    return " | ".join(sorted(str(v) for v in values))
  if not values or values[0] is None:
    # SUM() over zero rows gives one NULL row, so treat that as empty too.
    raise ValueError("truth_sql returned no value (wrap it in COALESCE if 0 is the answer)")
  if len(values) > 1:
    raise ValueError(f"truth_sql returned {len(values)} values for a single answer")
  value = values[0]
  if answer_type == "number":
    if not isinstance(value, (int, float)):
      raise ValueError(f"truth_sql returned {value!r}, not a number")
    return f"{value:.2f}"  # rounded to cents
  if answer_type == "yes_no":
    # SQL comparisons give 1 or 0; a query may also return 'yes' or 'no' directly.
    if value in (0, 1):
      return "yes" if value else "no"
    if str(value).lower() in ("yes", "no"):
      return str(value).lower()
    raise ValueError(f"truth_sql returned {value!r}, not yes/no or 1/0")
  return str(value)


def fill(rows, db):
  """Check every row and fill `expected` in place. Returns (error lines, skipped ids)."""
  errors, skipped = [], []
  seen = set()
  present = {p for (p,) in db.execute("SELECT DISTINCT persona FROM accounts")}
  for n, row in enumerate(rows, start=2):  # line 1 is the header
    rid = row["id"] or f"(line {n})"
    # csv fills a short row with None and puts extra cells under a None key.
    if None in row or None in row.values():
      errors.append(f"{rid}: wrong number of columns")
      continue
    if not row["id"] or row["id"] in seen:
      errors.append(f"{rid}: missing or duplicate id")
    seen.add(row["id"])
    bad = [f"unknown {col} {row[col]!r}" for col, allowed in ALLOWED.items() if row[col] not in allowed]
    if bad:
      errors.append(f"{rid}: {', '.join(bad)}")
      continue
    if row["persona"] not in present:
      skipped.append(rid)
      continue
    if not row["truth_sql"].strip():
      continue  # hand-written answer, kept as is
    try:
      result = db.execute(row["truth_sql"]).fetchall()
      row["expected"] = format_answer(row["answer_type"], result)
    except sqlite3.Error as e:
      errors.append(f"{rid}: SQL error: {e}")
    except ValueError as e:
      errors.append(f"{rid}: {e}")
  return errors, skipped


def main(path=QUESTIONS):
  """Read, check, fill and rewrite the questions file. Returns a process exit code."""
  if not DB_PATH.exists():
    print(f"{DB_PATH} is missing; run eval/truth_db.py first", file=sys.stderr)
    return 1
  with open(path, newline="") as f:
    reader = csv.DictReader(f)
    if reader.fieldnames != COLUMNS:
      print(f"{path}: header must be {','.join(COLUMNS)}", file=sys.stderr)
      return 1
    rows = list(reader)
  # Read-only connection, so a truth_sql can never change the truth data.
  db = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True)
  errors, skipped = fill(rows, db)
  db.close()
  if errors:
    print("\n".join(errors), file=sys.stderr)
    return 1
  with open(path, "w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=COLUMNS, lineterminator="\n")
    writer.writeheader()
    writer.writerows(rows)
  filled = sum(1 for r in rows if r["truth_sql"].strip() and r["id"] not in skipped)
  print(f"filled {filled} answers in {path}")
  if skipped:
    print(f"skipped {len(skipped)} rows whose persona is not in truth.db: {', '.join(skipped)}")
  return 0


if __name__ == "__main__":
  sys.exit(main(*sys.argv[1:]))
