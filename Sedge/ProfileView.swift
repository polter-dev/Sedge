//
//  ProfileView.swift
//  Sedge
//

import GRDB
import SedgeCore
import SwiftUI

// A fact's `id` is already unique, so a fact can drive `.sheet(item:)` directly.
extension Profile.Fact: @retroactive Identifiable {}

/// What the app worked out about the person (income, rent, tuition, loans, accounts) as a
/// mosaic of tiles colored by kind. Tapping a tile corrects its fact; the correction is saved in
/// the open database and always wins over what was worked out.
struct ProfileView: View {
    let database: SedgeDatabase
    @State private var facts: [Profile.Fact] = []
    /// When each income, housing and loan fact is next due, by fact id, as "YYYY-MM-DD".
    @State private var next: [String: String] = [:]
    @State private var editing: Profile.Fact?
    /// False until the mosaic first appears, so the tiles fade in once.
    @State private var shown = false
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Grows the tiles' symbols with the reader's text size.
    @ScaledMetric(relativeTo: .caption2) private var glyphScale = 1.0
    /// The narrow column beside income (loans and tuition): the design's 112 pt, grown with the text.
    @ScaledMetric(relativeTo: .caption) private var sideWidth = 112.0

    /// Tile labels for the kinds `Profile` knows; anything else shows its raw kind.
    static let titles = ["income": "Income", "housing": "Housing", "tuition": "Tuition", "loan": "Loans", "account": "Accounts"]

    // The mosaic's parts, top to bottom: income with loans, tuition and any kind `Profile` adds
    // later in a column beside it, then housing, then the accounts.
    private var income: [Profile.Fact] { facts.filter { $0.kind == "income" } }
    private var side: [Profile.Fact] { facts.filter { !["income", "housing", "account"].contains($0.kind) } }
    private var housing: [Profile.Fact] { facts.filter { $0.kind == "housing" } }
    private var accounts: [Profile.Fact] { facts.filter { $0.kind == "account" } }

    var body: some View {
        // At the largest text sizes everything is one column, so nothing has to squeeze.
        let oneColumn = textSize.isAccessibilitySize
        ScrollView {
            if !facts.isEmpty {
                VStack(alignment: .leading, spacing: 11) {
                    Text("What Sedge learned about you")
                        .font(.footnote)
                        .foregroundStyle(Color.muted)
                    // Either column fills the row alone when the other has nothing to show.
                    Self.row(oneColumn, spacing: 11, alignment: .top) {
                        if !income.isEmpty {
                            VStack(spacing: 11) { ForEach(income) { fact in tile(fact) { incomeTile(fact) } } }
                        }
                        if !side.isEmpty {
                            VStack(spacing: 11) { ForEach(side) { fact in tile(fact) { sideTile(fact) } } }
                                .frame(width: oneColumn || income.isEmpty ? nil : sideWidth)
                        }
                    }
                    // Lets the income tile and the column beside it stretch to the taller one's height.
                    .fixedSize(horizontal: false, vertical: true)
                    ForEach(housing) { fact in tile(fact) { housingTile(fact, oneColumn: oneColumn) } }
                    if !accounts.isEmpty { accountsStrip(oneColumn: oneColumn) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                // Flipped here, after the tiles exist at opacity 0, so their animation sees the change.
                // Setting it in the same update that loads the facts would build them already shown.
                .onAppear { shown = true }
            }
        }
        .themedBackground()
        .overlay {
            if facts.isEmpty { ContentUnavailableView("Nothing learned yet", systemImage: "person.text.rectangle", description: Text("No paychecks, rent, tuition, loans or accounts were found in this data.")) }
        }
        .sheet(item: $editing) { fact in
            CorrectFactView(fact: fact) { value in
                do {
                    try Profile.correct(id: fact.id, kind: fact.kind, value: value, in: database)
                } catch {
                    print("Could not save the correction:", error)
                }
                // The changed tile's text cross-fades to the new value.
                withAnimation(.easeInOut(duration: reduceMotion ? 0.2 : 0.25)) { reload() }
            }
        }
        .task { reload() }
    }

    /// Side by side, or stacked at the largest text sizes.
    private static func row(_ oneColumn: Bool, spacing: Double, alignment: VerticalAlignment = .center,
                            @ViewBuilder _ content: () -> some View) -> some View {
        let layout = oneColumn ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: alignment, spacing: spacing))
        return layout(content)
    }

