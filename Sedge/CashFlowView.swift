//
//  CashFlowView.swift
//  Sedge
//

import Charts
import GRDB
import SedgeCore
import SwiftUI

/// The checking balance projected forward from the dataset's today, as it stands and with the
/// scenarios that are switched on, and the likely range around it. Every number comes from the
/// same `Simulator` the simulate_balance tool uses.
struct CashFlow {
    static let days = 30

    let account: String
    let accountName: String
    /// The current plan: the projection with no scenarios.
    let without: [Simulator.Day]
    /// With the scenarios that are on; nil when none is.
    let with: [Simulator.Day]?
    /// The busiest and quietest spending around the shown line (`Simulator.range`).
    let range: (low: [Simulator.Day], high: [Simulator.Day])
    /// The person's recurring bills that come due in the projection, biggest first. The names are
    /// the store names recurring_charges uses, which a `Simulator.Change` matches on.
    let bills: [(name: String, isSubscription: Bool)]

    /// Projects `days` days, or returns nil when there is no bank account with a balance.
    /// Each purchase is in dollars on a "YYYY-MM-DD" day, from this checking account.
    static func load(_ database: SedgeDatabase, days: Int = days, purchases: [(amount: Double, date: String)] = [],
                     changes: [Simulator.Change] = []) throws -> CashFlow? {
        try database.dbQueue.read { db in
            // The same account the simulate_balance tool picks, so this screen and the assistant agree.
            guard let checking = try Row.fetchOne(db, sql: """
                SELECT account_id, name FROM accounts
                WHERE type = 'depository' AND json_extract(balances, '$.current') IS NOT NULL
                ORDER BY subtype = 'checking' DESC, name LIMIT 1
                """) else { return nil }
            let account: String = checking[0]
            let tried = purchases.map { Simulator.Purchase(amount: $0.amount, date: $0.date, account: account) }
            let without = try Simulator.simulate(db, days: days)
            let with = tried.isEmpty && changes.isEmpty ? nil
                : try Simulator.simulate(db, days: days, purchases: tried, changes: changes)
            let range = try Simulator.range(db, days: days, purchases: tried, changes: changes)
            // A stopped series is still a recurring series here, so only bills the projection
            // actually charges are offered: changing any other would do nothing.
            let due = Set(without.flatMap { $0.bills.map(\.name) })
            let bills = try Row.fetchAll(db, sql: """
                SELECT m.name, MAX(EXISTS(SELECT 1 FROM edges c WHERE c.kind = 'in_category'
                                          AND c.source = m.id AND c.target = 'category:subscriptions'))
                FROM edges e JOIN transactions t ON t.transaction_id = e.source JOIN entities m ON m.id = e.target
                WHERE e.kind = 'recurring' AND t.kind = 'spending'
                GROUP BY e.target ORDER BY MAX(e.typical_amount) DESC, m.name
                """).map { (name: $0[0] as String, isSubscription: $0[1] as Bool) }.filter { due.contains($0.name) }
            return CashFlow(account: account, accountName: checking[1], without: without, with: with, range: range, bills: bills)
        }
    }

    /// The line the screen leads with: with the scenarios when any is on.
    var shown: [Simulator.Day] { with ?? without }

    func balance(_ day: Simulator.Day) -> Double { day.balances[account] ?? 0 }

    /// The lowest balance and its first day.
    func lowest(_ days: [Simulator.Day]) -> (date: String, balance: Double)? {
        days.map { (date: $0.date, balance: balance($0)) }.min { $0.balance < $1.balance }
    }

    /// Why the shown line is lowest where it is: "Before payday" when money comes in the next
    /// day, else the checking bill paid that day. Nil when neither explains it.
    var lowReason: String? {
        guard let low = lowest(shown), let index = shown.firstIndex(where: { $0.date == low.date }) else { return nil }
        // shortcut: any rise the next day is called payday, though a transfer in from savings
        // would rise too; read the income series' days if a persona moves money that way.
        if index + 1 < shown.count, balance(shown[index + 1]) > low.balance { return "Before payday" }
        return shown[index].bills.first { $0.account == account }.map { "After \($0.name)" }
    }
}

