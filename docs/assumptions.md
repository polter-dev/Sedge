# Assumptions

The business rules Sedge assumes about a person's money, one per line, each followed by where it lives. Files are in `Packages/SedgeCore/Sources/SedgeCore/` unless a path says otherwise. This list describes what the code does today; when a rule changes in code, change its line here in the same PR.

To add a rule, add one line under its area in the same shape as the others: the rule as a plain sentence, then " — ", then the file and function in backticks. Start a new `##` area if none fits.

## Data

- "Today" is the dataset's `as_of` date, never the device clock. — `Simulator.swift` `simulate`
- The fake personas' today is 2026-06-30. — `Persona.swift` `asOf`
- One database is one person, so every account in it belongs to the same person. — `Organizer.swift` `reconcile`
- Dates are calendar days with no time zone. — `Organizer.swift` `calendar`
- A week runs Monday to Sunday; in the month-by-month transactions list, a week that crosses into another month shows only the shown month's days. — `Sedge/TransactionsView.swift` `TransactionGroups.monday(of:)`, `TransactionGroups.parts`
- A positive amount is money out; a credit card's balance is what is owed. — `Simulator.swift` `simulate`, `Tools.swift` `accountBalances`
- Plaid data's today is its newest transaction date. — `Sedge/BankConnection/ConnectBankView.swift` `syncTransactions`
- A Plaid transaction's name is the bank's original description when Plaid sends one, else Plaid's `name` (which Plaid rewrites for stores it recognizes, e.g. NETFLIX.COM to Netflix). — `Sedge/BankConnection/ConnectBankView.swift` `AllTransactionsResponse.init(from:)`
- Plaid data is saved only into the bank database, never a persona's, and is organized again after every sync. — `Sedge/BankConnection/ConnectBankView.swift` `syncTransactions`, `ConnectBankView`

## Organizer

