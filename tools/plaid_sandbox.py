"""Plaid Sandbox copies of the personas, and a check that data pulled back through Plaid equals the fixtures.

Run from tools/:
  uv run python plaid_sandbox.py configs                        writes data/<persona>/plaid_user.json for every persona
  uv run python plaid_sandbox.py check <persona> <pulled.json>  matches a pulled /api/all_transactions reply to the
                                                                persona's fixtures, checks every answer is unchanged, and
                                                                saves the reply and result in data/<persona>/
  uv run python plaid_sandbox.py dry-run                        runs check on a made-up Plaid reply for the dev and
                                                                validation personas, without calling Plaid
Held-out personas (jordan, elena) print counts and pass/fail only, never their values.
"""
import copy
import csv
import hashlib
import json
import random
import sqlite3
import string
import sys
import tempfile
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS / "eval"))  # truth_db and fill_answers live there and aren't a package
import fill_answers  # noqa: E402
import truth_db  # noqa: E402
from checks import HELD_OUT, cents  # noqa: E402

PERSONAS = truth_db.PERSONAS
DEV_AND_VALIDATION = [p for p in PERSONAS if p not in HELD_OUT]
# Plaid's limits for one custom user: about 250 transactions, about 55 KB, at most 10 accounts.
MAX_TRANSACTIONS, MAX_BYTES, MAX_ACCOUNTS = 250, 55_000, 10
TX_FIELDS = set(truth_db.TX_FIELDS)


def mask(index):
  """Plaid hands back new account ids, so each account carries its position as a mask to be found again by."""
  return f"{index + 1:04d}"


def config(persona):
  """The custom Sandbox user for a persona (https://plaid.com/docs/sandbox/user-custom/)."""
  transactions = truth_db.load(persona, "transactions")
  return {
    "roll_dates_forward": False,  # keep the 2026 dates; past dates come back posted
    "override_accounts": [{
      "type": a["type"],
      "subtype": a["subtype"],
      # Plaid shows starting_balance as the current balance, and every date is past, so it is the June 30 balance.
      "starting_balance": a["balances"]["current"],
      "currency": a["balances"]["iso_currency_code"],
      "meta": {"name": a["name"], "mask": mask(i)},
      "inflow_model": {"type": "none"},  # no paychecks of Plaid's own on top of ours
      # Both conventions are the same: a positive amount is money leaving the account.
      "transactions": [{"date_transacted": t["date"], "date_posted": t["date"], "amount": t["amount"],
                        "description": t["name"], "currency": t["iso_currency_code"]}
                       for t in transactions if t["account_id"] == a["account_id"]],
    } for i, a in enumerate(truth_db.load(persona, "accounts"))],
  }


def config_text(persona):
  """The config as pasted into Plaid: compact, because the size limit counts every byte."""
  return json.dumps(config(persona), separators=(",", ":")) + "\n"


def fits(text):
  cfg = json.loads(text)
  count = sum(len(a["transactions"]) for a in cfg["override_accounts"])
  ok = count <= MAX_TRANSACTIONS and len(text.encode()) <= MAX_BYTES and len(cfg["override_accounts"]) <= MAX_ACCOUNTS
  return ok, count, len(cfg["override_accounts"]), len(text.encode())


def write_configs():
  all_fit = True
  for persona in PERSONAS:
    text = config_text(persona)
    (truth_db.DATA / persona / "plaid_user.json").write_text(text)
    ok, count, n_accounts, size = fits(text)
    all_fit &= ok
    if persona in HELD_OUT:
      print(f"{persona}: {'ok' if ok else 'too big'}")
    else:
      print(f"{persona}: {count} transactions, {n_accounts} accounts, {size / 1000:.1f} KB, {'ok' if ok else 'too big'}")
  return 0 if all_fit else 1


