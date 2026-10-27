# Assumptions

The business rules Sedge assumes about a person's money, one per line, each followed by where it lives. Files are in `Packages/SedgeCore/Sources/SedgeCore/` unless a path says otherwise. This list describes what the code does today; when a rule changes in code, change its line here in the same PR.

To add a rule, add one line under its area in the same shape as the others: the rule as a plain sentence, then " — ", then the file and function in backticks. Start a new `##` area if none fits.

## Data

- "Today" is the dataset's `as_of` date, never the device clock. — `Simulator.swift` `simulate`
- The fake personas' today is 2026-06-30. — `Persona.swift` `asOf`
- One database is one person, so every account in it belongs to the same person. — `Organizer.swift` `reconcile`
- Dates are calendar days with no time zone. — `Organizer.swift` `calendar`
- A positive amount is money out; a credit card's balance is what is owed. — `Simulator.swift` `simulate`, `Tools.swift` `accountBalances`
- Plaid data's today is its newest transaction date. — `Sedge/BankConnection/ConnectBankView.swift` `syncTransactions`
- Plaid data is saved only into the bank database, never a persona's, and is organized again after every sync. — `Sedge/BankConnection/ConnectBankView.swift` `syncTransactions`, `ConnectBankView`

## Organizer

- Two cleaned store names at least 80% alike are the same store. — `Organizer.swift` `similarityThreshold`, `sameStore`
- A name that is the first whole words of a longer one is the same store ("shell" and "shell oil"). — `Organizer.swift` `sameStore`
- "amzn" means amazon and "st" means street. — `Organizer.swift` `aliases`
- One to three letters or "paypal" before a "*", and a leading "pos", "pos debit" or "pos purchase", are a payment-processor tag, not the store, so a store with a name that short loses it. — `Organizer.swift` `processorPrefix`, `clean`
- Words with a digit in them are store numbers or ids, not part of the store's name. — `Organizer.swift` `clean`
- A statement name starting with "REFUND " is a refund. — `Organizer.swift` `clean`
- A store's category is the keyword list most of its names match; ties go to the earlier list, no match is "other". — `Organizer.swift` `category(of:)`
- A subscription word beats a shopping word ("amazon prime membership" is a subscription). — `Organizer.swift` `categoryKeywords`
- HOA dues are in the housing category. — `Organizer.swift` `categoryKeywords`
- A refund belongs to the latest earlier purchase of the same amount at the same store. — `Organizer.swift` `organize`
- Money in and money out at one store are separate series, and each direction has at most one series. — `Organizer.swift` `organize`
- A recurring series needs at least three charges. — `Organizer.swift` `recurrence(of:)`
- Weekly charges are 6 to 8 days apart, biweekly 12 to 16, monthly 26 to 35. — `Organizer.swift` `cadences`
- A series is twice-monthly when every other charge falls on one day of the month and the rest on another, and each day on its own is monthly (three or more charges, 26 to 35 days apart). — `Organizer.swift` `recurrence(of:)`, `everyOther`
- Each charge of a twice-monthly series is on its day, or on the Friday before or Monday after when that day is a Saturday or Sunday, which may be in the month before or after; the last day of the month counts as one day (Feb 28, Apr 30, Mar 31). — `Organizer.swift` `fixedDay(of:)`
- A holiday shift (Thu Jan 1 paid Fri Jan 2) is not a weekend shift, so it breaks a twice-monthly series, which is then biweekly or not recurring. — `Organizer.swift` `fixedDay(of:)`
- Twice-monthly is checked before biweekly: biweekly pay drifts through the month, so it never stays on two days or their weekend shifts. — `Organizer.swift` `recurrence(of:)`
- A missed or extra charge breaks a twice-monthly series' every-other split, so it is then biweekly or not recurring. — `Organizer.swift` `recurrence(of:)`
- A bill may change price by up to 25% between charges and still be the same bill. — `Organizer.swift` `priceChangeAllowance`
- A series' typical amount is the middle of its last three charges. — `Organizer.swift` `recurrence(of:)`
- A series' next date is its latest charge plus a week, two weeks or a month; twice a month, the charge before the latest plus a month. — `Organizer.swift` `recurrence(of:)`
- The two sides of a transfer post at most 3 days apart. — `Organizer.swift` `transferWindowDays`, `reconcile`
- A transfer pairs the same amount (to the cent) leaving one account and arriving in another, when either side's name says payment, transfer, xfer, pmt, pymt or autopay, or Plaid's category says transfer. — `Organizer.swift` `reconcile`
- A transfer whose name mentions one of the person's accounts goes to that account first; otherwise the closest date wins. — `Organizer.swift` `reconcile`
- A matched pair that touches a credit card is a card payment; any other pair is a transfer. — `Organizer.swift` `reconcile`
- Unmatched money out is spending; unmatched money in is income, or a refund when its name says so. — `Organizer.swift` `reconcile`

## Profile

