# a program for generating fake data formatted to how PLAID will be returning data
# this will be used for testing and benchmarking models with grounded truths

#imports
from datetime import date
from datetime import timedelta
import calendar
import json
from pathlib import Path
import random

rng = random.Random(42)
global_counter = 0

PERSONAS = {
  "maya": {
    "accounts": [
      {"account_id": "maya-checking", "name": "Checking", "type": "depository", "subtype": "checking", "starting_balance": 900.00},
      {"account_id": "maya-card", "name": "Credit Card", "type": "credit", "subtype": "credit card", "starting_balance": 0.00}
    ],
    "bills": [
      {"name": "OAKWOOD APARTMENTS RENT", "true_merchant": "Oakwood Apartments", "amount": 650.00, "day": 1},
      {"name": "NETFLIX.COM", "true_merchant": "Netflix", "amount": 15.49, "day": 3, "new_amount": 17.99, "from_month": 4},
      {"name": "CITY TRANSIT PASS", "true_merchant": "City Transit", "amount": 40.00, "day": 5},
      {"name": "TMOBILE*AUTOPAY", "true_merchant": "T-Mobile", "amount": 35.00, "day": 10},
      {"name": "CITY UTILITIES PMT", "true_merchant": "City Utilities", "amount": 60.00, "day": 15},
      {"name": "COMCAST XFINITY", "true_merchant": "Comcast", "amount": 25.00, "day": 20}
    ],
    "paycheck": {"type": "biweekly", "name": "BEAN STREET COFFEE PAYROLL", "true_merchant": "Bean Street Coffee", "amount": 520.00, "first_day": date(2026, 1, 2), "every_days": 14},
    "payment_day": 20,
    "spending": [
      {"name": "VALUE MART", "true_merchant": "Value Mart", "low": 18.00, "high": 28.00, "every_weeks": 1},
      {"name": "BEAN STREET COFFEE", "true_merchant": "Bean Street Coffee", "low": 2.00, "high": 4.00, "every_weeks": 1},
      {"name": "CORNER CAFE", "true_merchant": "Corner Cafe", "low": 7.00, "high": 12.00, "every_weeks": 2},
      {"name": "CAMPUS BOOKSTORE", "true_merchant": "Campus Bookstore", "low": 12.00, "high": 22.00, "every_weeks": 8}
    ]
  },
  "daniel": {
    "accounts": [
      {"account_id": "daniel-checking", "name": "Checking", "type": "depository", "subtype": "checking", "starting_balance": 3000.00},
      {"account_id": "daniel-savings", "name": "Savings", "type": "depository", "subtype": "savings", "starting_balance": 8000.00},
      {"account_id": "daniel-card-a", "name": "Card A", "type": "credit", "subtype": "credit card", "starting_balance": 0.00},
      {"account_id": "daniel-card-b", "name": "Card B", "type": "credit", "subtype": "credit card", "starting_balance": 0.00}
    ],
    "bills": [
      {"name": "HOME MORTGAGE", "true_merchant": "Home Mortgage", "amount": 1850.00, "day": 1},
      {"name": "NETFLIX.COM", "true_merchant": "Netflix", "amount": 15.49, "day": 3, "new_amount": 17.99, "from_month": 4},
      {"name": "AUTO LOAN PAYMENT", "true_merchant": "Auto Loan", "amount": 325.00, "day": 7},
      {"name": "AUTO INSURANCE", "true_merchant": "Auto Insurance", "amount": 125.00, "day": 12},
      {"name": "CITY ELECTRIC", "true_merchant": "City Electric", "amount": 110.00, "day": 16},
      {"name": "COMCAST XFINITY", "true_merchant": "Comcast", "amount": 70.00, "day": 20},
      {"name": "AMAZON PRIME MEMBERSHIP", "true_merchant": "Amazon", "amount": 139.00, "day": 14, "months": [3], "account": "card-a", "recurring": "yearly"}
    ],
    "paycheck": {"type": "last_business_day", "name": "NORTHPOINT SERVICES PAYROLL", "true_merchant": "Northpoint Services", "amount": 5200.00},
    "transfer": {"amount": 500.00, "day": 2, "account": "savings"},
    "payment_day": 25,
    "spending": [
      {"name": "VALUE MART", "true_merchant": "Value Mart", "low": 65.00, "high": 95.00, "every_weeks": 1, "account": "card-a"},
      {"name": "HOME GOODS", "true_merchant": "Home Goods", "low": 18.00, "high": 45.00, "every_weeks": 3, "account": "card-a"},
      {"name": "AMAZON", "true_merchant": "Amazon", "low": 15.00, "high": 60.00, "every_weeks": 4, "account": "card-a"},
      {"name": "CORNER CAFE", "true_merchant": "Corner Cafe", "low": 25.00, "high": 55.00, "every_weeks": 1, "account": "card-b"},
      {"name": "SHELL", "true_merchant": "Shell", "low": 30.00, "high": 50.00, "every_weeks": 1, "account": "card-b"},
      {"name": "BEAN STREET COFFEE", "true_merchant": "Bean Street Coffee", "low": 3.00, "high": 6.00, "every_weeks": 2, "account": "card-b"}
    ]
  },
  "jordan": {
    "accounts": [
      {"account_id": "jordan-checking", "name": "Checking", "type": "depository", "subtype": "checking", "starting_balance": 1200.00},
      {"account_id": "jordan-tax-savings", "name": "Tax Savings", "type": "depository", "subtype": "savings", "starting_balance": 1500.00},
      {"account_id": "jordan-card", "name": "Credit Card", "type": "credit", "subtype": "credit card", "starting_balance": 0.00}
    ],
    "bills": [
      {"name": "RIVERSIDE APARTMENTS RENT", "true_merchant": "Riverside Apartments", "amount": 950.00, "day": 1},
      {"name": "PHOTO EDITING SOFTWARE", "true_merchant": "Photo Editing Software", "amount": 19.99, "day": 4},
      {"name": "TMOBILE*AUTOPAY", "true_merchant": "T-Mobile", "amount": 65.00, "day": 8},
      {"name": "AUTO INSURANCE", "true_merchant": "Auto Insurance", "amount": 145.00, "day": 12},
      {"name": "CAMERA EQUIPMENT INSTALLMENT", "true_merchant": "Camera Equipment", "amount": 85.00, "day": 18},
      {"name": "CLOUD STORAGE", "true_merchant": "Cloud Storage", "amount": 9.99, "day": 22}
    ],
    "paycheck": {"type": "gig", "name": "DELIVERY PLATFORM PAYOUT", "true_merchant": "Delivery Platform", "first_day": date(2026, 1, 6), "every_days": 7, "low": 250.00, "high": 450.00,
      "photography": {"name": "STRIPE TRANSFER JORDAN PHOTO", "true_merchant": "Jordan Photo", "low": 400.00, "high": 1200.00, "min_jobs": 1, "max_jobs": 3, "tax_rate": 0.25}},
    "payment_day": 15,
    "spending": [
      {"name": "VALUE MART", "true_merchant": "Value Mart", "low": 35.00, "high": 55.00, "every_weeks": 1},
      {"name": "SHELL", "true_merchant": "Shell", "low": 25.00, "high": 45.00, "every_weeks": 1},
      {"name": "CORNER CAFE", "true_merchant": "Corner Cafe", "low": 10.00, "high": 22.00, "every_weeks": 2},
      {"name": "BEAN STREET COFFEE", "true_merchant": "Bean Street Coffee", "low": 3.00, "high": 6.00, "every_weeks": 1},
      {"name": "CAMERA SHOP", "true_merchant": "Camera Shop", "low": 30.00, "high": 80.00, "every_weeks": 8}
    ]
  },
  "elena": {
    "accounts": [
      {"account_id": "elena-checking", "name": "Checking", "type": "depository", "subtype": "checking", "starting_balance": 2500.00},
      {"account_id": "elena-savings", "name": "Savings", "type": "depository", "subtype": "savings", "starting_balance": 6000.00},
      {"account_id": "elena-card", "name": "Credit Card", "type": "credit", "subtype": "credit card", "starting_balance": 0.00}
    ],
    "bills": [
      {"name": "HOME MORTGAGE", "true_merchant": "Home Mortgage", "amount": 1450.00, "day": 1},
      {"name": "COLLEGE TUITION PAYMENT PLAN", "true_merchant": "College Tuition", "amount": 800.00, "day": 5},
      {"name": "FAMILY PHONE PLAN", "true_merchant": "Family Phone", "amount": 110.00, "day": 9},
      {"name": "AUTO LOAN PAYMENT", "true_merchant": "Auto Loan", "amount": 275.00, "day": 12},
      {"name": "CITY ELECTRIC", "true_merchant": "City Electric", "amount": 135.00, "day": 17},
      {"name": "COMCAST XFINITY", "true_merchant": "Comcast", "amount": 65.00, "day": 21}
    ],
    "paycheck": {"type": "biweekly", "name": "LAKESIDE SCHOOL DIST PAYROLL", "true_merchant": "Lakeside School District", "amount": 2300.00, "first_day": date(2026, 1, 9), "every_days": 14},
    "transfer": {"amount": 300.00, "day": 16, "account": "savings"},
    "payment_day": 25,
    "spending": [
      {"name": "VALUE MART", "true_merchant": "Value Mart", "low": 75.00, "high": 110.00, "every_weeks": 1},
      {"name": "SHELL", "true_merchant": "Shell", "low": 25.00, "high": 45.00, "every_weeks": 1},
      {"name": "CORNER CAFE", "true_merchant": "Corner Cafe", "low": 20.00, "high": 40.00, "every_weeks": 3},
      {"name": "BEAN STREET COFFEE", "true_merchant": "Bean Street Coffee", "low": 3.00, "high": 5.00, "every_weeks": 2},
      {"name": "HOME GOODS", "true_merchant": "Home Goods", "low": 12.00, "high": 30.00, "every_weeks": 4}
    ]
  }
}

