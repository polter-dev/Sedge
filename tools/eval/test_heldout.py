"""Checks that a test run on a fresh clone never opens the held-out personas' data.

Run from tools/:  uv run pytest
"""
import builtins
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import test_truth_db  # imported as a module so pytest doesn't collect TruthDbTest twice
import truth_db

HELD_OUT = {"jordan", "elena"}


class HeldOutTest(unittest.TestCase):
  def test_missing_truth_db_never_opens_heldout(self):
    real_open = builtins.open

    def guarded(file, *args, **kwargs):
      # Raises before the file is read, so the held-out data stays unseen even when this fails.
      if HELD_OUT & set(Path(str(file)).parts):
        raise AssertionError(f"held-out file opened: {file}")
      return real_open(file, *args, **kwargs)

    # A fresh clone has no eval/truth.db, since git ignores it.
    with tempfile.TemporaryDirectory() as tmp, \
        mock.patch.object(truth_db, "DB_PATH", Path(tmp) / "missing.db"), \
        mock.patch("builtins.open", guarded):
      test_truth_db.TruthDbTest.setUpClass()
      try:
        self.assertEqual(test_truth_db.TruthDbTest.personas, ["maya", "daniel"])
      finally:
        test_truth_db.TruthDbTest.tearDownClass()


if __name__ == "__main__":
  unittest.main()