    /// One tappable tile: its content on `fill`, the whole rounded shape as the tap target, read
    /// by VoiceOver as one button with everything the tile shows.
    private func tile(_ fact: Profile.Fact, fill: Color? = nil, radius: Double = 18,
                      @ViewBuilder _ content: () -> some View) -> some View {
        // Tiles rise in one after another in reading order; with Reduce Motion they only fade.
        let order = facts.firstIndex(of: fact) ?? 0
        return Button { editing = fact } label: {
            content()
                .background(fill ?? Self.fill(fact.kind), in: .rect(cornerRadius: radius))
                .contentShape(.rect(cornerRadius: radius))
        }
        .buttonStyle(TileStyle())
        .accessibilityLabel(Self.spoken(fact, next: next))
        .accessibilityHint("Correct this fact")
        .opacity(shown ? 1 : 0)
        .offset(y: shown || reduceMotion ? 0 : 8)
        .animation(reduceMotion ? .easeInOut(duration: 0.2)
                   : .spring(response: 0.35, dampingFraction: 0.85).delay(Double(order) * 0.04), value: shown)
    }

    /// Income: the biggest tile, with its glyph on top and the figure, line and chip at the bottom.
    private func incomeTile(_ fact: Profile.Fact) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            badge(Self.symbol(fact), size: 28, glyph: 16)
            VStack(alignment: .leading, spacing: 6) {
                label(fact.kind)
                if let figure = Self.figure(fact) { amount(figure, font: .heroValue) }
                if let line = Self.subtext(fact) { Text(line).font(.row).foregroundStyle(Color.ink).contentTransition(.opacity) }
                chip(Self.chip(fact, next: next))
            }
            // Sits at the bottom when the column beside makes the tile taller.
            .frame(maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
    }

