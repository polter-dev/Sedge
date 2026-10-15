"""Build tools/eval/truth.db, the grader's SQLite copy of every persona's data.

Run from tools/:  uv run python eval/truth_db.py
The file is rebuilt from scratch each time, so two runs give the same tables.
"""
import csv
import json
import sqlite3
from datetime import date, timedelta
from pathlib import Path

# Paths are relative to this file, so the script works from any folder.
EVAL = Path(__file__).resolve().parent
DATA = EVAL.parent / "data"
DB_PATH = EVAL / "truth.db"
CATEGORIES = EVAL / "categories.csv"

PERSONAS = ["maya", "daniel", "jordan", "elena"]
FIRST_DAY = date(2026, 1, 1)
LAST_DAY = date(2026, 6, 30)

# Fields straight from transactions.json, then the answer-key labels.
TX_FIELDS = ["transaction_id", "account_id", "date", "name", "amount", "iso_currency_code", "pending", "pending_transaction_id"]
LABEL_FIELDS = ["true_merchant", "kind", "recurring", "linked_transaction_id"]

SCHEMA = """
CREATE TABLE tx (
  persona TEXT, transaction_id TEXT PRIMARY KEY, account_id TEXT, date TEXT, name TEXT,
  amount REAL, iso_currency_code TEXT, pending INTEGER, pending_transaction_id TEXT,
  true_merchant TEXT, kind TEXT, recurring TEXT, linked_transaction_id TEXT, category TEXT
);
-- "limit" is an SQL keyword, so the Plaid balances.limit field is stored as credit_limit.
CREATE TABLE accounts (
  persona TEXT, account_id TEXT PRIMARY KEY, name TEXT, official_name TEXT, mask TEXT,
  type TEXT, subtype TEXT, current REAL, available REAL, credit_limit REAL,
  iso_currency_code TEXT, unofficial_currency_code TEXT,
  starting_balance REAL, ending_balance REAL
);
CREATE TABLE daily_balance (
  persona TEXT, account_id TEXT, date TEXT, balance REAL,
  PRIMARY KEY (account_id, date)
);
"""


def load(persona, name):
  """Read one JSON file from tools/data/<persona>/."""
  with open(DATA / persona / f"{name}.json") as f:
    return json.load(f)


def load_categories():
  """Map true_merchant -> category. The CSV is optional; a missing one leaves every category blank."""
  if not CATEGORIES.exists():
    return {}
  with open(CATEGORIES, newline="") as f:
    return {row["true_merchant"]: row["category"] for row in csv.DictReader(f)}


def daily_balances(account, start_balance, posted):
  """End-of-day balance for every date, Jan 1 - Jun 30.

  Depository balances fall when money leaves (positive amount); credit balances
  rise, because they show money owed. Cents avoid float drift over six months.
  """
  sign = 1 if account["type"] == "credit" else -1
  change_by_day = {}
  for t in posted:
    change_by_day[t["date"]] = change_by_day.get(t["date"], 0) + sign * round(t["amount"] * 100)
  cents = round(start_balance * 100)
  day = FIRST_DAY
  while day <= LAST_DAY:
    cents += change_by_day.get(day.isoformat(), 0)
    yield day.isoformat(), cents / 100
    day += timedelta(days=1)


def build(db_path=DB_PATH):
  """Delete and rebuild the truth database at db_path."""
  db_path.unlink(missing_ok=True)
  categories = load_categories()
  db = sqlite3.connect(db_path)
  db.executescript(SCHEMA)
  for persona in PERSONAS:
    transactions = load(persona, "transactions")
    key = load(persona, "answer_key")
    labels = {entry["transaction_id"]: entry for entry in key["transactions"]}
    for t in transactions:
      label = labels[t["transaction_id"]]  # a KeyError here means the answer key is out of date
      row = [persona] + [t[f] for f in TX_FIELDS] + [label[f] for f in LABEL_FIELDS]
      row.append(categories.get(label["true_merchant"], ""))
      db.execute(f"INSERT INTO tx VALUES ({','.join('?' * len(row))})", row)

    balances = {entry["account_id"]: entry for entry in key["accounts"]}
    for a in load(persona, "accounts"):
      b = a["balances"]
      start = balances[a["account_id"]]["starting_balance"]
      db.execute(
        "INSERT INTO accounts VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        [persona, a["account_id"], a["name"], a["official_name"], a["mask"], a["type"], a["subtype"],
         b["current"], b["available"], b["limit"], b["iso_currency_code"], b["unofficial_currency_code"],
         start, balances[a["account_id"]]["ending_balance"]],
      )
      # Pending records are not in the balance yet, matching the generator.
      posted = [t for t in transactions if t["account_id"] == a["account_id"] and not t["pending"]]
      db.executemany(
        "INSERT INTO daily_balance VALUES (?,?,?,?)",
        [(persona, a["account_id"], day, bal) for day, bal in daily_balances(a, start, posted)],
      )
  db.commit()
  db.close()


if __name__ == "__main__":
  build()
  print(f"wrote {DB_PATH}")