SPELLINGS = {
  "VALUE MART": ["VALUE MART", "VALUE-MART #104", "VALUEMART GROCERY"],
  "BEAN STREET COFFEE": ["BEAN STREET COFFEE", "SQ *BEAN ST COFFEE", "BEANSTREET CAFE"],
  "CORNER CAFE": ["CORNER CAFE", "TST* CORNER CAFE", "CORNER CAFE RESTAURANT"],
  "SHELL": ["SHELL", "SHELL OIL #021", "SHELL SERVICE STATION"],
  "HOME GOODS": ["HOME GOODS", "HOMEGOODS #081", "HOME GOODS STORE"],
  "AMAZON": ["AMAZON", "AMZN Mktp US", "AMAZON.COM*ORDER"],
  "CAMPUS BOOKSTORE": ["CAMPUS BOOKSTORE", "CAMPUS BOOKS", "UNIVERSITY BOOK STORE"],
  "CAMERA SHOP": ["CAMERA SHOP", "CAMERA SHOP ONLINE", "THE CAMERA STORE"]
}


# creates a dictionary for each transaction a person holds
def make_transaction(person_name, account_id, day, vendor, amount):
  global global_counter
  global_counter += 1
  ret = {
    "transaction_id": f"{person_name}-{global_counter:04d}", #unique ids
    "account_id": account_id, #unique ID
    "date": day.isoformat(), # date
    "name": vendor,
    "amount": amount, #money leaving -> positive values (means going out) [negative ->(going in)]
    "iso_currency_code": "USD",
    "pending": False,
    "pending_transaction_id": None # used later for pending, posted charges
  }
  return ret