/// The cash-flow screen: the checking balance for the next 30, 60 or 90 days, its lowest point,
/// and scenarios to switch on and off: purchases the person adds, a change to one bill, and
/// cancelling subscriptions.
struct CashFlowView: View {
    let database: SedgeDatabase
    @State private var days = CashFlow.days
    @State private var result: CashFlow?
    @State private var loaded = false
    @State private var asOf = ""
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// A purchase the person added, with its switch.
    struct Purchase: Identifiable {
        let id = UUID()
        let amount: Double
        let date: String
        var isOn = true
    }
    @State private var purchases: [Purchase] = []
    /// Typed text, read as dollars, and the day picked for the next purchase to add.
    @State private var amountText = ""
    @State private var date = ""

    /// The bill change: which bill, typed dollars per charge, and the day it starts.
    @State private var billOn = false
    @State private var billName = ""
    @State private var billText = ""
    @State private var billFrom = ""

    /// Cancelling subscriptions. All of them are chosen until the person unticks one, so the
    /// set holds the ones kept rather than the ones cancelled.
    @State private var cancelOn = false
    @State private var kept: Set<String> = []
    /// How much more checking has at the end with the chosen subscriptions cancelled.
    @State private var saving: Double?

    @State private var showingIncluded = false

    /// A projected day for people, e.g. "Jul 1". The next 90 days need no year.
    private static func day(_ date: String) -> String {
        date.displayDate(.dateTime.month(.abbreviated).day())
    }

    private static func money(_ amount: Double) -> String { amount.formatted(.currency(code: "USD")) }

    /// Read in the phone's own number format, so "12,50" works where a comma is the decimal mark.
    private static func dollars(_ text: String) -> Double? { try? Double(text, format: .number) }

    private var subscriptions: [String] { result?.bills.filter(\.isSubscription).map(\.name) ?? [] }

    /// The chosen subscriptions cancelled from `first`, the first projected day (tomorrow), so
    /// every charge the projection has stops.
    private func cancels(_ result: CashFlow?, from first: String) -> [Simulator.Change] {
        (result?.bills ?? []).filter { $0.isSubscription && !kept.contains($0.name) }
            .map { Simulator.Change(cancelling: $0.name, from: first) }
    }

    private var changes: [Simulator.Change] {
        var changes: [Simulator.Change] = []
        if billOn, !billName.isEmpty, !billFrom.isEmpty, let by = Self.dollars(billText), by != 0 {
            changes.append(Simulator.Change(merchant: billName, from: billFrom, by: by))
        }
        if cancelOn { changes += cancels(result, from: result?.without.first?.date ?? "") }
        return changes
    }

    /// Everything the projection depends on, so it is redone whenever any of it changes.
    private var inputs: String {
        let on = purchases.filter(\.isOn).map { "\($0.amount)@\($0.date)" }
        let changed = changes.map { "\($0.merchant)@\($0.from)\($0.by.map { "+\($0)" } ?? "x")" }
        return "\(days)|\(on)|\(changed)|\(kept.sorted())"
    }

