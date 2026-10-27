//
//  AllMonthsView.swift
//  Sedge
//

import Charts
import SedgeCore
import SwiftUI

/// Every month's spending and every category's over all the data, with a switch that adds
/// money moved between the person's own accounts as its own category bar. Opened from the Spending screen.
struct AllMonthsView: View {
    let database: SedgeDatabase
    /// Off by default: moving money to savings or paying a card isn't spending, and the
    /// purchases on the card were already counted at the store.
    @State private var includeMoved = false
    @State private var totals: [SpendingTotal] = []

    /// One bar: what it's labeled with and its total in dollars.
    struct Bar: Identifiable {
        let label: String
        let total: Double
        var id: String { label }
    }

    /// Adds up the totals that share a label in whole cents, as the tools add.
    static func bars(_ totals: [SpendingTotal], by label: (SpendingTotal) -> String) -> [Bar] {
        Dictionary(grouping: totals, by: label).map { label, same in
            Bar(label: label, total: Double(same.reduce(0) { $0 + Int(($1.total * 100).rounded()) }) / 100)
        }
    }

    /// Each month's spending over all categories, oldest first. Money moved is left out: it's
    /// not spending, and a second bar per month would be read by VoiceOver as one unnamed pair.
    static func byMonth(_ totals: [SpendingTotal]) -> [Bar] {
        bars(totals.filter { $0.category != SpendingTotal.movedCategory }, by: \.month).sorted { $0.label < $1.label }
    }

    /// Each category's total over all the data, biggest first, money moved included when loaded.
    static func byCategory(_ totals: [SpendingTotal]) -> [Bar] {
        bars(totals) { SpendingView.title($0.category) }.sorted { ($0.total, $1.label) > ($1.total, $0.label) }
    }

    /// The category bar money moved gets, as `SpendingView.title` writes it.
    private static let movedLabel = SpendingView.title(SpendingTotal.movedCategory)

    /// Whole dollars on the axes and labels; cents only clutter a chart.
    private static let dollars = FloatingPointFormatStyle<Double>.Currency(code: "USD").precision(.fractionLength(0))

    /// The reader's text size setting.
    @Environment(\.dynamicTypeSize) private var textSize

    var body: some View {
        let months = Self.byMonth(totals), categories = Self.byCategory(totals)
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                Text("By month").font(.title2.bold()).foregroundStyle(Color.ink)
                Text("Every month in the data, all categories together.").font(.row).foregroundStyle(Color.muted)
                Chart(months) { bar in
                    BarMark(x: .value("Month", bar.label), y: .value("Spent", bar.total), width: .ratio(0.55))
                        .cornerRadius(5)
                        .foregroundStyle(Color.accent)
                        .accessibilityLabel((bar.label + "-01").displayDate(.dateTime.month(.wide).year()))
                        .accessibilityValue(bar.total.formatted(Self.dollars))
                }
                .chartXAxis {
                    AxisMarks { value in
                        // "2026-01" is shown as "Jan".
                        if let month = value.as(String.self) {
                            // At the accessibility text sizes "Jan" becomes "J", so six months still fit side by side.
                            AxisValueLabel {
                                Text((month + "-01").displayDate(.dateTime.month(textSize.isAccessibilitySize ? .narrow : .abbreviated)))
                                    .foregroundStyle(Color.muted)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine().foregroundStyle(Color.line)
                        AxisValueLabel(format: Self.dollars).foregroundStyle(Color.muted)
                    }
                }
                .frame(height: 220)
                .padding(.top, 8)

                Text("By category").font(.headline).foregroundStyle(Color.ink).padding(.top, 24)
                Text("All the data, biggest first.").font(.row).foregroundStyle(Color.muted)
                // The switch sits right above the chart it changes.
                Toggle("Include money moved between my accounts", isOn: $includeMoved)
                    .font(.subheadline)
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 52)
                    .background(Color.group, in: .rect(cornerRadius: 12))
                    .padding(.vertical, 8)
                // Plain rows rather than a chart: a chart's axis label stays on one line and runs off
                // the screen at large text sizes, while a row's text wraps and the row grows to fit.
                ForEach(categories) { bar in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(bar.label)  \(Text(bar.total, format: Self.dollars).foregroundStyle(Color.muted))")
                            .font(.row)
                            .foregroundStyle(Color.ink)
                        // Biggest first, so the first bar fills the width and the others are its share.
                        GeometryReader { space in
                            RoundedRectangle(cornerRadius: 5)
                                // Money moved in the quieter chart gray; its name above says what it is.
                                .fill(bar.label == Self.movedLabel ? Color.second : Color.accent)
                                .frame(width: space.size.width * max(0, bar.total) / max(categories[0].total, 1))
                        }
                        .frame(height: 18)
                    }
                    .padding(.top, 10)
                    // One VoiceOver element per category, read as its name and total.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(bar.label)
                    .accessibilityValue(bar.total.formatted(Self.dollars))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Color.background)
        // Runs each time the screen shows, so a bank sync or a moved transaction counts here,
        // and again whenever the switch changes.
        .task(id: includeMoved) {
            do {
                totals = try SpendingTotal.all(in: database, includeMoved: includeMoved)
            } catch {
                print("Could not read spending:", error)
            }
        }
    }
}

#Preview {
    // Maya's fake data, loaded the same way the app loads it.
    NavigationStack {
        AllMonthsView(database: try! .open("maya"))
            .navigationTitle("All months")
    }
}
