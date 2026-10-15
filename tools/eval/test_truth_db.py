"""Checks that truth.db agrees with each persona's answer key.

Run from tools/:  uv run python eval/test_truth_db.py
"""
import sqlite3
import tempfile
import unittest
from pathlib import Path

import fill_answers
import truth_db


class TruthDbTest(unittest.TestCase):
  @classmethod
  def setUpClass(cls):
    # Build into a temp folder so the test never touches the real truth.db.
    cls.tmp = tempfile.TemporaryDirectory()
    path = Path(cls.tmp.name) / "truth.db"
    truth_db.build(path)
    cls.db = sqlite3.connect(path)

  @classmethod
  def tearDownClass(cls):
    cls.db.close()
    cls.tmp.cleanup()

  def test_totals_match_answer_key(self):
    for persona in truth_db.PERSONAS:
      with self.subTest(persona=persona):
        totals = truth_db.load(persona, "answer_key")["totals"]
        # Plaid amounts are negative when money comes in, so income is the negated sum.
        income, spending = self.db.execute(
          "SELECT ROUND(-SUM(CASE WHEN kind = 'income' THEN amount END), 2),"
          " ROUND(SUM(CASE WHEN kind = 'spending' THEN amount END), 2)"
          " FROM tx WHERE persona = ? AND NOT pending", [persona]).fetchone()
        self.assertEqual(income, totals["income"])
        self.assertEqual(spending, totals["spending"])

  def test_last_daily_balance_is_ending_balance(self):
    rows = self.db.execute(
      "SELECT a.account_id, d.balance, a.ending_balance FROM accounts a"
      " JOIN daily_balance d ON d.account_id = a.account_id AND d.date = '2026-06-30'").fetchall()
    self.assertTrue(rows)
    for account_id, balance, ending in rows:
      self.assertEqual(balance, ending, account_id)

  def test_fill_rejects_broken_rows(self):
    base = {c: "" for c in fill_answers.COLUMNS} | {"persona": "maya", "type": "aggregation", "split": "dev"}
    rows = [
      base | {"id": "ok", "answer_type": "number", "truth_sql": "SELECT 1.234"},
      base | {"id": "ok", "answer_type": "number", "truth_sql": "SELECT 1"},
      base | {"id": "bad-sql", "answer_type": "number", "truth_sql": "SELECT nope FROM tx"},
      base | {"id": "many", "answer_type": "number", "truth_sql": "SELECT amount FROM tx"},
      base | {"id": "empty", "answer_type": "list", "truth_sql": "SELECT name FROM tx WHERE 0"},
      base | {"id": "who", "persona": "bob", "answer_type": "number", "truth_sql": "SELECT 1"},
      base | {"id": "short", "notes": None},  # what csv gives for a row missing cells
    ]
    errors = fill_answers.fill(rows, self.db)
    self.assertEqual(rows[0]["expected"], "1.23")
    self.assertEqual([e.split(":")[0] for e in errors], ["ok", "bad-sql", "many", "empty", "who", "short"])


if __name__ == "__main__":
  unittest.main()