    /// Loans, tuition and any other kind, laid out like income in a narrower column: the glyph on
    /// top, then the label, figure and chip at the bottom, so the tile fills the column's height.
    private func sideTile(_ fact: Profile.Fact) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            badge(Self.symbol(fact), size: 22, glyph: 13)
            VStack(alignment: .leading, spacing: 6) {
                label(fact.kind)
                if let refund = Self.refund(fact.value) {
                    // Money back in green, what was paid in red.
                    Text(refund.back).foregroundStyle(Color.moneyBack)
                    Text(refund.spent).foregroundStyle(Color.moneySpent)
                } else if let figure = Self.figure(fact) {
                    VStack(alignment: .leading, spacing: 0) {
                        amount(figure, font: .tileValue)
                        if fact.kind == "tuition" { Text("spent").font(.note).foregroundStyle(Color.muted) }
                    }
                }
                chip(Self.chip(fact, next: next))
            }
            .frame(maxHeight: .infinity, alignment: .bottomLeading)
        }
        .font(.row.weight(.semibold))
        .contentTransition(.opacity)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
    }

    /// Housing: a wide tile with its glyph, label and figure in a row and the chip on the right.
    private func housingTile(_ fact: Profile.Fact, oneColumn: Bool) -> some View {
        Self.row(oneColumn, spacing: 12) {
            badge(Self.symbol(fact), size: 36, glyph: 21)
            VStack(alignment: .leading, spacing: 1) {
                label(fact.kind)
                if let figure = Self.figure(fact) { amount(figure, font: .tileValue) }
            }
            if !oneColumn { Spacer(minLength: 0) }
            chip(Self.chip(fact, next: next))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    /// Every account in one strip, each a small tile filled with its type's color.
    private func accountsStrip(oneColumn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Self.row(oneColumn, spacing: 8) {
                HStack(spacing: 8) {
                    badge("building.columns", size: 22, glyph: 13)
                    label("account")
                }
                if !oneColumn { Spacer(minLength: 0) }
                Text("What's connected").font(.note).foregroundStyle(Color.muted)
            }
            grid(accounts, columns: oneColumn ? 1 : 2) { fact in
                tile(fact, fill: .account(fact.value.type), radius: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        glyph(Self.symbol(fact), size: 16)
                        Text(fact.value.name).font(.row.weight(.semibold)).contentTransition(.opacity)
                    }
                    .foregroundStyle(Color.onAccount)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(12)
                }
            }
        }
        .padding(12)
        .background(Color.tileAccounts, in: .rect(cornerRadius: 18))
    }

    /// `items` in rows of `columns` tiles of one width and one height. A short last row is
    /// filled with blanks, so a lone account stays the width of the others.
    private func grid<Tile: View>(_ items: [Profile.Fact], columns: Int,
                                  tile: @escaping (Profile.Fact) -> Tile) -> some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(Array(stride(from: 0, to: items.count, by: columns)), id: \.self) { start in
                GridRow {
                    ForEach(items[start..<min(start + columns, items.count)]) { fact in tile(fact) }
                    ForEach(min(start + columns, items.count) - start..<columns, id: \.self) { _ in
                        Color.clear.gridCellUnsizedAxes(.vertical)
                    }
                }
            }
        }
    }

    /// A tile's label, e.g. "LOANS".
    private func label(_ kind: String) -> some View {
        Text(Self.titles[kind] ?? kind).font(.note.weight(.semibold)).textCase(.uppercase).tracking(0.44)
            .foregroundStyle(Color.muted)
    }

    /// A tile's big figure. It shrinks rather than wraps, so a long amount stays on one line.
    private func amount(_ text: String, font: Font) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(Color.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .contentTransition(.opacity)
    }

    /// The tile's one chip, e.g. "Next Jul 1" or "Spring Term", when there is one.
    @ViewBuilder private func chip(_ text: String?) -> some View {
        if let text {
            Text(text)
                .font(.note.weight(.semibold))
                .foregroundStyle(Color.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.background, in: .capsule)
        }
    }

    /// A glyph on a small round plate in the screen's color.
    private func badge(_ symbol: String, size: Double, glyph points: Double) -> some View {
        glyph(symbol, size: points)
            .foregroundStyle(Color.ink)
            .frame(width: size * min(glyphScale, 2), height: size * min(glyphScale, 2))
            .background(Color.background, in: .circle)
    }

    /// An SF Symbol in a square box `size` points wide (at the default text size), so a tall
    /// symbol like the house makes its row no taller than a flat one like the banknote.
    private func glyph(_ name: String, size: Double) -> some View {
        Image(systemName: name)
            .resizable()
            .scaledToFit()
            // Capped at double size, so at the largest text sizes the glyphs leave room for the words.
            .frame(width: size * min(glyphScale, 2), height: size * min(glyphScale, 2))
    }

    /// The SF Symbol on a fact's tile; an account's depends on its type.
    private static func symbol(_ fact: Profile.Fact) -> String {
        switch fact.kind {
        case "income": "dollarsign"
        case "housing": "house"
        case "loan": "banknote"
        case "tuition": "graduationcap"
        case "account":
            fact.value.type?.contains("credit") == true ? "creditcard"
                : fact.value.type == "savings" ? "dollarsign.circle" : "building.columns"
        default: "person.text.rectangle"
        }
    }

    /// A tile's color by kind; a kind `Profile` adds later gets the plain card color.
    private static func fill(_ kind: String) -> Color {
        switch kind {
        case "income": .tileIncome
        case "housing": .tileHousing
        case "loan": .tileLoan
        case "tuition": .tileTuition
        default: .group
        }
    }

    // MARK: - What the tiles say

    // Worked out from the fact alone, so a test can check every one against the profile.

    /// How often a payment comes, after its amount.
    static let per = ["weekly": "a week", "biweekly": "every two weeks", "twice_monthly": "twice a month", "monthly": "a month"]

    static func money(_ dollars: Double) -> String { dollars.formatted(.currency(code: "USD")) }

    /// A tile's big figure. Housing says how often (twice-monthly rent shows its monthly cost);
    /// tuition shows everything paid, unless money came back (then `refund` shows both).
    static func figure(_ fact: Profile.Fact) -> String? {
        let value = fact.value
        switch fact.kind {
        case "housing":
            if let monthly = value.monthly_average { return money(monthly) + " a month" }
            return value.amount.map { [money($0), per[value.schedule ?? ""]].compactMap { $0 }.joined(separator: " ") }
        case "tuition":
            return refund(value) == nil ? (value.paid ?? value.amount).map(money) : nil
        default:
            return value.amount.map(money)
        }
    }

    /// Income's line under its figure, e.g. "Every two weeks from Bean Street Coffee, about
    /// $1,126.67 a month". The monthly figure is left out when it is the paycheck itself.
    static func subtext(_ fact: Profile.Fact) -> String? {
        guard fact.kind == "income" else { return nil }
        let value = fact.value
        let often = per[value.schedule ?? ""].map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "A typical deposit"
        var line = "\(often) from \(value.name)"
        if let average = value.monthly_average, average != value.amount { line += ", about \(money(average)) a month" }
        return line
    }

    /// Tuition with money back: "+$X back" and "−$Y spent", where spent is everything paid (a
    /// refund never erases a payment). Nil when nothing came back.
    static func refund(_ value: Profile.Value) -> (back: String, spent: String)? {
        guard let back = value.refunded, back > 0, let paid = value.paid else { return nil }
        return ("+" + money(back) + " back", "−" + money(paid) + " spent")
    }

    /// The school term a tuition payment on `date` ("YYYY-MM-DD") is for: Jan–May is spring,
    /// Jun–Jul summer, Aug–Dec fall.
    static func term(_ date: String) -> String? {
        guard let month = Int(date.dropFirst(5).prefix(2)), (1...12).contains(month) else { return nil }
        return month <= 5 ? "Spring Term" : month <= 7 ? "Summer Term" : "Fall Term"
    }

    /// The tile's chip: when an income, housing or loan fact is next due, or the term of
    /// tuition's last payment. Nil when the data doesn't say.
    static func chip(_ fact: Profile.Fact, next: [String: String]) -> String? {
        if fact.kind == "tuition" { return fact.value.payments?.last.flatMap { term($0.date) } }
        return next[fact.id].map { "Next " + $0.displayDate(.dateTime.month(.abbreviated).day()) }
    }

    /// What VoiceOver reads for a tile: its label, name and type, then everything the tile shows.
    static func spoken(_ fact: Profile.Fact, next: [String: String]) -> String {
        let refund = refund(fact.value), figure = figure(fact)
        return [titles[fact.kind] ?? fact.kind,
                fact.kind == "income" ? nil : fact.value.name, // income's line already names the payer
                fact.value.type, figure, subtext(fact), refund?.back, refund?.spent,
                fact.kind == "tuition" && figure != nil ? "spent" : nil,
                chip(fact, next: next)].compactMap { $0 }.joined(separator: ", ")
    }

    /// The facts in reading order (income, loans, tuition and other kinds, housing, accounts),
    /// so a fact's index is its place in the tiles' entrance, and each one's next due date.
    static func load(_ database: SedgeDatabase) throws -> (facts: [Profile.Fact], next: [String: String]) {
        // The sort is stable, so each group keeps Profile's order.
        let row = ["income": 0, "loan": 1, "housing": 3, "account": 4]
        let facts = try Profile.facts(in: database).sorted { row[$0.kind, default: 2] < row[$1.kind, default: 2] }
        return (facts, try nextDates(facts, in: database))
    }

    /// When each income, housing and loan fact is next due, by fact id: the first day the
    /// simulator's own projection changes when that series is cancelled from tomorrow. So the date
    /// is the one Cash flow uses, counted from the dataset's today, and a series the simulator
    /// doesn't project (irregular, stopped, or renamed by a correction) gets none.
    /// shortcut: series are found by store name, as what-if changes are, so a store with both a
    /// bill and a deposit series gets the earlier of the two; match by kind if real data has one.
    static func nextDates(_ facts: [Profile.Fact], in database: SedgeDatabase) throws -> [String: String] {
        try database.dbQueue.read { db in
            // Two months: every cadence the simulator projects comes due again within one.
            let plain = try Simulator.simulate(db, days: 62)
            guard let tomorrow = plain.first?.date else { return [:] }
            var next: [String: String] = [:]
            for fact in facts where ["income", "housing", "loan"].contains(fact.kind) {
                let without = try Simulator.simulate(db, days: 62, changes: [.init(cancelling: fact.value.name, from: tomorrow)])
                next[fact.id] = zip(plain, without).first { $0.balances != $1.balances }?.0.date
            }
            return next
        }
    }

    private func reload() {
        do {
            (facts, next) = try Self.load(database)
        } catch {
            print("Could not read the profile:", error)
        }
    }

    /// The fact's numbers in one line, e.g. "$1,850.00 · monthly · on day 1". Saved answers lists
    /// corrections with it.
    static func details(_ value: Profile.Value) -> String {
        let dollars = FloatingPointFormatStyle<Double>.Currency(code: "USD")
        var parts: [String] = []
        if let type = value.type { parts.append(type) }
        if let amount = value.amount { parts.append(amount.formatted(dollars)) }
        if let schedule = value.schedule { parts.append(schedule) }
        if let day = value.day { parts.append("on day \(day)") }
        if let average = value.monthly_average { parts.append("about \(average.formatted(dollars)) a month") }
        if let paid = value.paid { parts.append("\(paid.formatted(dollars)) paid in all") }
        if let refunded = value.refunded { parts.append("\(refunded.formatted(dollars)) refunded") }
        return parts.joined(separator: " · ")
    }
}

