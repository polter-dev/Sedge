//
//  ProfileView.swift
//  Sedge
//

import GRDB
import SedgeCore
import SwiftUI

// A fact's `id` is already unique, so a fact can drive `.sheet(item:)` directly.
extension Profile.Fact: @retroactive Identifiable {}

/// What the app worked out about the person (income, rent, tuition, loans, accounts), with
/// the transactions behind each fact, as a grid of tiles whose size says how much each matters.
/// Tapping a tile corrects its fact; the correction is saved in the open database and always
/// wins over what was worked out.
struct ProfileView: View {
    let database: SedgeDatabase
    @State private var facts: [Profile.Fact] = []
    /// Every transaction's date by id, to say when a fact's evidence starts and ends.
    @State private var dates: [String: String] = [:]
    @State private var editing: Profile.Fact?
    /// False until the first load, so the tiles fade in once.
    @State private var shown = false
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Grows the tiles' symbols with the reader's text size.
    @ScaledMetric(relativeTo: .caption2) private var glyphScale = 1.0

    /// Section titles for the kinds `Profile` knows; anything else shows its raw kind.
    static let titles = ["income": "Income", "housing": "Housing", "tuition": "Tuition", "loan": "Loans", "account": "Accounts"]

    // The four groups of tiles, top to bottom. Tuition and any kind `Profile` adds later are wide strips.
    private var income: [Profile.Fact] { facts.filter { $0.kind == "income" } }
    private var pair: [Profile.Fact] { facts.filter { $0.kind == "housing" || $0.kind == "loan" } }
    private var strips: [Profile.Fact] { facts.filter { !["income", "housing", "loan", "account"].contains($0.kind) } }
    private var accounts: [Profile.Fact] { facts.filter { $0.kind == "account" } }

