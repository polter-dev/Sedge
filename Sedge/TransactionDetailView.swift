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
    /// The account's name as the app shows it: the person's own name, or the bank's.
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
                       t.kind, t.merchant_id, COALESCE(a.nickname, a.name) AS account, a.mask, c.name AS store_category,
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
    /// "Higher than your last three visits.", "Lower …" or "In line …".
    let headline: String
    /// "Those were $8.00–$14.00."
    let range: String

    /// `earlier` is the store's earlier purchase amounts, newest first (only the first three count).
    /// Nil with fewer than three, since there is nothing to compare; the screen then leaves the block out.
    static func compare(_ amount: Double, earlier: [Double]) -> StoreContext? {
        guard earlier.count >= 3 else { return nil }
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
/// Opened from the transactions list and a category's page on Trends.
struct TransactionDetailView: View {
    let database: SedgeDatabase
    let id: String
    @State private var detail: TransactionDetail?
    @State private var context: StoreContext?
    /// The organizer's categories found in this data, offered when changing the category.
    @State private var categories: [String] = []
    /// The store's transactions, for Merchant history.
    @State private var history: [ListedTransaction] = []
    /// The design's 16 pt icon, growing with the text beside it.
    @ScaledMetric(relativeTo: .caption) private var sproutSize: CGFloat = 16
    /// The familiar prompt's countdown, 4 down to 0, while the track shows under the buttons; nil hides it.
    @State private var countdown: Int?
    /// The part of the track still full, 1 down to 0. Each tick sets it from the number, so the
    /// track can't run ahead of the countdown, even after the countdown paused for Merchant history.
    @State private var remaining = 1.0
    /// True once the countdown has shown 0: the prompt is folded away until the screen is opened again.
    @State private var folded = false
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
        // One tick a second: 4, 3, 2, 1, 0. Each tick changes `countdown`, which starts the next one;
        // Undo sets it to nil, which cancels the tick in progress.
        .task(id: countdown) {
            guard let count = countdown else { return }
            // The track drains a quarter over this tick's second, ending where the next number starts.
            // With Reduce Motion it follows the number instead, a step a second.
            if reduceMotion {
                remaining = Double(count) / 4
            } else {
                withAnimation(.linear(duration: 1)) { remaining = Double(max(count - 1, 0)) / 4 }
            }
            // The countdown holds 0 for 0.3 s, so it's seen, before the prompt folds away.
            guard (try? await Task.sleep(for: .seconds(count > 0 ? 1 : 0.3))) != nil else { return }
            // With Reduce Motion the number just changes and the prompt is removed without
            // sliding the rest up.
            if count > 0 {
                withAnimation(reduceMotion ? nil : .default) { countdown = count - 1 }
            } else {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { folded = true }
            }
        }
    }

    private func content(_ detail: TransactionDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(detail.pending ? "Pending" : "Posted") · \(detail.date.displayDate())")
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

            if !folded {
                Text("Does this look familiar?")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                // The buttons stay while the countdown runs, the chosen one filled.
                AnswerStack {
                    AnswerButton("Yes", chosen: detail.familiar == "yes", filled: detail.familiar != "not_sure") { setFamiliar(.yes) }
                    AnswerButton("Not sure", chosen: detail.familiar == "not_sure") { setFamiliar(.notSure) }
                }
                .padding(.top, 10)
                if let countdown {
                    savedTrack(countdown: countdown)
                        .padding(.top, 8)
                        .transition(.opacity)
                }
                rule.padding(.vertical, 17)
            }

            Menu {
                // Choosing the store's own category clears the answer, so the data stays as the organizer left it.
                Picker("Category", selection: Binding(get: { detail.category }, set: setCategory)) {
                    ForEach(categories, id: \.self) { Text(SpendingView.title($0)) }
                }
            } label: {
                listRow("Category", nil, value: SpendingView.title(detail.category))
            }
            .accessibilityLabel("Category")
            .accessibilityValue(SpendingView.title(detail.category))
            if detail.merchant_id != nil {
                NavigationLink {
                    MerchantHistoryView(rows: history, database: database)
                        .navigationTitle(detail.store)
                } label: {
                    // Counts what the history lists: its purchases, or every row at a store with none.
                    let purchases = MerchantHistoryView.purchases(history)
                    listRow("Merchant history", MerchantHistoryView.count(purchases.isEmpty ? history.count : purchases.count, visits: !purchases.isEmpty),
                            value: "View")
                }
            }

            Text("Bank description: \(detail.name)")
                .font(.note)
                .foregroundStyle(.secondary)
                .padding(.top, 18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The comparison with the store's earlier visits.
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
            Text(context.range)
                .font(.row)
                .foregroundStyle(.secondary)
                .padding(.top, 14)
        }
    }

    /// The 4 pt track that drains under the answer buttons, with "Saved. Closing in 3" and Undo.
    private func savedTrack(countdown: Int) -> some View {
        let text = Text("Saved. Closing in \(countdown)")
            .font(.row)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .contentTransition(.numericText(countsDown: true))
            .frame(maxWidth: .infinity, alignment: .leading)
        // The design puts Undo's word flush with the right edge; its 44 pt target may reach past it.
        let undo = undoButton(undoFamiliar).padding(.trailing, -8)
        return VStack(spacing: 0) {
            track(remaining)
            // At the largest text sizes Undo drops under the text instead of squeezing it.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) { text; undo }
                VStack(alignment: .leading, spacing: 0) { text.padding(.top, 12); undo }
            }
            .frame(minHeight: 44)
        }
    }

    /// The 4 pt track, `full` of it in the accent color. The accent part is squeezed from the right,
    /// so it shrinks toward the leading edge.
    private func track(_ full: Double) -> some View {
        Rectangle().fill(Color.accent)
            .scaleEffect(x: full, anchor: .leading)
            .background(Color.line)
            .frame(height: 4)
            .clipShape(.rect(cornerRadius: 2))
            .accessibilityHidden(true)
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

    /// A row like the design's list buttons: a title and optional subtitle on the left, a value and › on the right.
    private func listRow(_ title: String, _ subtitle: String?, value: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline)
                    if let subtitle { Text(subtitle).font(.note).foregroundStyle(.secondary) }
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

    /// Saves the answer at once, then shows the draining track and its countdown under the buttons.
    private func setFamiliar(_ answer: Answers.Familiar) {
        save { try Answers.setFamiliar(answer, transaction: id, in: database) }
        // Only a saved answer counts down; if saving failed, nothing changes. Switching answers
        // while it counts saves the new one and keeps the countdown going.
        guard detail?.familiar == answer.rawValue, countdown == nil else { return }
        // The track appears full; the countdown's first tick starts it draining.
        remaining = 1
        // With Reduce Motion the track just appears, without sliding the rest down.
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { countdown = 4 }
    }

    /// Undo under the buttons: the answer goes back to empty and the track goes away.
    private func undoFamiliar() {
        save { try Answers.setFamiliar(nil, transaction: id, in: database) }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { countdown = nil }
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

/// One of the side-by-side answer buttons, in the same look as the account check's answers: the
/// chosen answer is filled with the accent, the other is outlined in it. With no answer yet, the
/// first button is filled as the suggested one.
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
                .font(.answer.weight(.medium))
                // On the accent fill, the color made to sit on it.
                .foregroundStyle(filled ? Color.contrast : Color.accent)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, 4)
                .background(filled ? Color.accent : Color.background, in: .rect(cornerRadius: 10))
                .overlay {
                    if !filled { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accent, lineWidth: 1.5) }
                }
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