/// A tile presses in slightly while touched, so the tap feels physical; Reduce Motion turns it off.
private struct TileStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Spelled out because GRDB, imported above, has its own `Configuration` type.
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A form for the person's own version of one fact. Only the fields the fact already has are shown.
struct CorrectFactView: View {
    let fact: Profile.Fact
    let save: (Profile.Value) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var value: Profile.Value
    // Numbers are edited as text, so a half-typed number never overwrites the saved one.
    @State private var amount: String
    @State private var day: String

    static let schedules = ["weekly", "biweekly", "twice_monthly", "monthly", "irregular"]

    init(fact: Profile.Fact, save: @escaping (Profile.Value) -> Void) {
        self.fact = fact
        self.save = save
        _value = State(initialValue: fact.value)
        // Written and read in the phone's own number format, so a comma decimal mark works too.
        _amount = State(initialValue: fact.value.amount.map { $0.formatted(.number.grouping(.never)) } ?? "")
        _day = State(initialValue: fact.value.day.map { String($0) } ?? "")
    }

    /// The edited value, or nil while a number field doesn't hold a valid number.
    private var corrected: Profile.Value? {
        var result = value
        if fact.value.amount != nil {
            guard let number = try? Double(amount, format: .number), number >= 0 else { return nil }
            result.amount = number
        }
        if fact.value.day != nil {
            guard let number = Int(day), (1...31).contains(number) else { return nil }
            result.day = number
        }
        return result.name.trimmingCharacters(in: .whitespaces).isEmpty ? nil : result
    }