# saves the grounded truth separately from the bank data
def add_transaction(data, answer_key, person_name, account, day, vendor, amount, kind, recurring, true_merchant=None):
  if kind in ("transfer", "card_payment"):
    true_merchant = None
  elif true_merchant is None:
    raise ValueError(f"missing true merchant for {vendor}")
  res = make_transaction(person_name, f"{person_name}-{account}", day, vendor, amount)
  data.append(res)
  answer_key.append({
    "transaction_id": res["transaction_id"],
    "true_merchant": true_merchant,
    "kind": kind,
    "recurring": recurring,
    "linked_transaction_id": None
  })
  return res


# money moving between accounts has two sides, both linked in the answer key
def transfer_pair(data, answer_key, person_name, day, amount, from_account, to_account, from_name, to_name, kind="transfer", recurring="monthly"):
  outgoing = add_transaction(data, answer_key, person_name, from_account, day, from_name, amount, kind, recurring)
  outgoing_key = answer_key[-1]
  incoming = add_transaction(data, answer_key, person_name, to_account, day, to_name, -amount, kind, recurring)
  outgoing_key["linked_transaction_id"] = incoming["transaction_id"]
  answer_key[-1]["linked_transaction_id"] = outgoing["transaction_id"]


# function to extract data per person passed into this function
# passing an answer_key list collects truth while generate still returns data
def generate(person_name, person, answer_key=None):
  if answer_key is None:
    answer_key = []
  data = []
  end_day = date(2026, 6, 30)

  #collect for bills
  for month in range (1,7):
    for bill in person["bills"]:
      if month not in bill.get("months", range(1, 7)):
        continue
      amount = bill["amount"]
      if "new_amount" in bill and month >= bill["from_month"]:
        amount = bill["new_amount"]
      add_transaction(data, answer_key, person_name, bill.get("account", "checking"), date(2026, month, bill["day"]), bill["name"], amount, "spending", bill.get("recurring", "monthly"), bill["true_merchant"])

  #collect for paychecks
  if "paycheck" in person:
    paycheck = person["paycheck"]
    if paycheck["type"] == "last_business_day":
      for month in range (1,7):
        day = date(2026, month, calendar.monthrange(2026, month)[1])
        while day.weekday() >= 5:
          day = day - timedelta(days=1)
        add_transaction(data, answer_key, person_name, "checking", day, paycheck["name"], -paycheck["amount"], "income", "monthly", paycheck["true_merchant"])
    elif paycheck["type"] in ("biweekly", "gig"):
      day = paycheck["first_day"]
      while day <= end_day:
        if paycheck["type"] == "gig":
          amount = round(rng.uniform(paycheck["low"], paycheck["high"]), 2)
          recurring = "weekly"
        else:
          amount = paycheck["amount"]
          recurring = "biweekly"
        add_transaction(data, answer_key, person_name, "checking", day, paycheck["name"], -amount, "income", recurring, paycheck["true_merchant"])
        day = day + timedelta(days=paycheck["every_days"])
    else:
      raise ValueError("unknown paycheck type")

    if "photography" in paycheck:
      photography = paycheck["photography"]
      for month in range (1,7):
        job_count = rng.randint(photography["min_jobs"], photography["max_jobs"])
        days = rng.sample(range(1, calendar.monthrange(2026, month)[1] + 1), job_count)
        for day_num in sorted(days):
          day = date(2026, month, day_num)
          amount = round(rng.uniform(photography["low"], photography["high"]), 2)
          add_transaction(data, answer_key, person_name, "checking", day, photography["name"], -amount, "income", "none", photography["true_merchant"])
          tax_amount = round(amount * photography["tax_rate"], 2)
          transfer_pair(data, answer_key, person_name, day, tax_amount, "checking", "tax-savings", "ONLINE TRANSFER TO TAX SAVINGS", "ONLINE TRANSFER FROM CHECKING", recurring="none")

  #collect for scheduled savings
  if "transfer" in person:
    transfer = person["transfer"]
    for month in range (1,7):
      transfer_pair(data, answer_key, person_name, date(2026, month, transfer["day"]), transfer["amount"], "checking", transfer["account"], "ONLINE TRANSFER TO SAVINGS", "ONLINE TRANSFER FROM CHECKING")

  #collect for everyday spending, with different days and amounts each week
  week = date(2026, 1, 1)
  week_num = 0
  spelling_counts = {}
  while week <= end_day:
    for habit in person.get("spending", []):
      if week_num % habit["every_weeks"] != 0:
        continue
      day = week + timedelta(days=rng.randint(0, min(6, (end_day - week).days)))
      amount = round(rng.uniform(habit["low"], habit["high"]), 2)
      vendor = habit["name"]
      spellings = SPELLINGS.get(vendor, [vendor])
      count = spelling_counts.get(vendor, 0)
      spelling_counts[vendor] = count + 1
      add_transaction(data, answer_key, person_name, habit.get("account", "card"), day, spellings[count % len(spellings)], amount, "spending", "none", habit["true_merchant"])
    week = week + timedelta(days=7)
    week_num += 1

  # a small purchase returned in February and April, before the month ends
  for month in (2, 4):
    purchases = [res for res in data if res["date"][5:7] == f"{month:02d}" and res["date"][8:10] <= "20" and res["amount"] > 0 and "-card" in res["account_id"]]
    if not purchases:
      continue
    original = rng.choice(purchases)
    original_key = next(entry for entry in answer_key if entry["transaction_id"] == original["transaction_id"])
    day = date.fromisoformat(original["date"]) + timedelta(days=3)
    account = original["account_id"][len(person_name) + 1:]
    add_transaction(data, answer_key, person_name, account, day, f"REFUND {original['name']}", -original["amount"], "spending", "none", original_key["true_merchant"])
    answer_key[-1]["linked_transaction_id"] = original["transaction_id"]

  # pay the previous month's net posted charges, including any refunds
  if "payment_day" in person:
    spending_ids = {entry["transaction_id"] for entry in answer_key if entry["kind"] == "spending"}
    for month in range (2,7):
      for account in person["accounts"]:
        if account["type"] != "credit":
          continue
        amount = round(sum(res["amount"] for res in data if res["transaction_id"] in spending_ids and res["account_id"] == account["account_id"] and res["date"][5:7] == f"{month - 1:02d}"), 2)
        if amount <= 0:
          continue
        account_name = account["account_id"][len(person_name) + 1:]
        transfer_pair(data, answer_key, person_name, date(2026, month, person["payment_day"]), amount, "checking", account_name, f"PAYMENT {account['name'].upper()}", "PAYMENT RECEIVED THANK YOU", kind="card_payment")

  # simulate pending IDs, then remove their old records from the final snapshot
  keys = {entry["transaction_id"]: entry for entry in answer_key}
  for res in list(data):
    entry = keys[res["transaction_id"]]
    if entry["kind"] != "spending" or res["amount"] <= 0 or "-card" not in res["account_id"]:
      continue
    posted_day = date.fromisoformat(res["date"])
    if posted_day.day <= 3 or rng.random() >= 0.12:
      continue
    day = posted_day - timedelta(days=rng.randint(1, 3))
    account = res["account_id"][len(person_name) + 1:]
    pending = add_transaction(data, answer_key, person_name, account, day, res["name"], res["amount"], "spending", entry["recurring"], entry["true_merchant"])
    pending["pending"] = True
    res["pending_transaction_id"] = pending["transaction_id"]

  data = [res for res in data if not res["pending"]]
  posted_ids = {res["transaction_id"] for res in data}
  answer_key[:] = [entry for entry in answer_key if entry["transaction_id"] in posted_ids]
  data.sort(key=lambda res: (res["date"], res["transaction_id"]))
  order = {res["transaction_id"]: i for i, res in enumerate(data)}
  answer_key.sort(key=lambda entry: order[entry["transaction_id"]])
  return data


