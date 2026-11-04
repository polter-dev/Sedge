//
//  TransactionDetailView.swift
//  Sedge
//

import GRDB
import SedgeCore
import SwiftUI

/// Everything the transaction screen shows about one transaction, read from the open database.
struct TransactionDetail: Decodable, FetchableRecord {
    let transaction_id: String
    let date: String
    /// The organizer's store name, or the raw name if the organizer hasn't run.
    let store: String
    /// The raw statement name, as the bank sent it.
    let name: String
    /// Plaid's sign: positive is money out.
    let amount: Double
    let pending: Bool
    /// spending, income, transfer, card_payment or refund (set by the organizer).
    let kind: String?
    let merchant_id: String?
    let account: String
    let mask: String?
    /// The organizer's category for the store, nil if the organizer hasn't run.
    let store_category: String?
    /// The category the person moved this transaction to, if any (#76's answer).
    let category_override: String?
    /// The category this transaction is counted in, by the Spending screen's own rule.
    let category: String
    /// "yes" or "not_sure", nil until answered.
    let familiar: String?

    static func load(_ id: String, in database: SedgeDatabase) throws -> TransactionDetail? {
        try database.dbQueue.read { db in
            try TransactionDetail.fetchOne(db, sql: """
                SELECT t.transaction_id, t.date, COALESCE(m.name, t.name) AS store, t.name, t.amount, t.pending,
                       t.kind, t.merchant_id, a.name AS account, a.mask, c.name AS store_category,
                       t.category_override, \(SpendingTotal.categoryOf) AS category, t.familiar
                FROM transactions t
                JOIN accounts a ON a.account_id = t.account_id
                LEFT JOIN entities m ON m.id = t.merchant_id
                \(SpendingTotal.categoryJoins)
                WHERE t.transaction_id = ?
                """, arguments: [id])
        }
    }

    /// The amounts of the same store's purchases just before this one, newest first, at most three.
    /// Same-day charges are ordered by id, as in the transactions list. Pending charges and
    /// anything that isn't spending (refunds, transfers) are left out.
    func earlierCharges(in database: SedgeDatabase) throws -> [Double] {
        guard let merchant_id else { return [] }
        return try database.dbQueue.read { db in
            try Double.fetchAll(db, sql: """
                SELECT amount FROM transactions
                WHERE merchant_id = ? AND kind = 'spending' AND NOT pending
                  AND (date < ? OR (date = ? AND transaction_id < ?))
                ORDER BY date DESC, transaction_id DESC
                LIMIT 3
                """, arguments: [merchant_id, date, date, transaction_id])
        }
    }
}

/// "Sedge's context": how a purchase compares with the same store's three purchases before it.
/// Computed from the data only, never written by a model.
struct StoreContext: Equatable {
    /// "Higher than your last three visits.", "Lower …", "In line …", or a plain line when
    /// there aren't three earlier visits to compare with.
    let headline: String
    /// "Those were $8.00–$14.00.", or nil when there is nothing to compare.
    let range: String?

    /// `earlier` is the store's earlier purchase amounts, newest first (only the first three count).
    static func compare(_ amount: Double, earlier: [Double]) -> StoreContext {
        guard earlier.count >= 3 else {
            return StoreContext(headline: "Fewer than three earlier visits here, so there’s nothing to compare yet.", range: nil)
        }
        // Whole cents, so float noise (14.000000001) never turns "in line" into "higher".
        let cents = { (dollars: Double) in (dollars * 100).rounded() }
        let last = earlier.prefix(3).map(cents)
        let low = last.min()!, high = last.max()!
        let headline = cents(amount) > high ? "Higher than your last three visits."
            : cents(amount) < low ? "Lower than your last three visits."
            : "In line with your last three visits."
        let money = { (cents: Double) in (cents / 100).formatted(.currency(code: "USD")) }
        let range = low == high ? "Those were all \(money(low))." : "Those were \(money(low))–\(money(high))."
        return StoreContext(headline: headline, range: range)
    }
}