def fake_reply(cfg, seed=0):
  """What /api/all_transactions could return for cfg: new ids, Plaid's field names and the extra fields it adds."""
  rng = random.Random(seed)
  def new_id():
    return "".join(rng.choices(string.ascii_letters + string.digits, k=37))
  accounts, transactions = [], []
  for a in cfg["override_accounts"]:
    account_id = new_id()
    balance = a["starting_balance"]
    accounts.append({
      "account_id": account_id, "persistent_account_id": new_id(), "holder_category": "personal",
      "balances": {"available": balance if a["type"] == "depository" else None, "current": balance,
                   "iso_currency_code": a["currency"], "limit": None, "unofficial_currency_code": None},
      "mask": a["meta"]["mask"], "name": a["meta"]["name"], "official_name": None,
      "type": a["type"], "subtype": a["subtype"],
    })
    for t in a["transactions"]:
      transactions.append({
        "transaction_id": new_id(), "account_id": account_id, "account_owner": None,
        "date": t["date_posted"], "authorized_date": t["date_transacted"], "datetime": None, "authorized_datetime": None,
        "name": t["description"], "original_description": None, "merchant_name": t["description"].title(),
        "merchant_entity_id": None, "logo_url": None, "website": None, "counterparties": [],
        "amount": t["amount"], "iso_currency_code": t["currency"], "unofficial_currency_code": None,
        "personal_finance_category": {"primary": "GENERAL_MERCHANDISE",
                                      "detailed": "GENERAL_MERCHANDISE_OTHER_GENERAL_MERCHANDISE",
                                      "confidence_level": "LOW"},
        "payment_channel": "other", "transaction_type": "special", "transaction_code": None, "check_number": None,
        "location": {"address": None, "city": None, "region": None, "postal_code": None, "country": None,
                     "lat": None, "lon": None, "store_number": None},
        "pending": False, "pending_transaction_id": None,
      })
  rng.shuffle(transactions)  # Plaid's order is not ours
  return {"accounts": accounts, "transactions": transactions}


def description(t):
  """The bank's own statement text: Sandbox rewrites `name` for stores it knows (NETFLIX.COM comes back as Netflix),
  so `original_description` is used whenever Plaid sends one."""
  original = t.get("original_description")
  return t["name"] if original is None else original


def match(persona, pulled):
  """Map pulled ids back to fixture ids by (account, date, amount, description).

  Returns (account_map, mapping, unmatched reasons, fixture ids nothing matched, ambiguous count).
  Ambiguous rows are identical in every field, so any pairing of them gives the same data.
  """
  fixture_accounts = truth_db.load(persona, "accounts")
  by_mask = {mask(i): a["account_id"] for i, a in enumerate(fixture_accounts)}
  account_map = {a["account_id"]: by_mask.get(a.get("mask")) for a in pulled["accounts"]}

  waiting = defaultdict(list)  # fixture ids still unclaimed, per key
  for t in truth_db.load(persona, "transactions"):
    waiting[(t["account_id"], t["date"], cents(t["amount"]), t["name"])].append(t["transaction_id"])
  keys = list(waiting)
  ambiguous = sum(len(ids) - 1 for ids in waiting.values())

  mapping, reasons = {}, Counter()
  for t in pulled["transactions"]:
    account, day, amount, name = account_map.get(t["account_id"]), t["date"], cents(t["amount"]), description(t)
    if waiting.get((account, day, amount, name)):
      mapping[t["transaction_id"]] = waiting[(account, day, amount, name)].pop(0)
    elif (account, day, amount, name) in waiting:  # the key exists, but every fixture row with it is claimed
      reasons["duplicate row"] += 1
    elif account is None:
      reasons["unknown account"] += 1
    elif (account, day, -amount, name) in waiting:
      reasons["sign flipped"] += 1
    elif any(k[:3] == (account, day, amount) for k in keys):
      reasons["description differs"] += 1
    elif any((k[0], k[1], k[3]) == (account, day, name) for k in keys):
      reasons["amount differs"] += 1
    elif any((k[0], k[2], k[3]) == (account, amount, name) for k in keys):
      reasons["date differs"] += 1
    else:
      reasons["no fixture row"] += 1
  missing = [i for ids in waiting.values() for i in ids]
  return account_map, mapping, reasons, missing, ambiguous