    var body: some View {
        ScrollView {
            if let result {
                VStack(alignment: .leading, spacing: 12) {
                    Text("\(result.accountName) · updated \(asOf.displayDate(.dateTime.month(.abbreviated).day()))")
                        .font(.row)
                        .foregroundStyle(Color.muted)
                    Picker("Projection length", selection: $days) {
                        ForEach([30, 60, 90], id: \.self) { Text("\($0) days").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    lowestPoint(result)
                    chart(result)
                        .frame(height: 204)
                        // Axis labels past this size overlap; VoiceOver reads the summary instead.
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    legend(result)
                    Text("Shading shows the range between your busiest and quietest recent four weeks of spending.")
                        .font(.row)
                        .foregroundStyle(Color.muted)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                scenarios(result)
                    .padding(.top, 16)
            }
        }
        .background(Color.background)
        .navigationBarTitleDisplayMode(.inline)
        // The number pad has no return key, so scrolling is the way to put it away and reach the tabs.
        .scrollDismissesKeyboard(.immediately)
        .toolbar {
            Button("What’s included?", systemImage: "info.circle") { showingIncluded = true }
        }
        .sheet(isPresented: $showingIncluded) { included }
        .overlay {
            if loaded && result == nil {
                ContentUnavailableView("No bank account", systemImage: "banknote", description: Text("A checking or savings balance is needed to project."))
            }
        }
        .task(id: inputs) { await load() }
    }

    private func load() async {
        do {
            if asOf.isEmpty { asOf = try database.asOf() ?? "" }
            let loaded = try CashFlow.load(database, days: days, purchases: purchases.filter(\.isOn).map { ($0.amount, $0.date) },
                                           changes: changes)
            result = loaded
            if let loaded, let first = loaded.without.first?.date {
                // Defaults once the days are known: the next purchase tomorrow, and the biggest bill
                // from tomorrow. A purchase day a shorter window no longer has goes back to tomorrow.
                if !loaded.without.contains(where: { $0.date == date }) { date = first }
                if billFrom.isEmpty { billFrom = first }
                if billName.isEmpty { billName = loaded.bills.first?.name ?? "" }
                let chosen = cancels(loaded, from: first)
                // What cancelling alone would save, measured against the current plan by the simulator itself.
                saving = try chosen.isEmpty ? nil : CashFlow.load(database, days: days, changes: chosen)
                    .flatMap { cancelled in cancelled.with?.last.map { cancelled.balance($0) - cancelled.balance(cancelled.without.last!) } }
            }
        } catch {
            print("Could not project:", error)
        }
        loaded = true
    }

    /// "Lowest projected balance", its amount, and its day with the reason beside it.
    private func lowestPoint(_ result: CashFlow) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Lowest projected balance")
                .font(.row)
                .foregroundStyle(Color.muted)
            if let lowest = result.lowest(result.shown) {
                // Stacked at the largest text sizes, so the amount keeps the full width.
                let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading))
                    : AnyLayout(HStackLayout(alignment: .top))
                layout {
                    Text(Self.money(lowest.balance))
                        .font(.bigValue)
                        .monospacedDigit()
                        .foregroundStyle(lowest.balance < 0 ? Color.red : Color.ink)
                    Spacer(minLength: 8)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Self.day(lowest.date))
                        if let reason = result.lowReason { Text(reason) }
                    }
                    .font(.row)
                    .foregroundStyle(Color.muted)
                    .padding(.top, 8)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func chart(_ result: CashFlow) -> some View {
        let shown = result.shown
        let dates = shown.map(\.date)
        let lowest = result.lowest(shown)
        // Start, middle and end, as in the design.
        let labeled = [dates.first, dates[dates.count / 2], dates.last].compactMap { $0 }
        return Chart {
            ForEach(Array(zip(result.range.low, result.range.high)), id: \.0.date) { low, high in
                AreaMark(x: .value("Day", low.date),
                         yStart: .value("Low", result.balance(low)),
                         yEnd: .value("High", result.balance(high)))
                    .foregroundStyle(Color.accent.opacity(0.09))
            }
            // The current plan stays as a dashed line behind the changes, so the difference shows.
            if result.with != nil {
                ForEach(result.without, id: \.date) { day in
                    LineMark(x: .value("Day", day.date), y: .value("Balance", result.balance(day)), series: .value("Line", "Current plan"))
                        .foregroundStyle(Color.second)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
            ForEach(shown, id: \.date) { day in
                LineMark(x: .value("Day", day.date), y: .value("Balance", result.balance(day)), series: .value("Line", "Shown"))
                    .foregroundStyle(Color.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineJoin: .round))
            }
            if let lowest {
                PointMark(x: .value("Day", lowest.date), y: .value("Balance", lowest.balance))
                    .foregroundStyle(Color.accent)
            }
        }
        // Zero stays on the axis, so a dip toward it reads as one.
        .chartYScale(domain: .automatic(includesZero: true))
        .chartXAxis {
            AxisMarks { value in
                if let date = value.as(String.self), labeled.contains(date) {
                    AxisValueLabel { Text(Self.day(date)).foregroundStyle(Color.muted) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(Color.line)
                // Short labels such as "$2.5K", so the axis stays narrow.
                AxisValueLabel(format: .currency(code: "USD").notation(.compactName)).foregroundStyle(Color.muted)
            }
        }
        // One sentence for VoiceOver instead of every point.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(chartSummary(result, lowest))
    }

    /// E.g. "Checking balance forecast, July 1 to July 30, with changes. Lowest $1,234.00 on July 15."
    private func chartSummary(_ result: CashFlow, _ lowest: (date: String, balance: Double)?) -> String {
        let format = Date.FormatStyle.dateTime.month(.wide).day()
        let span = "\(result.shown.first?.date.displayDate(format) ?? "") to \(result.shown.last?.date.displayDate(format) ?? "")"
        let lowestText = lowest.map { " Lowest \(Self.money($0.balance)) on \($0.date.displayDate(format))." } ?? ""
        return "\(result.accountName) balance forecast, \(span)\(result.with == nil ? "" : ", with changes").\(lowestText)"
    }

    /// The design's legend: a solid swatch for the line shown, a dashed one for the plan behind it.
    private func legend(_ result: CashFlow) -> some View {
        HStack(spacing: 12) {
            if result.with != nil {
                swatch("With changes", dashed: false)
                swatch("Current plan", dashed: true)
            } else {
                swatch("Current plan", dashed: false)
            }
        }
        .font(.note)
        .foregroundStyle(Color.muted)
        .accessibilityElement(children: .combine)
    }

    private func swatch(_ title: String, dashed: Bool) -> some View {
        HStack(spacing: 5) {
            Path { $0.move(to: CGPoint(x: 0, y: 1)); $0.addLine(to: CGPoint(x: 16, y: 1)) }
                .stroke(dashed ? Color.second : Color.accent, style: StrokeStyle(lineWidth: 2, dash: dashed ? [4, 3] : []))
                .frame(width: 16, height: 2)
            Text(title)
        }
    }

    /// The scenario panel: a switch for each scenario, the projected end balance, and what's included.
    private func scenarios(_ result: CashFlow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Scenario")
                    .font(.headline)
                    .foregroundStyle(Color.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text("Preview only")
                    .font(.row)
                    .foregroundStyle(Color.muted)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach($purchases) { $purchase in
                    row(isOn: $purchase.isOn, "One-time purchase", "\(Self.money(purchase.amount)) · \(Self.day(purchase.date))")
                        .accessibilityIdentifier("purchase")
                    Divider().overlay(Color.line)
                }
                purchaseEntry(result)
                if !result.bills.isEmpty {
                    Divider().overlay(Color.line)
                    billChange(result)
                }
                if !subscriptions.isEmpty {
                    Divider().overlay(Color.line)
                    cancelSubscriptions(result)
                }
            }
            .background(Color.background, in: .rect(cornerRadius: 14))
            if let end = result.shown.last {
                HStack {
                    Text("Projected \(Self.day(end.date))")
                    Spacer()
                    Text(Self.money(result.balance(end)))
                        .bold()
                        .monospacedDigit()
                        .accessibilityIdentifier("projected")
                }
                .font(.subheadline)
                .foregroundStyle(Color.ink)
            }
            Button {
                showingIncluded = true
            } label: {
                // A 44 pt tall target, though only the words show.
                Text("What’s included? →")
                    .font(.link)
                    .frame(minHeight: 44)
                    .contentShape(.rect)
            }
        }
        .padding(.horizontal, 17)
        .padding(.top, 24)
        .padding(.bottom, 12)
        .background(Color.group, in: .rect(cornerRadius: 22))
    }

    /// One scenario: its name and what it does, with its switch.
    private func row(isOn: Binding<Bool>, _ title: String, _ detail: String) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.footnote).foregroundStyle(Color.ink)
                Text(detail).font(.row).foregroundStyle(Color.muted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    /// The old what-if entry: an amount and a day, added as a purchase switch that starts on.
    private func purchaseEntry(_ result: CashFlow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                // A dollar sign in front, so a typed "1500" still reads as money.
                Text("$").foregroundStyle(Color.muted).accessibilityHidden(true)
                // Outside a Form nothing makes these rows 44 pt tall, so each target sets it.
                TextField("Extra purchase in dollars", text: $amountText)
                    .keyboardType(.decimalPad)
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                Button {
                    guard let amount = Self.dollars(amountText), amount > 0, !date.isEmpty else { return }
                    purchases.append(Purchase(amount: amount, date: date))
                    amountText = ""
                } label: {
                    Text("Add purchase")
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                }
                .font(.link)
                .disabled((Self.dollars(amountText) ?? 0) <= 0)
            }
            .font(.footnote)
            // A menu picker outside a Form shows only its choice, so its name goes beside it.
            LabeledContent("On") {
                Picker("On", selection: $date) {
                    ForEach(result.without, id: \.date) { Text(Self.day($0.date)).tag($0.date) }
                }
                .labelsHidden()
            }
            .font(.footnote)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    /// A change to one recurring bill from a day on; its bill, amount and day show while it's on.
    private func billChange(_ result: CashFlow) -> some View {
        let by = Self.dollars(billText)
        let detail = by.map { "\(billName) \($0 < 0 ? "−" : "+")\(Self.money(abs($0))) · from \(Self.day(billFrom))" }
            ?? "Pick a bill and an amount"
        return VStack(alignment: .leading, spacing: 0) {
            row(isOn: $billOn, "Change a bill", detail)
                .accessibilityIdentifier("bill")
            if billOn {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Bill") {
                        Picker("Bill", selection: $billName) {
                            ForEach(result.bills, id: \.name) { Text($0.name).tag($0.name) }
                        }
                        .labelsHidden()
                    }
                    // Numbers and punctuation, since a smaller bill needs a minus sign the number pad lacks.
                    TextField("Change per bill in dollars, e.g. 200 or -50", text: $billText)
                        .keyboardType(.numbersAndPunctuation)
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                    LabeledContent("From") {
                        Picker("From", selection: $billFrom) {
                            ForEach(result.without, id: \.date) { Text(Self.day($0.date)).tag($0.date) }
                        }
                        .labelsHidden()
                    }
                }
                .font(.footnote)
                .padding(.horizontal, 12)
                .padding(.bottom, 9)
            }
        }
    }

    /// Cancelling the chosen subscriptions from tomorrow, before their next charge.
    private func cancelSubscriptions(_ result: CashFlow) -> some View {
        let chosen = Set(subscriptions).subtracting(kept)
        let next = result.without.first { $0.bills.contains { chosen.contains($0.name) } }?.date
        let detail = chosen.isEmpty ? "None chosen"
            : "Save \(Self.money(saving ?? 0))\(next.map { " · before \(Self.day($0))" } ?? "")"
        return VStack(alignment: .leading, spacing: 0) {
            row(isOn: $cancelOn, "Cancel subscriptions", detail)
                .accessibilityIdentifier("cancel")
            if cancelOn {
                ForEach(subscriptions, id: \.self) { name in
                    Toggle(name, isOn: Binding(get: { !kept.contains(name) },
                                               set: { if $0 { kept.remove(name) } else { kept.insert(name) } }))
                        .font(.footnote)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 9)
                }
            }
        }
    }

    /// What the projection counts, opened from the info button and "What's included?".
    private var included: some View {
        NavigationStack {
            List {
                Section {
                    Text("Paychecks and other regular deposits, on their usual days.")
                    Text("Recurring bills, at their usual amounts, from the account they last used.")
                    Text("Card payments: each card's last statement, paid in full on its usual day.")
                    Text("Everyday spending: what you spent outside regular bills in the last four weeks, spread evenly over each day.")
                } header: {
                    Text("The projection counts")
                } footer: {
                    Text("It starts from your balances on \(asOf.displayDate()). The shading redoes everyday spending at your busiest and quietest four weeks of the last twelve. Scenarios are a preview only; nothing changes in your accounts.")
                        .foregroundStyle(Color.muted)
                }
                .listRowBackground(Color.group)
            }
            .themedBackground()
            .navigationTitle("What’s included")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { showingIncluded = false } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview {
    // Maya's fake data, loaded the same way the app loads it.
    NavigationStack {
        CashFlowView(database: try! .open("maya"))
            .navigationTitle("Cash flow")
    }
}