/// One transaction: when, where, how much, Sedge's context, and the person's answers about it.
/// Opened from the transactions list and the Spending screen's latest transaction.
struct TransactionDetailView: View {
    let database: SedgeDatabase
    let id: String
    /// The open data's name, the same saved choice ContentView opens, so the source line can say
    /// whether this came from a sample person's file or the linked bank.
    @AppStorage("persona") private var choice = "maya"
    @State private var detail: TransactionDetail?
    @State private var context: StoreContext?
    /// The organizer's categories found in this data, offered when changing the category.
    @State private var categories: [String] = []
    /// The store's transactions, for Merchant history.
    @State private var history: [ListedTransaction] = []
    /// The design's 16 pt icon, growing with the text beside it.
    @ScaledMetric(relativeTo: .caption) private var sproutSize: CGFloat = 16
    /// The person hid the "not a fraud determination" note. Saved in the app's settings, so it
    /// stays hidden on every transaction and for every dataset, until the Accounts tab shows it again.
    @AppStorage("hideSpendingNote") private var noteHidden = false
    /// True for the 4 s the note's box says it was hidden, with Undo.
    @State private var noteUndo = false
    /// The familiar prompt's countdown, 4 down to 0, while the saved bar shows; nil shows the buttons.
    /// At 0 the prompt is folded away until the screen is opened again.
    @State private var countdown: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            if let detail {
                content(detail)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
            }
        }
        .background(Color.background)
        .navigationTitle("Transaction")
        .navigationBarTitleDisplayMode(.inline)
        // Runs on open, and again on coming back from Merchant history.
        .task { reload() }
        // The note's Undo line stays 4 s, then the box collapses. Undo cancels this by
        // changing `noteUndo`; a cancelled sleep fails, so nothing collapses after an Undo.
        .task(id: noteUndo) {
            guard noteUndo, (try? await Task.sleep(for: .seconds(4))) != nil else { return }
            // With Reduce Motion the box is simply gone in the next frame, so nothing slides.
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { noteUndo = false }
        }
        // One tick a second: 4, 3, 2, 1, 0. Each tick changes `countdown`, which starts the next one;
        // Undo sets it to nil, which cancels the tick in progress.
        .task(id: countdown) {
            guard let count = countdown, count > 0, (try? await Task.sleep(for: .seconds(1))) != nil else { return }
            // Reaching 0 folds the prompt away. With Reduce Motion the number just changes and the
            // prompt is removed without sliding the rest up.
            withAnimation(reduceMotion ? nil : count == 1 ? .easeInOut(duration: 0.3) : .default) { countdown = count - 1 }
        }
    }

    private func content(_ detail: TransactionDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(detail.pending ? "Pending" : "Posted") · \(detail.date.displayDate(.dateTime.month(.wide).day().year()))")
                .font(.note)
                .foregroundStyle(.secondary)
            Text(detail.store)
                .font(.title.bold())
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 3)
            Text(amountText(detail.amount))
                .font(.largeTitle.weight(.semibold))
                .monospacedDigit()
                .padding(.top, 16)
            Text("\(accountTitle(detail.account, detail.mask)) · \(SpendingView.title(detail.category))")
                .font(.note)
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(accountTitle(detail.account, detail.mask, spoken: true)), \(SpendingView.title(detail.category))")
                .padding(.top, 7)
            rule.padding(.vertical, 17)

            if let context {
                contextBlock(context)
                rule.padding(.vertical, 17)
            }

            if countdown != 0 {
                Text("Does this look familiar?")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Group {
                    if let countdown {
                        savedBar(detail.familiar == "not_sure" ? "Not sure" : "Yes", countdown: countdown)
                    } else {
                        AnswerStack {
                            AnswerButton("Yes", chosen: detail.familiar == "yes", filled: detail.familiar != "not_sure") { setFamiliar(.yes) }
                            AnswerButton("Not sure", chosen: detail.familiar == "not_sure") { setFamiliar(.notSure) }
                        }
                    }
                }
                // The design's swap between the buttons and the saved bar; Reduce Motion keeps only the fade.
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
                .padding(.top, 10)
                rule.padding(.vertical, 17)
            }

            Menu {
                // Choosing the store's own category clears the answer, so the data stays as the organizer left it.
                Picker("Category", selection: Binding(get: { detail.category }, set: setCategory)) {
                    ForEach(categories, id: \.self) { Text(SpendingView.title($0)) }
                }
            } label: {
                // The subtitle names Sedge's category, never Plaid's: the organizer doesn't read Plaid's.
                listRow("Category", detail.category_override == nil ? "Sedge category · editable" : "Changed by you · editable",
                        value: SpendingView.title(detail.category))
            }
            .accessibilityLabel("Category")
            .accessibilityValue(SpendingView.title(detail.category))
            if detail.merchant_id != nil {
                NavigationLink {
                    TransactionsView(rows: history, database: database)
                        .navigationTitle(detail.store)
                        .navigationSubtitle("Merchant history")
                } label: {
                    listRow("Merchant history", history.count == 1 ? "1 transaction" : "\(history.count) transactions", value: "View")
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Bank description: \(detail.name)")
                Text(choice == SedgeDatabase.bankChoice ? "Source: linked bank via Plaid" : "Source: sample data, \(choice.capitalized)’s file")
            }
            .font(.note)
            .foregroundStyle(.secondary)
            .padding(.top, 18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The comparison with the store's earlier visits, and the note that it's not a fraud check.
    private func contextBlock(_ context: StoreContext) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Label {
                Text("Sedge’s context").font(.row.weight(.semibold))
            } icon: {
                Image("sprout")
                    .resizable()
                    .frame(width: sproutSize, height: sproutSize)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Color.accent)
            .accessibilityAddTraits(.isHeader)
            Text(context.headline)
                .font(.answer)
                .padding(.top, 10)
            if let range = context.range {
                Text(range)
                    .font(.row)
                    .foregroundStyle(.secondary)
                    .padding(.top, 14)
            }
            if !noteHidden || noteUndo {
                spendingNote
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.leading, 12)
                    .background(Color.soft, in: .rect(cornerRadius: 10))
                    .padding(.top, 14)
            }
        }
    }

    /// The note with its 44 × 44 ×, or for 4 s after the × the line saying it's hidden, with Undo.
    /// The text cross-fades inside the same box.
    @ViewBuilder private var spendingNote: some View {
        if noteHidden {
            let text = Text("Spending note hidden on every transaction.")
                .font(.row)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            let undo = undoButton { setNoteHidden(false) }
            // At the largest text sizes Undo drops under the line instead of squeezing it.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) { text; undo }
                VStack(alignment: .leading, spacing: 0) { text.padding(.top, 12); undo }
            }
            .padding(.trailing, 4)
        } else {
            HStack(spacing: 4) {
                Text("This is a spending observation, not a fraud determination.")
                    .font(.row)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
                Button("Dismiss", systemImage: "xmark") { setNoteHidden(true) }
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
        }
    }

    /// "Saved · Yes", the countdown ring and Undo, in place of the answer buttons.
    private func savedBar(_ answer: String, countdown: Int) -> some View {
        let text = Text("Saved · \(answer)").font(.row).frame(maxWidth: .infinity, alignment: .leading)
        let ring = Text("\(countdown)")
            .font(.note.weight(.semibold))
            .monospacedDigit()
            .contentTransition(.numericText(countsDown: true))
            // The ring stays 24 pt at every text size, so its number stops growing before it would spill out.
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .foregroundStyle(Color.accent)
            .frame(width: 24, height: 24)
            .overlay(Circle().stroke(Color.accent, lineWidth: 2))
            .accessibilityLabel("Closing in \(countdown)")
        let undo = undoButton(undoFamiliar)
        // At the largest text sizes the ring and Undo drop under the text.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { text; ring; undo }
            VStack(alignment: .leading, spacing: 0) {
                text.padding(.top, 12)
                HStack(spacing: 8) { ring; undo }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(Color.surface, in: .rect(cornerRadius: 10))
    }

    /// The design's text-only Undo, with a 44 pt target.
    private func undoButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Undo")
                .font(.row.weight(.semibold))
                .foregroundStyle(Color.accent)
                .padding(.horizontal, 8)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// Hides the note (its box shows the Undo line for 4 s) or, from Undo, shows it again.
    private func setNoteHidden(_ hidden: Bool) {
        withAnimation(.easeInOut(duration: reduceMotion ? 0.2 : 0.25)) {
            noteHidden = hidden
            noteUndo = hidden
        }
    }

    /// A row like the design's list buttons: a title and subtitle on the left, a value and › on the right.
    private func listRow(_ title: String, _ subtitle: String, value: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline)
                    Text(subtitle).font(.note).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text("\(value) \(Image(systemName: "chevron.right"))").font(.subheadline)
            }
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            rule
        }
        .foregroundStyle(Color.ink, Color.muted)
        .contentShape(.rect)
    }

    private var rule: some View { Rectangle().fill(Color.line).frame(height: 1) }

    /// Money out as "$48.00", money in as "+$2,140.55".
    private func amountText(_ amount: Double) -> String {
        amount < 0 ? (-amount).formatted(.currency(code: "USD").sign(strategy: .always())) : amount.formatted(.currency(code: "USD"))
    }

    private func reload() {
        do {
            detail = try TransactionDetail.load(id, in: database)
            guard let detail else { return }
            // Only a purchase is compared; a paycheck or a transfer isn't a "visit".
            context = detail.kind == "spending" && detail.merchant_id != nil
                ? StoreContext.compare(detail.amount, earlier: try detail.earlierCharges(in: database)) : nil
            let found = try database.dbQueue.read { db in
                try String.fetchAll(db, sql: "SELECT name FROM entities WHERE kind = 'category'")
            }
            categories = Set(found + ["other", detail.category]).sorted { SpendingView.title($0) < SpendingView.title($1) }
            history = try detail.merchant_id.map { try ListedTransaction.all(in: database, merchant: $0) } ?? []
        } catch {
            print("Could not read the transaction:", error)
        }
    }

    /// Saves the answer at once, then swaps the buttons for the saved bar and its countdown.
    private func setFamiliar(_ answer: Answers.Familiar) {
        save { try Answers.setFamiliar(answer, transaction: id, in: database) }
        // Only a saved answer counts down; if saving failed, the buttons stay.
        guard detail?.familiar == answer.rawValue else { return }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .easeOut(duration: 0.3)) { countdown = 4 }
    }

    /// Undo on the saved bar: the answer goes back to empty and the buttons come back.
    private func undoFamiliar() {
        save { try Answers.setFamiliar(nil, transaction: id, in: database) }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .easeOut(duration: 0.3)) { countdown = nil }
    }

    private func setCategory(_ category: String) {
        save { try Answers.setCategory(category == detail?.store_category ? nil : category, transaction: id, in: database) }
    }

    /// Saves one answer through #76's functions, then shows the saved state.
    private func save(_ write: () throws -> Void) {
        do {
            try write()
        } catch {
            print("Could not save the answer:", error)
        }
        reload()
    }
}