    var body: some View {
        // At the largest text sizes every tile is full width, so nothing has to squeeze.
        let oneColumn = textSize.isAccessibilitySize
        ScrollView {
            if !facts.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("What Sedge worked out from this data. Tap any tile to correct it.")
                        .font(.footnote)
                        .foregroundStyle(Color.muted)
                    ForEach(income) { fact in tile(fact) { card(fact, hero: true) } }
                    grid(pair, columns: oneColumn ? 1 : 2, span: true) { fact in tile(fact) { card(fact) } }
                    ForEach(strips) { fact in
                        tile(fact) { if oneColumn { card(fact) } else { strip(fact) } }
                    }
                    grid(accounts, columns: oneColumn ? 1 : 4, span: false) { fact in
                        tile(fact) { if oneColumn { card(fact) } else { square(fact) } }
                    }
                    Text("Accounts come from your bank's list. Corrections always win over what Sedge worked out.")
                        .font(.note)
                        .foregroundStyle(Color.muted)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
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
        .task {
            reload()
            shown = true
        }
    }

    /// One tappable tile: its content on the group color, the whole rounded shape as the tap
    /// target, read by VoiceOver as one button with the fact's full text.
    private func tile(_ fact: Profile.Fact, @ViewBuilder _ content: () -> some View) -> some View {
        // Tiles rise in one after another in reading order; with Reduce Motion they only fade.
        let order = (income + pair + strips + accounts).firstIndex(of: fact) ?? 0
        return Button { editing = fact } label: {
            content()
                .background(Color.group, in: .rect(cornerRadius: 16))
                .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(TileStyle())
        .accessibilityLabel([Self.titles[fact.kind] ?? fact.kind, fact.value.name, Self.details(fact.value), evidence(fact)]
            .filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityHint("Correct this fact")
        .opacity(shown ? 1 : 0)
        .offset(y: shown || reduceMotion ? 0 : 8)
        .animation(reduceMotion ? .easeInOut(duration: 0.2)
                   : .spring(response: 0.35, dampingFraction: 0.85).delay(Double(order) * 0.04), value: shown)
    }

    /// `items` in rows of `columns` tiles of one width and one height. A short last row is
    /// filled with blanks, so squares stay squares, or with `span` its lone tile takes the
    /// whole row (housing without a loan).
    private func grid<Tile: View>(_ items: [Profile.Fact], columns: Int, span: Bool,
                                  tile: @escaping (Profile.Fact) -> Tile) -> some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            ForEach(Array(stride(from: 0, to: items.count, by: columns)), id: \.self) { start in
                let row = items[start..<min(start + columns, items.count)]
                GridRow {
                    ForEach(row) { fact in tile(fact).gridCellColumns(span && row.count == 1 ? columns : 1) }
                    if !span {
                        ForEach(row.count..<columns, id: \.self) { _ in Color.clear.gridCellUnsizedAxes(.vertical) }
                    }
                }
            }
        }
    }

    /// A tile's top line: the kind's glyph and name, and the pencil that says it can be corrected.
    private func head(_ fact: Profile.Fact, pencil: Bool = true) -> some View {
        HStack(spacing: 6) {
            glyph(Self.symbol(fact))
            Text(Self.titles[fact.kind] ?? fact.kind).font(.note.weight(.semibold)).textCase(.uppercase).tracking(0.44)
            Spacer(minLength: 0)
            if pencil { glyph("pencil") }
        }
        .foregroundStyle(Color.muted)
    }

    /// An SF Symbol in a square box `size` points wide (at the default text size), so a tall
    /// symbol like the house makes its row no taller than a flat one like the banknote.
    private func glyph(_ name: String, size: Double = 14) -> some View {
        Image(systemName: name)
            .resizable()
            .scaledToFit()
            // Capped at double size, so at the largest text sizes the glyphs leave room for the words.
            .frame(width: size * min(glyphScale, 2), height: size * min(glyphScale, 2))
    }

    /// The big dollar figure. It shrinks rather than wraps, so a long amount stays on one line.
    private func figure(_ text: String, hero: Bool = false) -> some View {
        Text(text)
            .font(hero ? .heroValue : .bigValue)
            .foregroundStyle(Color.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .contentTransition(.opacity)
    }

    /// The fact's evidence line, if it has one (a fact with no dated transactions has none).
    @ViewBuilder private func evidenceLine(_ fact: Profile.Fact) -> some View {
        let text = evidence(fact)
        if !text.isEmpty { Text(text).font(.note).foregroundStyle(Color.muted).contentTransition(.opacity) }
    }

    /// The tall tile: income (the hero), housing and loans, and every tile at the largest text sizes.
    private func card(_ fact: Profile.Fact, hero: Bool = false) -> some View {
        let (amount, rest) = Self.split(fact.value)
        return VStack(alignment: .leading, spacing: 4) {
            head(fact)
            Text(fact.value.name).font(.cardTitle).foregroundStyle(Color.ink)
            if let amount { figure(amount, hero: hero) }
            if !rest.isEmpty { Text(rest).font(.row).foregroundStyle(Color.muted).contentTransition(.opacity) }
            evidenceLine(fact)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// The wide, short tile for tuition: name and evidence on the left, the figure on the right.
    private func strip(_ fact: Profile.Fact) -> some View {
        let (amount, rest) = Self.split(fact.value)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                head(fact, pencil: false)
                Text(fact.value.name).font(.cardTitle).foregroundStyle(Color.ink)
                evidenceLine(fact)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 2) {
                if let amount { figure(amount) }
                if !rest.isEmpty {
                    Text(rest).font(.note).foregroundStyle(Color.muted).multilineTextAlignment(.trailing).contentTransition(.opacity)
                }
            }
            glyph("pencil").foregroundStyle(Color.muted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// The small square for an account: glyph, name and type. The note under the grid says the
    /// list came from the bank, so only a corrected account shows its evidence line.
    private func square(_ fact: Profile.Fact) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .top) {
                glyph(Self.symbol(fact), size: 16)
                Spacer(minLength: 0)
                glyph("pencil", size: 12)
            }
            .foregroundStyle(Color.muted)
            Spacer(minLength: 12)
            Text(fact.value.name).font(.row.weight(.semibold)).foregroundStyle(Color.ink)
            Text(Self.details(fact.value)).font(.note).foregroundStyle(Color.muted)
            if fact.rule != "account_list" { evidenceLine(fact) }
        }
        // 82 pt tall with the padding: the design's square, and well over the 44 pt tap minimum.
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
        .padding(10)
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

    /// A tile's big figure (the amount, e.g. "$1,850.00") and the rest of `details` without it,
    /// e.g. "mortgage · monthly · on day 1". The figure is nil when the fact has no amount (accounts).
    static func split(_ value: Profile.Value) -> (amount: String?, rest: String) {
        var rest = value
        rest.amount = nil
        return (value.amount?.formatted(.currency(code: "USD")), details(rest))
    }

    private func reload() {
        do {
            facts = try Profile.facts(in: database)
            dates = try database.dbQueue.read { db in
                try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: "SELECT transaction_id, date FROM transactions")
                    .map { ($0[0] as String, $0[1] as String) })
            }
        } catch {
            print("Could not read the profile:", error)
        }
    }

    /// The fact's numbers in one line, e.g. "$1,850.00 · monthly · on day 1".
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

    /// Where the fact came from, e.g. "Based on 6 deposits from Jan 2, 2026 to Jun 26, 2026."
    private func evidence(_ fact: Profile.Fact) -> String {
        switch fact.rule {
        case "user_correction": return "You set this."
        case "account_list": return "From your bank's list of accounts."
        default:
            let found = fact.evidence.compactMap { dates[$0] }.sorted()
            guard let first = found.first, let last = found.last else { return "" }
            let noun = fact.kind == "income" ? "deposit" : "payment"
            return "Based on \(found.count) \(noun)\(found.count == 1 ? "" : "s") from \(first.displayDate()) to \(last.displayDate())."
        }
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