# depository balances fall when money leaves, credit balances show money owed
# use cents so rounding does not add up over the six months
def summarize(person_name, person, data):
  balances = {account["account_id"]: round(account["starting_balance"] * 100) for account in person["accounts"]}
  types = {account["account_id"]: account["type"] for account in person["accounts"]}
  minimum = balances[f"{person_name}-checking"]
  for res in data:
    if res["pending"]:
      continue
    account_id = res["account_id"]
    amount = round(res["amount"] * 100)
    if types[account_id] == "credit":
      balances[account_id] += amount
    else:
      balances[account_id] -= amount
    minimum = min(minimum, balances[f"{person_name}-checking"])
  if minimum < 0:
    raise ValueError(f"{person_name}'s checking goes below $0: ${minimum / 100:.2f}")
  print(f"{person_name}: {len(data)} transactions")
  for account in person["accounts"]:
    print(f"  {account['name']}: ${balances[account['account_id']] / 100:.2f}")
  print(f"  lowest checking balance: ${minimum / 100:.2f}")
  return {account_id: amount / 100 for account_id, amount in balances.items()}


# bank-facing accounts use the balance at the end of the snapshot
def make_accounts(person, balances):
  accounts = []
  for account in person["accounts"]:
    accounts.append({
      "account_id": account["account_id"],
      "name": account["name"],
      "official_name": None,
      "mask": None,
      "type": account["type"],
      "subtype": account["subtype"],
      "balances": {
        "current": balances[account["account_id"]],
        "available": None,
        "limit": None,
        "iso_currency_code": "USD",
        "unofficial_currency_code": None
      }
    })
  return accounts


