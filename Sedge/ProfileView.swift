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
/// the transactions behind each fact. Tapping a fact corrects it; the correction is saved in
/// the open database and always wins over what was worked out.
struct ProfileView: View {
    let database: SedgeDatabase
    @State private var facts: [Profile.Fact] = []
    /// Every transaction's date by id, to say when a fact's evidence starts and ends.
    @State private var dates: [String: String] = [:]
    @State private var editing: Profile.Fact?

    /// Section titles for the kinds `Profile` knows; anything else shows its raw kind.
    static let titles = ["income": "Income", "housing": "Housing", "tuition": "Tuition", "loan": "Loans", "account": "Accounts"]

    /// The kinds in the order `Profile.facts` sorted them.
    private var kinds: [String] {
        facts.map(\.kind).reduce(into: []) { kinds, kind in if !kinds.contains(kind) { kinds.append(kind) } }
    }

    var body: some View {
        List {
            ForEach(kinds, id: \.self) { kind in
                Section {
                    ForEach(facts.filter { $0.kind == kind }) { fact in
                        Button { editing = fact } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(fact.value.name)
                                Text(Self.details(fact.value))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text(evidence(fact))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                        .accessibilityHint("Correct this fact")
                    }
                } header: {
                    Text(Self.titles[kind] ?? kind)
                } footer: {
                    // The rows don't look like buttons, so the first section says they are.
                    if kind == kinds.first { Text("Tap a fact to correct it.") }
                }
            }
        }
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
                reload()
            }
        }
        .task { reload() }
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
