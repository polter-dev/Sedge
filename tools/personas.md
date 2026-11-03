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

## Validation personas

Nia and Otis are the validation split: models and settings are chosen on them so the held-out test set (Jordan and Elena) is scored once at the end. They are not in the app's persona list, and the organizer is not tuned on them: a mistake they expose is logged, not fixed. † means an authored amount, approximate and unverified; a linked source supports its scale, not the fictional person's exact finances.

## Nia — Bookkeeper with a Shared Household Account

Nia works full time as a bookkeeper and lives with her partner, Arden. They pay rent, household bills and groceries from a joint checking account. Arden adds his share from his own account, which isn't connected. Nia also has personal savings and a personal credit card. She buys clothes, pays for pharmacy and health items, has one streaming subscription, eats out and goes to the movies, and pays a friend back for outings now and then while building a moving buffer.

Income: $1,550† on the 15th and the last business day of each month, from "KESTREL LEDGER PAYROLL". A weekend payday moves to the Friday before: Jan 15 and 30, Feb 13 and 27, Mar 13 and 31, Apr 15 and 30, May 15 and 29, Jun 15 and 30. None of these is a [federal holiday](https://www.opm.gov/policy-data-oversight/pay-leave/federal-holidays/#url=2026). $37,200 a year take-home is about 73% of the [BLS bookkeeper median of $50,670 (May 2025)](https://www.bls.gov/ooh/office-and-administrative-support/bookkeeping-accounting-and-auditing-clerks.htm).

Arden contributes $900† on the 27th, as "SPLITPAY TRANSFER FROM ARDEN VALE". It is income (`kind: "income"`), but the answer key labels it `income_type: "household_contribution"` and her pay `income_type: "wages"`, so "total income" needs clarifying: $18,600 of wages or $24,000 with Arden's share.

Accounts: joint checking ("Joint Checking"), personal savings, one credit card. The answer key records the owners: checking shared, savings and card hers.

Starting balances (Jan 1): checking [$2,000†], savings [$3,000†], credit card [$0†]

Example charges:

- Rent ("ASTER COURT RENT"), $1,300†, the 1st. With electricity and water it is $1,484, close to the [Census 2024 median gross rent of $1,487, utilities included](https://www.census.gov/newsroom/press-releases/2025/acs-1-year-estimates.html).
- Electricity ("BRAMBLE ELECTRIC", budget billing), $144, the 16th: the [EIA 2024 national average](https://www.eia.gov/todayinenergy/detail.php?id=65244).
- Two phone lines ("CIRRUS MOBILE"), $50, the 10th: two lines at [Visible's regular $25](https://www.visible.com/plans) (taxes and fees included; $19 with a promotion).
- Internet ("DOVETAIL INTERNET"), $50†, the 20th
- Water ("ESTUARY WATER"), $40†, the 12th
- Transit pass ("FERNWAY TRANSIT PASS"), $80†, the 5th
- Streaming ("GLIMMER STREAMING"), $15†, the 7th, on the credit card
- Pays her friend Tessa back, $60† from checking on Jan 17, Mar 14 and May 16 ("SPLITPAY PAYMENT TO TESSA ROWAN"). This is spending, not a transfer: nothing arrives in another of her accounts.

Everyday spending on the card: groceries $95–$125† weekly ("MALLOW MARKET"; [BLS food at home $6,224 a year per household, 2024](https://www.bls.gov/opub/ted/2026/the-new-year-and-household-spending.htm)), eating out $45–$80† weekly ("JUNIPER STREET KITCHEN"; [BLS food away from home $3,945](https://www.bls.gov/opub/ted/2026/the-new-year-and-household-spending.htm)), household supplies $15–$35† every three weeks ("THIMBLE GOODS"), clothes $120–$200† every two weeks ("VERVAIN APPAREL"), pharmacy $45–$85† every three weeks ("QUINCE PHARMACY"), movies $60–$100† every two weeks ("FABLE CINEMA"). Their spellings use the same tricks as the dev and test sets: `SQ *` and `TST*` tags, "ST" for STREET, run-together names and store numbers.

Money moving between accounts:

- On the 18th, pays the credit card in full from joint checking for the previous month's charges. Checking shows "PAYMENT CREDIT CARD"; the card shows "PAYMENT RECEIVED THANK YOU".
- On the 28th, moves $400† from joint checking to personal savings ("ONLINE TRANSFER TO SAVINGS" / "ONLINE TRANSFER FROM CHECKING").

Data generation check (seed 104): 181 transactions. Checking never goes below $530 (Jan 12) and ends at $6,152.67; savings $5,400; card owes $1,247.81. Spending is $18,695.14.

## Otis — Retiree with Social Security, a Pension, and a Few Returns

Otis is a retired foundry worker who rents an older apartment. He lives on Social Security and a small pension. His checking runs low at the start of January but stays positive; his savings is at the same bank and isn't set up to cover an overdraft. He shops at a housewares store, Cedar, and returns some of what he buys, and he eats at an unrelated diner, Cedar Cafe.

Income:

- Social Security, $1,868.10 on the second Wednesday (birthday on the 7th†): Jan 14, Feb 11, Mar 11, Apr 8, May 13, Jun 10; next Jul 8, per the [SSA 2026 schedule](https://www.ssa.gov/pubs/EN-05-10031-2026.pdf). It is the [SSA's estimated average retired-worker benefit of $2,071 (January 2026)](https://www.ssa.gov/cola/factsheets/2026.html) less the [2026 Part B premium of $202.90](https://www.cms.gov/newsroom/fact-sheets/2026-medicare-parts-b-premiums-deductibles). The statement says "XXSOC SEC", the [generic Social Security descriptor](https://fiscal.treasury.gov/payment-integrity/payment-integrity-resolution-services-pirs/i-want-to).
- Pension, $600†, the 1st, from "ORIEL FOUNDRY PENSION DEPOSIT". Like every fixed-day flow here it posts on its calendar day, even a weekend or Jan 1.

Accounts: checking, savings (same bank, no overdraft protection), one credit card.

Starting balances (Jan 1): checking [$1,175†], savings [$1,000†], credit card [$0†]

Example charges:

- Rent ("HEMLOCK COURT RENT"), $1,100†, the 1st. With electricity and water averaged monthly it is $1,230, below the [Census median gross rent](https://www.census.gov/newsroom/press-releases/2025/acs-1-year-estimates.html).
- Electricity ("IRIS ELECTRIC", budget billing), $100†, the 6th, below the [EIA average](https://www.eia.gov/todayinenergy/detail.php?id=65244)
- Phone ("JASPER MOBILE"), $25, the 10th: [Visible's regular price](https://www.visible.com/plans)
- Internet ("KEEL INTERNET"), $50†, the 12th
- Retiree health plan ("LUPINE RETIREE HEALTH"), $150†, the 15th, on top of Part B
- Reduced-fare transit pass ("MEADOWLINE TRANSIT PASS"), $30†, the 5th
- Water ("NACRE WATER"), $90†, every three months: Jan 8 and Apr 8, next Jul 8. The answer key labels it `recurring: "quarterly"`, a label the organizer has no cadence for.

Everyday spending on the card: groceries $55–$75† weekly ("PLOVER MARKET"), the diner $10–$20† weekly ("CEDAR CAFE"), pharmacy $20–$35† every four weeks ("RILL PHARMACY").

Cedar, on the card. Its statement name changes from "CEDAR #041" to "CEDAR HOME #041" in April. Three of five purchases are returned in full, and the June return says CREDIT, not REFUND:

| Purchase | Return |
|---|---|
| Jan 18, $42.50† | Jan 21, "REFUND CEDAR #041" |
| Feb 7, $119.00† | kept |
| Mar 23, $67.25† | Mar 30, "CEDAR #041 REFUND" |
| Apr 4, $24.80† | kept |
| Jun 17, $86.40† | Jun 22, "CEDAR HOME CREDIT" |

Money moving between accounts:

- On the 20th, pays the credit card in full from checking for the previous month's charges less returns ("PAYMENT CREDIT CARD" / "PAYMENT RECEIVED THANK YOU").
- On the 22nd, moves $100† from checking to savings ("ONLINE TRANSFER TO SAVINGS" / "ONLINE TRANSFER FROM CHECKING").

Data generation check (seed 105): 139 transactions. Checking's lowest is $75 on Jan 1, after rent and before the pension the same day, and it ends at $4,347.69; savings $1,600; card owes $343.12. Income is $14,808.60 and spending $11,379.03; Cedar comes to $143.80 after returns.

## Generated data conventions

Run `python3 fake_gen.py` from `tools/`. The script writes each person's
`transactions.json`, `answer_key.json`, and `accounts.json` under `tools/data/`.
The seed is 42 (Nia and Otis each reseed: 104 and 105), and IDs restart for each person. Maya's bills alone produce 36
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
Only Nia's and Otis's answer keys have two extra fields: each account's `owner`
(`mine` or `shared`) and, on Nia's income, `income_type` (`wages` or
`household_contribution`). `tools/data/manifest.json` records the seeds and the
SHA-256 of every data file; `uv run python checks.py` checks them.