# scorecard totals count posted spending net of refunds, excluding money transfers
def make_answer_key(person, data, answer_key, balances):
  keys = {entry["transaction_id"]: entry for entry in answer_key}
  totals = {"income": 0, "spending": 0}
  for res in data:
    if res["pending"]:
      continue
    kind = keys[res["transaction_id"]]["kind"]
    if kind == "income":
      totals["income"] -= round(res["amount"] * 100)
    elif kind == "spending":
      totals["spending"] += round(res["amount"] * 100)
  return {
    "as_of": "2026-06-30",
    "accounts": [
      {"account_id": account["account_id"], "starting_balance": account["starting_balance"], "ending_balance": balances[account["account_id"]]}
      for account in person["accounts"]
    ],
    "totals": {kind: amount / 100 for kind, amount in totals.items()},
    "transactions": answer_key
  }


if __name__ == "__main__":
  rng.seed(42)
  for person_name, person in PERSONAS.items():
    global_counter = 0
    answer_key = []
    data = generate(person_name, person, answer_key)
    balances = summarize(person_name, person, data)
    accounts = make_accounts(person, balances)
    answer_key = make_answer_key(person, data, answer_key, balances)
    folder = Path(__file__).resolve().parent / "data" / person_name
    folder.mkdir(parents=True, exist_ok=True)
    for name, contents in [("transactions", data), ("answer_key", answer_key), ("accounts", accounts)]:
      with open(folder / f"{name}.json", "w") as f:
        json.dump(contents, f, indent=2)
        f.write("\n")