- Two cleaned store names at least 80% alike are the same store. — `Organizer.swift` `similarityThreshold`, `sameStore`
- A name that is the first whole words of a longer one is the same store ("shell" and "shell oil"). — `Organizer.swift` `sameStore`
- "amzn" means amazon and "st" means street. — `Organizer.swift` `aliases`
- One to three letters or "paypal" before a "*", and a leading "pos", "pos debit" or "pos purchase", are a payment-processor tag, not the store, so a store with a name that short loses it. — `Organizer.swift` `processorPrefix`, `clean`
- Words with a digit in them are store numbers or ids, not part of the store's name. — `Organizer.swift` `clean`
- A statement name starting with "REFUND " is a refund. Money in whose name ends in the word "REFUND" after a store name (a trailing reference number is ignored, and the word may end a "*" descriptor, as in "AMAZON.COM*AB12C REFUND") is a refund only if it is no more than the purchases on or before it whose store name it names in full ("GEICO PREMIUM REFUND" names "GEICO"; "TAX REFUND" does not name "TAX PREP SERVICES", though the two merge by first word), and no more than what is left at the store (everything paid there on or before it, minus the refunds there before it; after "GEICO" $90, "GEICO AUTO" $500 and "GEICO AUTO REFUND" $500, a $90 "GEICO REFUND" counts). Only posted charges count as paid; a pending charge doesn't. A larger refund, or one with no such purchase, stays income ("STATE TAX REFUND"; "IRS TAX REFUND" $900 after "IRS TAX PAYMENT" $400; a second $300 "STATE U REFUND" after $500 paid and $300 already refunded). With the graph off each raw name is its own store, so such a name never finds its purchase and stays income. — `Organizer.swift` `clean`, `organize`
- At a tuition store (by the profile's rule, on posted charges: a store whose category isn't housing where a name says tuition or bursar, or an education store has one charge of $1,000 or more), a refund named last may name less of the store than the payment does, so "STATE U REFUND" counts against "STATE U TUITION". — `Organizer.swift` `organize`
- A store's category is the keyword list most of its names match; ties go to the earlier list, no match is "other". — `Organizer.swift` `category(of:)`
- A subscription word beats a shopping word ("amazon prime membership" is a subscription). — `Organizer.swift` `categoryKeywords`
- HOA dues are in the housing category. — `Organizer.swift` `categoryKeywords`
- A refund belongs to the latest earlier purchase of the same amount at the same store. — `Organizer.swift` `organize`
- Money in and money out at one store are separate series, and each direction has at most one series. — `Organizer.swift` `organize`
- A recurring series needs at least three charges. — `Organizer.swift` `recurrence(of:)`
- Weekly charges are 6 to 8 days apart, biweekly 12 to 16, monthly 26 to 35. — `Organizer.swift` `cadences`
- A series is twice-monthly when every charge is on one of two days of the month, the two days take turns, and each day's charges on their own are monthly (three or more, 26 to 35 days apart). Taking turns keeps a bill that moved to a new day monthly. — `Organizer.swift` `recurrence(of:)`, `byDay`
- Each charge of a twice-monthly series belongs to the day it is on, or to the day it was moved from when that day is a Saturday or Sunday (paid the Friday before or Monday after, which may be in the month before or after); the last day of the month counts as one day (Feb 28, Apr 30, Mar 31). The organizer, profile and simulator all group charges this way, so a charge left out by kind or pending never moves another to the wrong day. — `Organizer.swift` `byDay`, `isOn`
- A charge that fits both days (only when they are a few days apart, or both past a short month's end) goes with the first day found. — `Organizer.swift` `byDay`
- A holiday shift (Thu Jan 1 paid Fri Jan 2) is not a weekend shift, so it breaks a twice-monthly series, which is then biweekly or not recurring. — `Organizer.swift` `isOn`
- Twice-monthly is checked before biweekly: biweekly pay drifts through the month, so it never stays on two days or their weekend shifts. — `Organizer.swift` `recurrence(of:)`
- A missed charge (a day's gap over 35 days) or an extra charge (on a third day, or the days not taking turns) breaks a twice-monthly series, so it is then biweekly or not recurring. — `Organizer.swift` `recurrence(of:)`
- A bill may change price by up to 25% between charges and still be the same bill. — `Organizer.swift` `priceChangeAllowance`
- A series' typical amount is the middle of its last three charges; twice a month, of the next date's day's charges. — `Organizer.swift` `recurrence(of:)`
- A series' next date is its latest charge plus a week, two weeks or a month; twice a month, a month after the older of the two days' latest charges. — `Organizer.swift` `recurrence(of:)`
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
- A tuition refund is any refund at the tuition store, of any size, including when tuition was found only by the $1,000 rule. With reconciliation off a refund is income, so tuition refunded is 0. — `Profile.swift` `infer`
- Tuition `refunded` is capped at tuition paid, while the `refunds` list shows every refund. — `Profile.swift` `infer`
- A plain school-name line ("STATE U") can merge the school's bookstore and tuition into one store; a bookstore refund there counts as tuition refunded, on purpose. — `Profile.swift` `infer`
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
- A twice-monthly series is projected as two monthly series, one per day of the month (grouped by `Organizer.byDay`), each due on its own `dueDay` at its own typical amount. — `Simulator.swift` `simulate`
- A recurring series is paid from, or into, the account its latest charge used. — `Simulator.swift` `simulate`
- A charge up to 3 days past due is late, not stopped, and is projected for tomorrow; after that its series has stopped. — `Simulator.swift` `simulate`
- A paycheck due on a weekend may arrive on the business day before or after; a paycheck within that shift is on time, not late. Every monthly or twice-monthly series of money in counted as income gets 2 more days before it counts as stopped; with reconciliation off, that includes transfer and card-payment deposits and refunds. — `Simulator.swift` `weekendShiftDays`, `simulate`
- Projected monthly pay dates are not moved to business days, so pay on a fixed day can be projected up to 2 days before or after the real one. Pay on the 29th–31st or the last business day can be up to 5 days early (Fri Feb 26 makes Mar 26 while pay comes Mar 31), and pay a weekend moves into another month up to 5 days early or late (Sun Mar 1 paid Fri Feb 27 makes Mar 27 while pay comes Apr 1). — `Simulator.swift` `dueDay`, `monthDay`
- Every card statement closes on the last day of the month and is paid in full. — `Simulator.swift` `simulate`
- A card is paid from the account of its latest matched payment, on the day of the month of its latest payment, for what it owed at the last month end less what was paid since. — `Simulator.swift` `simulate`
- Card payments due the same day are made and listed in order of card name, then account id, so every run gives the same output. — `Simulator.swift` `project`
- A what-if change to a recurring series finds it by store name and adds its signed amount to the size of every charge on or after its start day, so +200 makes a bill or a paycheck 200 bigger, and no charge shrinks below 0; a cancelled series has no charges from its start day. Card payments can't be changed this way. — `Simulator.swift` `Change`, `project`
- The range reruns the projection with each account's highest and with its lowest four-week everyday spending among the three four-week windows ending today; an account with no spending in a window spent 0 there. — `Simulator.swift` `range`
- A four-week window counts toward the range only when the earliest transaction is on or before its first day; today's window always counts, so with only that one the range equals the projection. — `Simulator.swift` `range`

## Cash-flow screen

- The screen projects the same checking account as simulate_balance; its lowest balance is the first day of the minimum, labeled "Before payday" when the next day's balance is higher, else with a checking bill paid that day. — `Sedge/CashFlowView.swift` `CashFlow.lowest`, `CashFlow.lowReason`
- Scenarios offer only recurring bills the projection charges; subscriptions are those whose store is in the subscriptions category, cancelled from tomorrow, and the saving shown is the simulator's end-balance difference. — `Sedge/CashFlowView.swift` `CashFlow.load`, `CashFlowView.load`

## Savings

- A cut is stopping all spending at one store, worth everything spent there (less refunds, pending left out) divided by the months the data covers, a part month counting as a whole one. — `Savings.swift` `ranked`
- Only spending can be cut: transfers and card payments are never cuts, and neither is any store in the housing, utilities, phone_internet, insurance, loans, education or income category. — `Savings.swift` `fixedCategories`, `ranked`
- The profile's rent, mortgage, tuition and loan stores, including the person's corrections, are never cuts, matched by store name. — `Savings.swift` `ranked`
- A store with a recurring series of charges is a bill, never a cut, unless its category is subscriptions, coffee, dining, groceries, gas or shopping. — `Savings.swift` `everydayCategories`, `ranked`
- A store's category for savings is the store's own, not a category the person moved one transaction to. — `Savings.swift` `ranked`
- Weeks are 7-day blocks counted back from today; days before the oldest whole week count toward the monthly amount but not the weekly parts, and fewer than 4 whole weeks is too little data. — `Savings.swift` `ranked`
- A store is a cut only if it was bought from in at least 2 different calendar months and at least once in the 60 days up to today (60 days back still counts); a one-off or stopped store saves nothing from now on. Its monthly amount is still its average month over all the data. — `Savings.swift` `ranked`
- Tight stretches are found in each calendar month, not across all the data, because balances drift (every persona's rises over the half-year, so the lowest weeks overall were all early ones): in each month, the 7 days in a row inside that month whose end-of-day checking balances add up lowest, a tie going to the earlier stretch; a month with under 7 days of data has none. The balance is today's with every later posted transaction undone, on the account simulate_balance uses. — `Savings.swift` `tightDays`
- The value score is the average of three parts from 0 to 1: kept up (spending per day in the tight stretches over the store's spending per day across all the data, capped at 1; 0.5 with no bank balance), regular (weeks with a purchase over all weeks), and size (the store's spending over the biggest flexible store's), rounded to 2 places. — `Savings.swift` `ranked`
- A monthly charge, a store bought from at most once in any calendar month, gets the neutral 0.5 for kept up, and its evidence says so instead of a percentage: its one charge a month lands inside or outside the 7-day tight stretch by billing day alone, so two charges paid every month would otherwise score 0 or 1 by the calendar. — `Savings.swift` `ranked`
- Cuts go least valued first, a tie going to the bigger monthly amount and then the store name; they are taken in that order until they reach the goal, at most 5. — `Savings.swift` `ranked`, `plan`
- When every flexible store together falls short of the goal, the answer says it can't be reached without cutting bills. — `Savings.swift` `plan`
- A goal by a date is spread evenly with a month of 30 days ($300 in 45 days is $200 a month). — `Savings.swift` `savingsOptions`

## Tools and saved answers

- Transfers and card payments are never spending, bills or income. — `Tools.swift` `spendingFilter`, `recurringCharges`
- Refunds count against spending, and pending charges don't count until they post. — `Tools.swift` `spendingFilter`
- A store whose refunds cancel out its spending isn't a top store. — `Tools.swift` `topMerchants`
- A series that stopped is still listed by recurring_charges, with a next date before today. — `Tools.swift` `recurringCharges`
- simulate_balance reports the checking account (or the first bank account with a balance) and takes the extra purchase from it; bills there are the ones whose series last used it. — `Tools.swift` `simulateBalance`
- simulate_balance's balance on a day is that account's projected balance at the end of the day, after any extra purchase that day; on today it is the current balance. — `Tools.swift` `simulateBalance`
- An answer shows at most 10 rows. — `Tools.swift` `maxRows`
- A fact the person answered is never asked again; a skipped question may be asked next time. — `AskUser.swift` `run`
- A profile correction answers a question about the same kind of fact ("housing" covers "housing_type"). — `AskUser.swift` `remembered`, `covers`
- A saved answer or profile correction is used as the answer to related questions without asking; the person can change or remove it in Saved answers, and a removed one is asked again. — `AskUser.swift` `remembered`, `change`, `forget`; `Sedge/SavedAnswersView.swift`
- A transaction the person moved to another category counts in that category instead of its store's, in the tools' category totals and the Spending screen; totals by store and overall don't change, and the profile still reads the store's category. — `Tools.swift` `spendingFilter`; `Sedge/SpendingView.swift` `SpendingTotal.all`; `Profile.swift` `infer`
- An account's owner (mine or shared) and a transaction's familiar answer (yes or not_sure) are only reported to the model; they don't change any total. — `Answers.swift`; `Tools.swift` `accountBalances`, `findTransactions`
- An answer about a pending charge is lost when the charge posts under a new id. — `SedgeDatabase.swift` `save`
- An account's nickname is the person's own name for it, shown by the app in place of the bank's name; a blank one (after trimming spaces) is no nickname, and the tools keep reporting the bank's name. — `Answers.swift` `setNickname`; `Sedge/AccountCheckView.swift` `ListedAccount.title`

## Ask screen demo

- The Debug sample conversation counts food as groceries, dining and coffee, and its "usual pace" is the average of the same days (1st through today's day, or the month's end) of the last three months. — `Sedge/AskView.swift` `ChatTurn.sample`, `monthToDate`
- The sample's quick check asks about the month's largest transfer or card payment with a positive amount, the latest one on a tie. — `Sedge/AskView.swift` `ChatTurn.transferCheck`
- A quick-check tap is saved through `ask_user` and replaces an answer already saved for that fact; "Later" saves nothing and keeps any earlier answer, so it may be asked again. — `Sedge/AskView.swift` `TurnView.answer`

## Spending screen

- Months are compared over the same first days: the day of the month of `as_of` (a shorter month just ends sooner), for `as_of`'s month and the three before it. — `Sedge/SpendingView.swift` `SpendingTotal.all`, `SpendingView.months`
- The All months screen counts whole months, and money moved between the person's own accounts (transfers and card payments) counts only when its switch is on, as its own category bar, using only the side leaving an account so the arriving side doesn't cancel it. — `Sedge/SpendingView.swift` `SpendingTotal.all`; `Sedge/AllMonthsView.swift` `byMonth`, `byCategory`
- A tapped month's categories on All months leave money moved out, as its bar does, so they add up to that bar; the month chart pages in six-month windows counted back from the newest month in the data, and the oldest window may start before the data. — `Sedge/AllMonthsView.swift` `breakdown`, `windows`
- The spending mosaic shows a category's three biggest stores in the page's month and adds the rest up as "Other stores", or every store when there are four or fewer; with "All" it does the same with categories ("Other categories"). — `Sedge/SpendingView.swift` `SpendingView.stores`, `SpendingView.categoryBlocks`
- A month page on the Spending screen (swiped to, or a tapped bar) shows that month's 1st through the same day of the month as `as_of` (a shorter month just ends sooner), the same days as its bar, in the total, the mosaic and the latest row; its change line compares the bar with the month before's bar and gives no percentage when the month before is $0 or less. — `Sedge/SpendingView.swift` `SpendingView.window`, `SpendingView.changeLine`
- "All" on the Spending screen is every category's bar added up in whole cents; money moved between the person's own accounts isn't in it. — `Sedge/SpendingView.swift` `SpendingView.bars`
- The Spending chart's dollar axis starts at $0 and tops out at the largest bar rounded up to the smallest step of 25, 50, 100, 250, 500, 1,000, 2,500, 5,000 … (on and up) that reaches it in at most 4 steps; a bar of $0 or less still gets one step. — `Sedge/SpendingView.swift` `SpendingView.axisTop`
- The biggest change on Trends is the store in the category (with "All", the category) whose spending changed most, up or down, between the page's month and the month before, both over the same first days; a store missing from one month spent $0 then, the first name alphabetically wins a tie, and nothing shows when nothing changed. With "All" only a category the category sheet lists (spent in the four months shown) can be named, so on the oldest page a category spent only in the month before is left out. It is shown signed in whole dollars, red when spending rose and green when it fell. — `Sedge/SpendingView.swift` `SpendingView.biggestChange`, `SpendingView.categoryChange`, `SpendingView.changeText`
- The category sheet on Spending lists "All" first, then every category with spending in the four months shown, most spent first in the page's month (over the same first days; none that month counts $0), and by name on a tie. — `Sedge/SpendingView.swift` `SpendingView.categoryOrder`
- The cash-flow card on Trends shows the same 30-day projection and low point as the Cash flow screen's first view, with nothing switched on. — `Sedge/SpendingView.swift` `SpendingView.lowPointLine`; `Sedge/CashFlowView.swift` `CashFlow.load`, `CashFlow.lowest`

- The Ways to save screen, opened from Spending, shows the same cuts savings_options gives for the monthly goal typed in. — `Sedge/SavingsView.swift` `load`

## About you screen

- A tuition payment's term is its month's: January to May is the Spring Term, June and July the Summer Term, August to December the Fall Term; the tuition tile shows the term of the last payment. — `Sedge/ProfileView.swift` `ProfileView.term`, `ProfileView.chip`
- An income, housing or loan tile's next date is the first day after `as_of` that the simulator's projection changes when that series is cancelled, found by store name; a series the simulator doesn't project (irregular, stopped, or renamed by a correction) shows no date. — `Sedge/ProfileView.swift` `ProfileView.nextDates`
- The tuition tile's "spent" is everything paid and "back" is everything refunded, shown apart; with nothing refunded it shows only what was spent. — `Sedge/ProfileView.swift` `ProfileView.figure`, `ProfileView.refund`

## Transaction screen

- Sedge's context compares a purchase with the same store's three posted purchases just before it (same-day ones by id; refunds, transfers and pending charges left out): above all three is higher, below all three is lower, anything else is in line. With fewer than three earlier purchases there is no comparison. — `Sedge/TransactionDetailView.swift` `StoreContext.compare`, `TransactionDetail.earlierCharges`
- A purchase is worth a look when it is posted spending in the 30 days up to today (30 days back still counts), has no "Does this look familiar?" answer, and either is at least 1.5× and at least $25 more than the highest of the same store's three posted purchases just before it (same-day ones by id; answered ones still count as history; with one or two earlier purchases it is never flagged), or is the store's first purchase and is $150 or more. The store is the organizer's grouping, never Plaid's merchant name or category. — `WorthALook.swift` `flagged`; `Sedge/SpendingView.swift` `worthALookRow`
- Choosing a transaction's store category again clears the person's category answer instead of saving it. — `Sedge/TransactionDetailView.swift` `setCategory`
- After a bank connection, each account with no owner answer is asked about once; Later saves nothing, so it is asked again after the next connection. — `Sedge/AccountCheckView.swift` `AccountChecksAfterConnecting`
