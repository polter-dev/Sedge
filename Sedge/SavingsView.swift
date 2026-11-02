//
//  SavingsView.swift
//  Sedge
//

import SedgeCore
import SwiftUI

/// Ways to save: the person types a monthly goal and sees the stores they seem to value least,
/// ranked, from the same `Savings.plan` the savings_options tool answers with, so the screen and
/// the assistant always suggest the same cuts.
struct SavingsView: View {
    let database: SedgeDatabase
    @State private var goalText = ""
    @State private var plan: Savings.Plan?
    @State private var failed = false
    /// So a tap anywhere in the 44 pt goal row gives the field the cursor.
    @FocusState private var goalFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private static func money(_ amount: Double) -> String { amount.formatted(.currency(code: "USD")) }

    var body: some View {
        List {
            Section {
                HStack(spacing: 4) {
                    // A dollar sign in front, so a typed "200" still reads as money.
                    Text("$").foregroundStyle(Color.muted).accessibilityHidden(true)
                    TextField("Monthly goal in dollars", text: $goalText)
                        .keyboardType(.decimalPad)
                        .focused($goalFocused)
                        .foregroundStyle(Color.ink)
                }
                .frame(minHeight: 44)
                .contentShape(.rect)
                // A text field only takes taps on its text line, so the rest of the row passes them on.
                .onTapGesture { goalFocused = true }
            } header: {
                Text("Save each month")
            } footer: {
                // Short, so the cuts stay in view at the largest text sizes.
                Text("Never rent, bills, tuition, loans or transfers.")
                    .foregroundStyle(Color.muted)
            }
            .listRowBackground(Color.group)

            if let plan {
                Section {
                    ForEach(Array(plan.cuts.enumerated()), id: \.offset) { index, cut in
                        row(index + 1, cut)
                    }
                } header: {
                    Text("Least valued first")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(summary(plan)).accessibilityIdentifier("savings-summary")
                        Text("Stores you buy from rarely, cut back on when your balance is low, or spend little at come first. "
                             + "Each amount is your average month there.")
                    }
                    .foregroundStyle(Color.muted)
                }
                .listRowBackground(Color.group)
            } else if failed {
                Section {
                    Text("There isn't enough data to suggest cuts yet.").foregroundStyle(Color.muted)
                }
                .listRowBackground(Color.group)
            }
        }
        .themedBackground()
        // The number pad has no return key, so scrolling puts it away.
        .scrollDismissesKeyboard(.immediately)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: goalText) { load() }
    }

    private func load() {
        // Read in the phone's own number format, so "12,50" works where a comma is the decimal mark.
        guard let goal = try? Double(goalText, format: .number), goal > 0 else {
            plan = nil
            return
        }
        do {
            plan = try Savings.plan(in: database, goal: goal)
            failed = false
        } catch {
            plan = nil
            failed = true
            print("Could not rank savings:", error)
        }
    }

    /// "Together $308.72 a month, enough for the goal." or what is missing and why.
    private func summary(_ plan: Savings.Plan) -> String {
        let together = "Together \(Self.money(plan.total_per_month)) a month"
        guard !plan.reached else { return together + ", enough for your goal." }
        return together + ", \(Self.money(plan.short_by ?? 0)) short." + (plan.note.map { " " + $0 } ?? "")
    }

    /// One cut: its rank, store, monthly amount, and what the ranking was based on.
    private func row(_ rank: Int, _ cut: Savings.Cut) -> some View {
        // Stacked at the largest text sizes, so the store name and amount each keep the full width.
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        let category = SpendingView.title(cut.category)
        return layout {
            Text("\(rank)")
                .font(.headline)
                .monospacedDigit()
                .foregroundStyle(Color.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(cut.store).font(.answer).foregroundStyle(Color.ink)
                Text("\(category) · \(cut.evidence)").font(.row).foregroundStyle(Color.muted)
            }
            Spacer(minLength: 0)
            Text("\(Self.money(cut.per_month))/mo")
                .font(.answer.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Color.ink)
        }
        .padding(.vertical, 4)
        // One sentence per row, with "a month" spoken instead of "slash mo".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(rank). \(cut.store), \(Self.money(cut.per_month)) a month. \(category); \(cut.evidence).")
        .accessibilityIdentifier("cut")
    }
}

#Preview {
    // Daniel's fake data, which has more flexible spending than Maya's.
    NavigationStack {
        SavingsView(database: try! .open("daniel"))
            .navigationTitle("Ways to save")
    }
}
