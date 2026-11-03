"""Checks the Plaid Sandbox configs and the round-trip check on a made-up Plaid reply.

Run from tools/:  uv run pytest
Only the dev and validation personas are used; the held-out configs are checked by size alone.
"""
import unittest

import plaid_sandbox as ps


class PlaidSandboxTest(unittest.TestCase):
  def test_configs_are_current_and_fit_plaids_limits(self):
    for persona in ps.PERSONAS:
      with self.subTest(persona=persona):
        on_disk = (ps.truth_db.DATA / persona / "plaid_user.json").read_text()
        ok, *_ = ps.fits(on_disk)
        self.assertTrue(ok, f"{persona}: too big for one custom user")
        if persona not in ps.HELD_OUT:
          self.assertEqual(on_disk, ps.config_text(persona), "rerun plaid_sandbox.py configs")

  def test_round_trip_passes_for_dev_and_validation(self):
    for persona in ps.DEV_AND_VALIDATION:
      with self.subTest(persona=persona):
        results, details = ps.check(persona, ps.fake_reply(ps.config(persona)))
        self.assertTrue(all(results.values()), [k for k, ok in results.items() if not ok])
        self.assertGreater(details["questions compared"], 0)

  def test_a_cent_off_fails(self):
    pulled = ps.fake_reply(ps.config("maya"))
    pulled["transactions"][0]["amount"] = round(pulled["transactions"][0]["amount"] + 0.01, 2)
    results, details = ps.check("maya", pulled)
    self.assertFalse(results["transactions matched"])
    self.assertEqual(details["reasons"], {"amount differs": 1})
    self.assertEqual(details["unmatched fixture"], 1)
    self.assertFalse(results["totals"] and results["balances every day"])

  def test_a_flipped_sign_is_named(self):
    pulled = ps.fake_reply(ps.config("maya"))
    pulled["transactions"][0]["amount"] *= -1
    results, details = ps.check("maya", pulled)
    self.assertEqual(details["reasons"], {"sign flipped": 1})
    self.assertFalse(all(results.values()))

  def test_a_pending_row_breaks_the_balances(self):
    # Matched by key, but a pending row isn't in the balance yet, so the worked-back Jan 1 balance moves.
    pulled = ps.fake_reply(ps.config("maya"))
    pulled["transactions"][0]["pending"] = True
    results, details = ps.check("maya", pulled)
    self.assertTrue(results["transactions matched"])
    self.assertEqual(details["pending"], 1)
    self.assertFalse(results["balances every day"])


if __name__ == "__main__":
  unittest.main()
