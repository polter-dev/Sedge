//
//  WhatIfView.swift
//  Sedge
//

import Charts
import GRDB
import SedgeCore
import SwiftUI

/// The checking balance projected forward from the dataset's today, with and without one
/// extra purchase. The numbers come from the same `Simulator` the simulate_balance tool uses.
struct WhatIf {
    static let days = 30

    let account: String
    let accountName: String
    let without: [Simulator.Day]
    /// Nil when no extra purchase was entered.
    let with: [Simulator.Day]?
    /// Rent or mortgage payees from the profile, to "Rent" or "Mortgage", so that bill day stands out.
    let housing: [String: String]

    /// Projects the next 30 days, or returns nil when there is no bank account with a balance.
    /// `extra` is a purchase in dollars on `date` ("YYYY-MM-DD"; nil means tomorrow).
    static func load(_ database: SedgeDatabase, extra: Double?, on date: String?) throws -> WhatIf? {
        let housing = Dictionary(try Profile.facts(in: database).filter { $0.kind == "housing" }
            .map { ($0.value.name, ($0.value.type ?? "rent").capitalized) }) { first, _ in first }
        return try database.dbQueue.read { db in
            // The same account the simulate_balance tool picks, so this screen and the assistant agree.
            guard let checking = try Row.fetchOne(db, sql: """
                SELECT account_id, name FROM accounts
                WHERE type = 'depository' AND json_extract(balances, '$.current') IS NOT NULL
                ORDER BY subtype = 'checking' DESC, name LIMIT 1
                """) else { return nil }
            let account: String = checking[0]
            let without = try Simulator.simulate(db, days: days)
            var with: [Simulator.Day]?
            if let extra, extra > 0, let day = date ?? without.first?.date {
                with = try Simulator.simulate(db, days: days, purchases: [.init(amount: extra, date: day, account: account)])
            }
            return WhatIf(account: account, accountName: checking[1], without: without, with: with, housing: housing)
        }
    }

    /// The projection to show in the bill list: with the purchase when there is one.
    var shown: [Simulator.Day] { with ?? without }

    /// Days with a bill paid from the checking account. Bills on a card don't move this balance
    /// on their day; the card's payment does, and it is a bill here.
    var billDays: [Simulator.Day] {
        shown.filter { day in day.bills.contains { $0.account == account } }
    }

    /// "Rent" or "Mortgage" when that housing bill is paid on this day.
    func housingLabel(_ day: Simulator.Day) -> String? {
        day.bills.filter { $0.account == account }.compactMap { housing[$0.name] }.first
    }

    /// The lowest balance and its first day.
    func lowest(_ days: [Simulator.Day]) -> (date: String, balance: Double)? {
        days.map { (date: $0.date, balance: $0.balances[account] ?? 0) }.min { $0.balance < $1.balance }
    }
}