    var body: some View {
        NavigationStack {
            Form {
                // One section, so the theme's row color can be set on every row at once.
                Section {
                    LabeledContent("Name") {
                        TextField("Name", text: $value.name).multilineTextAlignment(.trailing)
                    }
                    if fact.value.type != nil {
                        LabeledContent("Type") {
                            TextField("Type", text: Binding { value.type ?? "" } set: { value.type = $0 }).multilineTextAlignment(.trailing)
                        }
                    }
                    if fact.value.amount != nil {
                        LabeledContent("Amount ($)") {
                            TextField("Amount", text: $amount).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        }
                    }
                    if fact.value.schedule != nil {
                        Picker("Schedule", selection: Binding { value.schedule ?? "" } set: { value.schedule = $0 }) {
                            ForEach(Self.schedules, id: \.self) { Text($0) }
                        }
                    }
                    if fact.value.day != nil {
                        LabeledContent("Day of the month") {
                            TextField("Day", text: $day).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        }
                    }
                }
                .listRowBackground(Color.group)
            }
            .themedBackground()
            .navigationTitle("Correct this")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let corrected { save(corrected) }
                        dismiss()
                    }
                    .disabled(corrected == nil)
                }
            }
        }
    }
}

#Preview("What the app learned") {
    // Maya's fake data, loaded the same way the app loads it.
    NavigationStack {
        ProfileView(database: try! .open("maya"))
            .navigationTitle("What Sedge learned")
    }
}

#Preview("Correct a fact") {
    // Maya's first fact (her income), so every field it has shows in the form.
    CorrectFactView(fact: try! Profile.facts(in: .open("maya"))[0]) { print("Saved", $0) }
}