/// "Checking •• 4821", or for VoiceOver "Checking ending in 4821", which it reads more clearly.
func accountTitle(_ name: String, _ mask: String?, spoken: Bool = false) -> String {
    guard let mask else { return name }
    return spoken ? "\(name) ending in \(mask)" : "\(name) •• \(mask)"
}

/// One of the design's side-by-side answer buttons. The chosen answer is filled with the accent;
/// with no answer yet, the first button is filled as the suggested one, as in the design.
struct AnswerButton: View {
    let title: String
    let chosen: Bool
    let filled: Bool
    let action: () -> Void

    init(_ title: String, chosen: Bool, filled: Bool? = nil, action: @escaping () -> Void) {
        self.title = title
        self.chosen = chosen
        self.filled = filled ?? chosen
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.row)
                // On the accent fill, the color made to sit on it.
                .foregroundStyle(filled ? Color.contrast : Color.accent)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, 4)
                .background(filled ? Color.accent : Color.surface, in: .rect(cornerRadius: 10))
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // VoiceOver hears "Selected" only for a saved answer, not for the suggested one.
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// Answer buttons side by side, or stacked at the largest text sizes so no answer is squeezed
/// to a few letters per line.
struct AnswerStack<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
        layout { content }
    }
}

#Preview {
    // Maya's first transaction, from her fake data.
    NavigationStack {
        TransactionDetailView(database: try! .open("maya"), id: "maya-0001")
    }
}