/// Try an extra purchase and see the next 30 days of the checking balance, with bill days marked.
struct WhatIfView: View {
    let database: SedgeDatabase
    /// Typed text, read as dollars, so the chart updates while typing.
    @State private var amountText = ""
    /// The purchase day; "" until the first projection says which days there are.
    @State private var date = ""
    @State private var result: WhatIf?
    @State private var loaded = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// A projected day for people, e.g. "Wed, Jul 1". The next 30 days need no year.
    private static func day(_ date: String) -> String {
        date.displayDate(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    /// Read in the phone's own number format, so "12,50" works where a comma is the decimal mark.
    private var amount: Double? { try? Double(amountText, format: .number) }

    var body: some View {
        Form {
            if let result {
                Section {
                    // A dollar sign in front, so a typed "1500" still reads as money.
                    HStack(spacing: 4) {
                        Text("$").foregroundStyle(.secondary).accessibilityHidden(true)
                        TextField("Extra purchase in dollars", text: $amountText)
                            .keyboardType(.decimalPad)
                    }
                    Picker("On", selection: $date) {
                        ForEach(result.without, id: \.date) { Text(Self.day($0.date)).tag($0.date) }
                    }
                } header: {
                    Text("Extra purchase")
                } footer: {
                    Text("\(result.accountName), projected from paychecks, bills, card payments and typical daily spending.")
                }
                Section("Next \(WhatIf.days) days") {
                    chart(result)
                        .frame(height: 240)
                    summary("Without the purchase", result.lowest(result.without))
                    if let with = result.with { summary("With the purchase", result.lowest(with)) }
                }
                Section("Bill days") {
                    ForEach(result.billDays, id: \.date) { day in
                        // Stacked at the largest text sizes, so the bill names keep the full width.
                        let stacked = dynamicTypeSize.isAccessibilitySize
                        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout())
                        layout {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.day(day.date))
                                Text(day.bills.filter { $0.account == result.account }.map(\.name).joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            if let label = result.housingLabel(day) {
                                // The icon sits inside the text, since a list lines up Label icons in their own column.
                                Text("\(Image(systemName: "house")) \(label)").font(.caption).foregroundStyle(.red)
                                    .accessibilityLabel(label)
                            }
                            Text(day.balances[result.account] ?? 0, format: .currency(code: "USD"))
                                .monospacedDigit()
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if result.billDays.isEmpty {
                        Text("No recurring bills are due from \(result.accountName) in the next \(WhatIf.days) days.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        // The number pad has no return key, so scrolling is the way to put it away and reach the tabs.
        .scrollDismissesKeyboard(.immediately)
        .overlay {
            if loaded && result == nil {
                ContentUnavailableView("No bank account", systemImage: "banknote", description: Text("A checking or savings balance is needed to project."))
            }
        }
        // Runs again whenever the amount or the day changes.
        .task(id: "\(amountText)|\(date)") {
            do {
                result = try WhatIf.load(database, extra: amount, on: date.isEmpty ? nil : date)
                if date.isEmpty, let first = result?.without.first?.date { date = first }
            } catch {
                print("Could not project:", error)
            }
            loaded = true
        }
    }

    private func chart(_ result: WhatIf) -> some View {
        let dates = result.without.map(\.date)
        return Chart {
            ForEach(result.without, id: \.date) { day in
                LineMark(x: .value("Day", day.date), y: .value("Balance", day.balances[result.account] ?? 0))
                    .foregroundStyle(by: .value("Projection", "Without purchase"))
            }
            if let with = result.with {
                ForEach(with, id: \.date) { day in
                    LineMark(x: .value("Day", day.date), y: .value("Balance", day.balances[result.account] ?? 0))
                        .foregroundStyle(by: .value("Projection", "With purchase"))
                }
            }
            // A thin line on every bill day, and a labeled red one on the rent or mortgage day.
            ForEach(result.billDays, id: \.date) { day in
                if let label = result.housingLabel(day) {
                    RuleMark(x: .value("Day", day.date))
                        .foregroundStyle(.red)
                        .annotation(position: .top, alignment: .leading) { Text(label).font(.caption2).foregroundStyle(.red) }
                } else {
                    RuleMark(x: .value("Day", day.date))
                        .foregroundStyle(.orange.opacity(0.4))
                }
            }
        }
        // The app's green for the balance as it is; blue for the purchase, apart from the
        // orange bill days and the red rent day.
        .chartForegroundStyleScale(["Without purchase": Color.accentColor, "With purchase": Color.blue])
        // With no purchase typed, a one-item legend says nothing.
        .chartLegend(result.with == nil ? .hidden : .visible)
        // 30 day labels don't fit, so only every 7th day is labeled ("Jul 8").
        .chartXAxis {
            AxisMarks { value in
                if let date = value.as(String.self), let index = dates.firstIndex(of: date), index % 7 == 0 {
                    AxisGridLine()
                    AxisValueLabel { Text(date.displayDate(.dateTime.month(.abbreviated).day())) }
                }
            }
        }
        // Whole dollars; cents only clutter the axis.
        .chartYAxis { AxisMarks(format: .currency(code: "USD").precision(.fractionLength(0))) }
    }

    private func summary(_ title: String, _ lowest: (date: String, balance: Double)?) -> some View {
        LabeledContent(title) {
            if let lowest {
                Text("Lowest \(lowest.balance.formatted(.currency(code: "USD"))) on \(Self.day(lowest.date))")
                    .monospacedDigit()
                    .foregroundStyle(lowest.balance < 0 ? .red : .secondary)
            }
        }
    }
}

#Preview {
    // Maya's fake data, loaded the same way the app loads it.
    NavigationStack {
        WhatIfView(database: try! .open("maya"))
            .navigationTitle("What if")
    }
}