- A recurring series of deposits from one payer is income. — `Profile.swift` `infer`
- Deposits from one payer in three or more months, but not on a cadence or not steady, are irregular income. — `Profile.swift` `infer`
- Monthly income is everything from that payer divided by the months in the data; a partial month counts as a whole one. — `Profile.swift` `infer`
- A housing bill is a mortgage if its name says "mortgage", rent if it says rent, apartment, property management, lease or leasing. — `Profile.swift` `rentWords`, `infer`
- A rent or mortgage bill with no steady series, paid in three or more different months, is still housing: schedule irregular, amount the middle payment. In one or two months it is not housing. — `Profile.swift` `infer`
- HOA dues are not counted as housing (neither rent nor mortgage). — `Profile.swift` `infer`
- A charge named tuition or bursar is tuition. — `Profile.swift` `tuitionWords`
- One education charge of $1,000 or more is tuition, not books or fees. — `Profile.swift` `tuitionMinimum`
- Tuition is paid per term, so its schedule is usually irregular. — `Profile.swift` `infer`
- Tuition paid and tuition refunded are kept separately; a refund doesn't erase the payment. — `Profile.swift` `Value.paid`, `Value.refunded`
- A tuition refund is a refund at the tuition store; under the $1,000 rule only a refund of $1,000 or more counts. With reconciliation off a refund is income, so tuition refunded is 0. — `Profile.swift` `infer`
- A store in the loans category, or Affirm, Klarna, Afterpay or "installment", is a loan. — `Profile.swift` `installmentWords`, `infer`
- A loan is installment, auto or student by the words in its name, otherwise "other". — `Profile.swift` `loanTypes`
- Two or more payments to a lender without a cadence are an irregular loan. — `Profile.swift` `infer`
- A monthly bill's usual day is its most common day of the month; a tie goes to the earlier day. — `Profile.swift` `usualDay`
- Twice-monthly rent or mortgage is housing like a monthly one, costing its two days' typical amounts a month (1000 on the 1st and 900 on the 16th is 1900). — `Profile.swift` `infer`
- A correction the person makes always wins over a worked-out fact. — `Profile.swift` `facts`

## Simulator

- Everyday spending is the last 28 days of spending (less refunds) outside any recurring series, spread evenly over each day, per account. — `Simulator.swift` `trailingDays`, `simulate`
- Pending transactions are left out of everyday spending and card statements. — `Simulator.swift` `simulate`
- An account without a current balance isn't projected. — `Simulator.swift` `simulate`
- A monthly series is due on its latest charge's day of the month. — `Simulator.swift` `dueDay`
- When the latest charge is the last day of a short month (Feb 28, Apr 30), the due day is the later of that day and the day of the latest charge in a 31-day month (Mar 31, Apr 30, May 29, Jun 30 gives the 30th). — `Simulator.swift` `dueDay`
- A due day past the end of a short month falls on that month's last day. — `Simulator.swift` `monthDay`
- Weekly and biweekly series repeat every 7 or 14 days from the latest charge. — `Simulator.swift` `simulate`
- A twice-monthly series is projected as two monthly series, every other charge each, each due on its own `dueDay` at its own typical amount. — `Simulator.swift` `simulate`
- A recurring series is paid from, or into, the account its latest charge used. — `Simulator.swift` `simulate`
- A charge up to 3 days past due is late, not stopped, and is projected for tomorrow; after that its series has stopped. — `Simulator.swift` `simulate`
- A paycheck due on a weekend may arrive on the business day before or after; a paycheck within that shift is on time, not late. Every monthly or twice-monthly series of money in counted as income gets 2 more days before it counts as stopped; with reconciliation off, that includes transfer and card-payment deposits and refunds. — `Simulator.swift` `weekendShiftDays`, `simulate`
- Projected monthly pay dates are not moved to business days, so pay on a fixed day can be projected up to 2 days before or after the real one. Pay on the 29th–31st or the last business day can be up to 5 days early (Fri Feb 26 makes Mar 26 while pay comes Mar 31), and pay a weekend moves into another month up to 5 days early or late (Sun Mar 1 paid Fri Feb 27 makes Mar 27 while pay comes Apr 1). — `Simulator.swift` `dueDay`, `monthDay`
- Every card statement closes on the last day of the month and is paid in full. — `Simulator.swift` `simulate`
- A card is paid from the account of its latest matched payment, on the day of the month of its latest payment, for what it owed at the last month end less what was paid since. — `Simulator.swift` `simulate`

## Tools and saved answers

- Transfers and card payments are never spending, bills or income. — `Tools.swift` `spendingFilter`, `recurringCharges`
- Refunds count against spending, and pending charges don't count until they post. — `Tools.swift` `spendingFilter`
- A store whose refunds cancel out its spending isn't a top store. — `Tools.swift` `topMerchants`
- A series that stopped is still listed by recurring_charges, with a next date before today. — `Tools.swift` `recurringCharges`
- simulate_balance reports the checking account (or the first bank account with a balance) and takes the extra purchase from it; bills there are the ones whose series last used it. — `Tools.swift` `simulateBalance`
- An answer shows at most 10 rows. — `Tools.swift` `maxRows`
- A fact the person answered is never asked again; a skipped question may be asked next time. — `AskUser.swift` `run`
- A profile correction answers a question about the same kind of fact ("housing" covers "housing_type"). — `AskUser.swift` `remembered`, `covers`
- A saved answer or profile correction is used as the answer to related questions without asking; the person can change or remove it in Saved answers, and a removed one is asked again. — `AskUser.swift` `remembered`, `change`, `forget`; `Sedge/SavedAnswersView.swift`
