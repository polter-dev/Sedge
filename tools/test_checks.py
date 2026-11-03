"""Checks that the generated data keeps its invariants and matches tools/data/manifest.json.

Run from tools/:  uv run pytest
The data is regenerated in memory, so no held-out file is opened (only hashed), and
failure messages carry counts, never a held-out persona's values.
"""
import copy
import json
import unittest

import checks


class ChecksTest(unittest.TestCase):
  @classmethod
  def setUpClass(cls):
    cls.built = checks.regenerate()

  def test_every_persona_keeps_its_invariants(self):
    for name, files in self.built.items():
      with self.subTest(persona=name):
        failures = checks.invariant_failures(checks.fake_gen.PERSONAS[name], files)
        self.assertEqual(sum(failures.values()), 0, f"{name}: {sum(failures.values())} broken records")

  def test_invariants_catch_a_broken_answer_key(self):
    # Unlink one refund and take a cent off the card side of one payment in a dev persona,
    # and expect exactly the invariants those two edits break to fail.
    files = copy.deepcopy(self.built["maya"])
    labels = {e["transaction_id"]: e for e in files["answer_key"]["transactions"]}
    refund = next(t for t in files["transactions"] if labels[t["transaction_id"]]["kind"] == "spending" and t["amount"] < 0)
    labels[refund["transaction_id"]]["linked_transaction_id"] = None
    payment = next(t for t in files["transactions"] if labels[t["transaction_id"]]["kind"] == "card_payment" and t["amount"] < 0)
    payment["amount"] = round(payment["amount"] + 0.01, 2)
    failures = checks.invariant_failures(checks.fake_gen.PERSONAS["maya"], files)
    self.assertEqual([inv for inv in checks.INVARIANTS if failures[inv]], ["pairs", "refunds", "card_payments", "balances"])

  def test_data_files_match_the_manifest(self):
    recorded = json.loads(checks.MANIFEST.read_text())
    self.assertEqual(recorded["generator_sha256"], checks.manifest(self.built)["generator_sha256"])
    mismatched = [path for path, ok in checks.file_mismatches(self.built, recorded) if not ok]
    self.assertEqual(mismatched, [])

  def test_validation_merchants_are_new(self):
    self.assertEqual(checks.shared_merchants(), 0)

  def test_validation_question_mix_matches_dev(self):
    self.assertEqual(checks.mix_off(checks.type_mix()), [])


if __name__ == "__main__":
  unittest.main()
