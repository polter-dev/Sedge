//
//  WelcomeView.swift
//  Sedge
//

import Charts
import GRDB
import SedgeCore
import SwiftUI

/// The first screen on a fresh install: what Sedge is, a preview chart, and two ways in,
/// connecting a bank through Plaid or exploring the sample people.
struct WelcomeView: View {
    /// Maya's database, which draws the preview chart; nil while it is still opening.
    let maya: SedgeDatabase?
    /// Saves the chosen data, which also ends the first launch.
    let choose: (String) -> Void
    @State private var preview: (projection: WhatIf, range: (low: [Simulator.Day], high: [Simulator.Day]))?
    /// True while the sample-people picker is shown.
    @State private var exploring = false
    /// The bank file, opened when Connect with Plaid is tapped, and whether its screen is shown.
    @State private var bank: SedgeDatabase?
    @State private var connecting = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Sedge")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.accent)
                        .padding(.top, 46)
                    // The design breaks the line after "view"; larger text sizes still wrap further.
                    Text("A clearer view\nof what’s next.")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                        .padding(.top, 35)
                    Text("Ask about your money. We’ll work out the details together.")
                        .font(.answer)
                        .padding(.top, 18)
                    chartCard
                        .padding(.top, 15)
                    Button {
                        connectBank()
                    } label: {
                        Text("Connect with Plaid")
                            .font(.subheadline.weight(.semibold))
                            // The button's fill is the accent, so its text takes the color made to sit on it.
                            .foregroundStyle(Color.contrast)
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 10))
                    .padding(.top, 28)
                    Button {
                        exploring = true
                    } label: {
                        // A full-width, 44 pt tall target, though only the words show.
                        Text("Explore sample data")
                            .font(.link)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .padding(.top, 5)
                    Text("Connect the accounts you choose. Review what’s shared before continuing.")
                        .font(.note)
                        .foregroundStyle(.secondary)
                        .padding(.top, 18)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .background(Color.background)
            .navigationTitle("Welcome")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $connecting) {
                if let bank {
                    // The same screen the Accounts tab shows, including its "server not running" message.
                    ConnectBankScreen(database: bank, onSynced: { choose(SedgeDatabase.bankChoice) },
                                      useSample: { exploring = true })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.background)
                        .navigationTitle("Connect bank")
                }
            }
        }
        .sheet(isPresented: $exploring) {
            DataPickerView(cancel: { exploring = false }) { choose($0) }
        }
        // Runs once Maya's database is open.
        .task(id: maya == nil) {
            guard let maya else { return }
            do {
                // The same 30-day projection and range the What if screen and the simulator tool use.
                if let projection = try WhatIf.load(maya, extra: nil, on: nil) {
                    let range = try maya.dbQueue.read { try Simulator.range($0, days: WhatIf.days) }
                    preview = (projection, range)
                }
            } catch {
                print("Could not project the preview:", error)
            }
        }
    }

    /// Only the bank file is ever handed to the Plaid flow, so a sync can't write into a persona's file.
    private func connectBank() {
        do {
            bank = try SedgeDatabase.open(SedgeDatabase.bankChoice)
            connecting = true
        } catch {
            // Choosing the bank anyway lands on the app's "Couldn't open the data" screen, which says why.
            choose(SedgeDatabase.bankChoice)
        }
    }

    /// The card with Maya's projected checking balance: the line, its likely range shaded, and the lowest day marked.
    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let (projection, range) = preview {
                chart(projection, range)
                    .frame(height: 130)
                    // Axis labels past this size overlap in a 130 pt chart; VoiceOver reads the summary instead.
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 130)
            }
            Text("A preview of what you can explore")
                .font(.note)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 13)
        .padding(.bottom, 8)
        .background(Color.surface, in: .rect(cornerRadius: 15))
    }

    private func chart(_ projection: WhatIf, _ range: (low: [Simulator.Day], high: [Simulator.Day])) -> some View {
        let account = projection.account
        let days = projection.without
        let dates = days.map(\.date)
        let lowest = projection.lowest(days)
        // Start, middle and end, as in the design.
        let labeled = [dates.first, dates[dates.count / 2], dates.last].compactMap { $0 }
        return Chart {
            ForEach(Array(zip(range.low, range.high)), id: \.0.date) { low, high in
                AreaMark(x: .value("Day", low.date),
                         yStart: .value("Low", low.balances[account] ?? 0),
                         yEnd: .value("High", high.balances[account] ?? 0))
                    .foregroundStyle(Color.accent.opacity(0.09))
            }
            ForEach(days, id: \.date) { day in
                LineMark(x: .value("Day", day.date), y: .value("Balance", day.balances[account] ?? 0))
                    .foregroundStyle(Color.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineJoin: .round))
            }
            if let lowest {
                PointMark(x: .value("Day", lowest.date), y: .value("Balance", lowest.balance))
                    .foregroundStyle(Color.accent)
            }
        }
        .chartXAxis {
            AxisMarks { value in
                if let date = value.as(String.self), labeled.contains(date) {
                    AxisValueLabel {
                        Text(date.displayDate(.dateTime.month(.abbreviated).day())).foregroundStyle(Color.muted)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Color.line)
                // Short labels such as "$2.5K", so the axis stays narrow.
                AxisValueLabel(format: .currency(code: "USD").notation(.compactName)).foregroundStyle(Color.muted)
            }
        }
        // One sentence for VoiceOver instead of every point.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary(projection, lowest))
    }

    /// E.g. "Sample checking balance forecast, Jul 1 to Jul 30. Lowest $1,234.00 on Jul 15."
    private func accessibilitySummary(_ projection: WhatIf, _ lowest: (date: String, balance: Double)?) -> String {
        let format = Date.FormatStyle.dateTime.month(.wide).day()
        let span = "\(projection.without.first?.date.displayDate(format) ?? "") to \(projection.without.last?.date.displayDate(format) ?? "")"
        guard let lowest else { return "Sample checking balance forecast, \(span)." }
        return "Sample checking balance forecast, \(span). Lowest \(lowest.balance.formatted(.currency(code: "USD"))) on \(lowest.date.displayDate(format))."
    }
}

#Preview {
    WelcomeView(maya: try? .open("maya")) { print("Chose", $0) }
}
