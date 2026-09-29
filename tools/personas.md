# Fictional Spending Personas

All people, statement descriptions, and amounts below are fictional test data for January–June 2026. Charges repeat monthly unless noted; dates indicate the day of the month. Income amounts are net deposits. Internal transfers and credit card payments should be matched across accounts, not counted as new income or spending.

Bills come out of checking; everyday spending goes on a credit card, unless noted.

Card payments start in February, since the cards begin at $0.

## Maya — College Student with a Part-Time Job

Maya is a college student who works part time at a coffee shop and shares an apartment with two roommates. Most of her paycheck goes toward rent, groceries, utilities, and textbooks. She buys store-brand food, uses student discounts, and takes the bus to keep costs down. She occasionally spends money on takeout or outings with friends, but unexpected expenses often leave her with little to save.

Income: $520 every other Friday starting January 2, from "BEAN STREET COFFEE PAYROLL".

Accounts: checking, one credit card.

Starting balances (Jan 1): checking [$900], credit card [$0]

Example charges:

- Rent (shared apartment), $650.00, the 1st
- Netflix (statement description: "NETFLIX.COM"), $15.49 on the 3rd in January–March; $17.99 on the 3rd in April–June
- Bus pass, $40.00, the 5th
- Phone plan, $35.00, the 10th
- Utilities (shared), $60.00, the 15th
- Internet (shared), $25.00, the 20th

Money moving between accounts:

- On the 20th, pays the credit card in full from checking. Each payment equals the total charged to that card in the previous calendar month. Checking shows "PAYMENT CREDIT CARD"; the credit card shows the corresponding amount as "PAYMENT RECEIVED THANK YOU" on the same date.

Data generation check: After adding everyday spending, check that Maya's checking balance stays nonnegative, especially around the card payment on the 20th. If it goes negative, lower her everyday spending or treat the overdraft as an intentional test case and note it in the answer key.

## Daniel — Salaried Worker with a Mortgage

Daniel works full time as an office manager and receives a steady monthly salary. He budgets for his mortgage, car payment, insurance, and household bills before setting aside money for savings. He usually cooks at home but enjoys a restaurant meal on weekends and pays for a few streaming subscriptions. He plans larger purchases, such as furniture or home repairs, several months ahead.

Income: $5,200 on the last business day of each month, from "NORTHPOINT SERVICES PAYROLL".

Accounts: checking, savings, two credit cards (Card A and Card B).

Starting balances (Jan 1): checking [$3,000], savings [$8,000], Card A [$0], Card B [$0]

Card A: groceries, household, and online shopping. Card B: restaurants and gas.

Example charges:

- Mortgage, $1,850.00, the 1st
- Netflix (statement description: "NETFLIX.COM"), $15.49 on the 3rd in January–March; $17.99 on the 3rd in April–June
- Car payment, $325.00, the 7th
- Auto insurance, $125.00, the 12th
- Electricity, $110.00, the 16th
- Internet, $70.00, the 20th
- Amazon Prime (statement description: "AMAZON PRIME MEMBERSHIP"), $139.00, March 14 only; renews annually, charged to Card A

Money moving between accounts:

- On the 25th, pays both credit cards in full from checking. Each payment equals the total charged to that card in the previous calendar month. Checking descriptions: "PAYMENT CARD A" and "PAYMENT CARD B"; each card shows the corresponding amount as "PAYMENT RECEIVED THANK YOU" on the same date.
- On the 2nd, moves $500 from checking to savings. Checking shows "ONLINE TRANSFER TO SAVINGS"; savings shows "ONLINE TRANSFER FROM CHECKING", with the same amount and date.

## Jordan — Gig Worker with Uneven Income

Jordan earns money through delivery apps and freelance photography, so their income changes from week to week. They prioritize rent, groceries, gas, and phone service, while setting aside part of each payment for taxes and slower months. During busy periods, they may buy photography equipment or eat out more often. When work slows down, they cut optional spending and rely on their savings to cover essentials.

Income: $250–$450 every Tuesday from "DELIVERY PLATFORM PAYOUT"; $400–$1,200 per photography job, 1–3 irregular payments per month, from "STRIPE TRANSFER JORDAN PHOTO".

Accounts: checking, tax savings, one credit card.

Starting balances (Jan 1): checking [$1,200], tax savings [$1,500], credit card [$0]

Example charges:

- Rent, $950.00, the 1st
- Photo editing software, $19.99, the 4th
- Phone plan, $65.00, the 8th
- Auto insurance, $145.00, the 12th
- Equipment installment, $85.00, the 18th
- Cloud storage, $9.99, the 22nd

Money moving between accounts:

- On the 15th, pays the credit card in full from checking. Each payment equals the total charged to that card in the previous calendar month. Checking shows "PAYMENT CREDIT CARD"; the credit card shows the corresponding amount as "PAYMENT RECEIVED THANK YOU" on the same date.
- On the day each photography payment arrives, moves 25% of that deposit from checking to tax savings, rounded to the nearest cent. For example, an $800 "STRIPE TRANSFER JORDAN PHOTO" deposit triggers a $200 transfer. Checking shows "ONLINE TRANSFER TO TAX SAVINGS"; tax savings shows "ONLINE TRANSFER FROM CHECKING", with the same amount and date. Delivery payouts do not trigger this rule.

## Elena — Parent Paying Tuition

Elena is a working parent who helps pay her daughter's college tuition while managing everyday household expenses. She sets aside money each month for tuition, housing, groceries, and transportation, leaving a smaller budget for entertainment. She compares prices, shops sales, and postpones replacing household items that still work. Family trips and other large purchases depend on how much remains after education costs and emergency savings.

Income: $2,300 every other Friday starting January 9, from "LAKESIDE SCHOOL DIST PAYROLL".

Accounts: checking, savings, one credit card.

Starting balances (Jan 1): checking [$2,500], savings [$6,000], credit card [$0]

Example charges:

- Mortgage, $1,450.00, the 1st
- College tuition payment plan, $800.00, the 5th
- Family phone plan, $110.00, the 9th
- Car payment, $275.00, the 12th
- Electricity, $135.00, the 17th
- Internet, $65.00, the 21st

Money moving between accounts:

- On the 25th, pays the credit card in full from checking. Each payment equals the total charged to that card in the previous calendar month. Checking shows "PAYMENT CREDIT CARD"; the credit card shows the corresponding amount as "PAYMENT RECEIVED THANK YOU" on the same date.
- On the 16th, moves $300 from checking to savings. Checking shows "ONLINE TRANSFER TO SAVINGS"; savings shows "ONLINE TRANSFER FROM CHECKING", with the same amount and date.

## Generated data conventions

Run `python3 fake_gen.py` from `tools/`. The script writes each person's
`transactions.json`, `answer_key.json`, and `accounts.json` under `tools/data/`.
The seed is 42, and IDs restart for each person. Maya's bills alone produce 36
records; adding only her paycheck produces 49. Everyday spending, transfers,
card payments, and refunds increase the final counts.

Everyday purchases vary within weekly budgets. Maya buys inexpensive groceries,
coffee, occasional takeout, and books; she uses the bus and has no gas purchases.
Daniel uses Card A for groceries, household goods, and online orders, and Card B
for restaurants, coffee, and gas. Jordan buys groceries, gas, coffee, occasional
meals, and camera supplies. Elena buys groceries, gas, occasional coffee and meals,
and discounted household goods. These purchases have `recurring: "none"` in the
answer key: a shopping habit is not a recurring bill.

Common stores cycle through three statement spellings; `true_merchant` holds the
clean name supplied separately in the persona data (for example, `Netflix`,
`T-Mobile`, `Comcast`, and `Bean Street Coffee`). Bills and income use the same
rule as everyday purchases; refunds retain the original purchase's clean name.
Transfers and card payments have `true_merchant: null` because they move money
between the person's own accounts. Missing merchant truth for spending or income
raises an error instead of falling back to the raw statement text.
`transactions.json` is a June 30 snapshot, not an event history.
Once a purchase posts, its pending copy is removed. The posted record can retain
`pending_transaction_id`, referring to an old ID that is no longer in the file.
All purchases in this fixture have posted by June 30. This follows
[Plaid's pending-to-posted behavior](https://plaid.com/docs/transactions/transactions-data/).
A few full refunds are negative spending, with `linked_transaction_id` in the
answer key pointing to the original purchase. Transfer and card payment entries
link both ways across their accounts; they are neither income nor spending.

Card payments cover the previous calendar month's posted charges less refunds.
The balance immediately after payment can include the current month's purchases;
it need not be zero. June purchases remain owed at the end of this dataset because
their payments occur in July. Depository balances equal starting balance minus
posted amounts; credit balances equal starting balance plus posted amounts and
represent money owed. The summary checks checking balances after every posted
transaction, including intermediate transactions on the same date.


`accounts.json` is an array of Plaid-shaped account objects (the `accounts` array
from an API response, without its response envelope). `balances.current` is the
June 30 balance, following [Plaid's account schema](https://plaid.com/docs/api/accounts/).
Unknown `available`, `limit`, `mask`, and `official_name` values are null.
Starting balances are generator inputs only and never appear in this app-facing file.

`answer_key.json` is now an object, with `as_of`, `accounts`, `totals`, and
`transactions` fields. Read transaction labels from `answer_key["transactions"]`
instead of treating the root as a list. The labels match the snapshot's transaction
IDs one for one. `accounts` contains each account's `starting_balance` on January 1
and `ending_balance` on June 30, keyed by `account_id`. `totals.income` is positive
net income; `totals.spending` is posted spending minus refunds. Both exclude
transfers and card payments, and exclude pending records. These are the expected
scorecard totals for the complete January–June period.