def write_pulled_as_fixtures(persona, pulled, account_map, mapping, folder):
  """Save the pulled data in the fixtures' shape under folder/<persona>/, so truth_db can build from it."""
  key = copy.deepcopy(truth_db.load(persona, "answer_key"))
  transactions = [{f: t.get(f) for f in truth_db.TX_FIELDS}
                  | {"transaction_id": mapping[t["transaction_id"]], "account_id": account_map[t["account_id"]],
                     "pending_transaction_id": mapping.get(t.get("pending_transaction_id")), "name": description(t)}
                  for t in pulled["transactions"] if t["transaction_id"] in mapping]
  accounts = [{f: a.get(f) for f in ("name", "official_name", "mask", "type", "subtype", "balances")}
              | {"account_id": account_map[a["account_id"]]}
              for a in pulled["accounts"] if account_map[a["account_id"]]]
  # Plaid only reports today's balance, so the Jan 1 balance is worked back from it, as the app has to.
  for entry in key["accounts"]:
    a = next((a for a in accounts if a["account_id"] == entry["account_id"]), None)
    if a is None:
      continue
    sign = 1 if a["type"] == "credit" else -1
    posted = sum(cents(t["amount"]) for t in transactions if t["account_id"] == a["account_id"] and not t["pending"])
    entry["starting_balance"] = (cents(a["balances"]["current"]) - sign * posted) / 100
    entry["ending_balance"] = a["balances"]["current"]
  (folder / persona).mkdir(parents=True)
  for name, contents in (("transactions", transactions), ("accounts", accounts), ("answer_key", key)):
    (folder / persona / f"{name}.json").write_text(json.dumps(contents))


def questions(persona, db):
  """Each of the persona's question ids with the `expected` text truth_sql gives on db, plus any errors."""
  with open(fill_answers.QUESTIONS, newline="") as f:
    rows = [r for r in csv.DictReader(f) if r["persona"] == persona]
  errors, _ = fill_answers.fill(rows, db)
  return {r["id"]: r["expected"] for r in rows}, errors


def check(persona, pulled):
  """Match pulled to the fixtures and compare what each gives. Returns (results: check -> passed, details)."""
  account_map, mapping, reasons, missing, ambiguous = match(persona, pulled)
  fixture_ids = {a["account_id"] for a in truth_db.load(persona, "accounts")}
  results = {
    "accounts matched": set(account_map.values()) == fixture_ids and len(account_map) == len(fixture_ids),
    "transactions matched": not reasons and not missing,
  }
  details = {"matched": len(mapping), "unmatched pulled": sum(reasons.values()), "unmatched fixture": len(missing),
             "ambiguous (identical rows)": ambiguous, "pending": sum(bool(t["pending"]) for t in pulled["transactions"]),
             "reasons": dict(reasons), "missing ids": missing[:10],
             "renamed by Plaid": sum(description(t) != t["name"] for t in pulled["transactions"])}

  # Plaid only returns a limited history window (90 days unless more is asked for), so a short pull shows up as
  # whole months missing at the start rather than as scattered unmatched rows.
  def per_month(dates):
    return Counter(d[:7] for d in dates)
  want_months = per_month(t["date"] for t in truth_db.load(persona, "transactions"))
  got_months = per_month(t["date"] for t in pulled["transactions"])
  results["every month present"] = got_months == want_months
  pulled_dates = sorted(t["date"] for t in pulled["transactions"])
  details["dates pulled"] = f"{pulled_dates[0]} to {pulled_dates[-1]}" if pulled_dates else "none"
  details["months short"] = {m: f"{got_months[m]} of {n}" for m, n in sorted(want_months.items()) if got_months[m] != n}

  tx_keys = set().union(*(t.keys() for t in pulled["transactions"])) if pulled["transactions"] else set()
  details["fields Plaid added"] = sorted(tx_keys - TX_FIELDS)
  details["fields Plaid dropped"] = sorted(TX_FIELDS - tx_keys)

  with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    write_pulled_as_fixtures(persona, pulled, account_map, mapping, tmp / "pulled")
    truth_db.build(tmp / "fixture.db", [persona])
    truth_db.build(tmp / "pulled.db", [persona], data=tmp / "pulled")
    fixture, plaid = sqlite3.connect(tmp / "fixture.db"), sqlite3.connect(tmp / "pulled.db")
    def same(sql):
      return fixture.execute(sql).fetchall() == plaid.execute(sql).fetchall()
    # Every column but pending_transaction_id: some fixture rows point at a pending record the data no longer
    # holds, and a custom user can't carry that link. The app only uses it to drop pending copies, so it is counted.
    results["transactions identical"] = same(
      "SELECT persona, transaction_id, account_id, date, name, amount, iso_currency_code, pending, true_merchant,"
      " kind, recurring, linked_transaction_id, category, income_type FROM tx ORDER BY transaction_id")
    details["pending links dropped"] = sum(
      x != y for x, y in zip(*(db.execute("SELECT pending_transaction_id FROM tx ORDER BY transaction_id").fetchall()
                               for db in (fixture, plaid))))
    results["totals"] = same("SELECT kind, SUM(ROUND(amount * 100)) FROM tx WHERE NOT pending GROUP BY kind ORDER BY kind")
    results["balances every day"] = same("SELECT account_id, date, balance FROM daily_balance ORDER BY account_id, date")
    results["current balances"] = same("SELECT account_id, current FROM accounts ORDER BY account_id")
    (want, want_errors), (got, got_errors) = questions(persona, fixture), questions(persona, plaid)
    fixture.close()
    plaid.close()
  results["questions"] = want == got and not want_errors and not got_errors
  details["questions compared"] = len(want)
  details["questions differing"] = {q: (want[q], got.get(q)) for q in want if want[q] != got.get(q)}
  details["question errors"] = got_errors
  return results, details


def report(persona, results, details):
  """Print the results; a held-out persona prints counts and pass/fail only. Returns True when every check passed."""
  passed = all(results.values())
  print(f"{persona}: {'PASS' if passed else 'FAIL'}")
  for name, ok in results.items():
    print(f"  {name}: {'pass' if ok else 'FAIL'}")
  counts = ("matched", "unmatched pulled", "unmatched fixture", "ambiguous (identical rows)", "pending",
            "pending links dropped", "renamed by Plaid", "questions compared")
  print("  " + ", ".join(f"{k} {details[k]}" for k in counts))
  if persona not in HELD_OUT:
    for k in ("dates pulled", "months short", "reasons", "missing ids", "fields Plaid added", "fields Plaid dropped", "questions differing", "question errors"):
      if details[k]:
        print(f"  {k}: {details[k]}")
  return passed


def save(persona, raw, results, details):
  """Keep the reply exactly as Plaid sent it, plus what the check found, as the record that the run happened."""
  folder = truth_db.DATA / persona
  (folder / "plaid_pulled.json").write_bytes(raw)
  counts = ("matched", "unmatched pulled", "unmatched fixture", "pending", "pending links dropped", "renamed by Plaid",
            "questions compared")
  record = {
    # When the pull was checked: provenance only, never used for data logic.
    "checked_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    "source": "Plaid Sandbox custom user (institution ins_109508) via /transactions/sync and /accounts/get",
    "config_sha256": hashlib.sha256((folder / "plaid_user.json").read_bytes()).hexdigest(),
    "reply_sha256": hashlib.sha256(raw).hexdigest(),
    "passed": all(results.values()),
    "results": results,
    "counts": {k: details[k] for k in counts},
  }
  (folder / "plaid_check.json").write_text(json.dumps(record, indent=2) + "\n")


def main(args):
  if args == ["configs"]:
    return write_configs()
  if args == ["dry-run"]:
    passed = [report(p, *check(p, fake_reply(config(p)))) for p in DEV_AND_VALIDATION]
    return 0 if all(passed) else 1
  if len(args) == 3 and args[0] == "check" and args[1] in PERSONAS:
    raw = Path(args[2]).read_bytes()
    results, details = check(args[1], json.loads(raw))
    save(args[1], raw, results, details)
    return 0 if report(args[1], results, details) else 1
  print(__doc__, file=sys.stderr)
  return 2


if __name__ == "__main__":
  sys.exit(main(sys.argv[1:]))
