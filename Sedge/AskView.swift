//
//  AskView.swift
//  Sedge
//

import Charts
import SedgeCore
import SwiftUI

// MARK: - What a conversation shows

// These types only say what the Ask screen draws. Whatever answers questions fills them in;
// until something does, every question gets the same "not connected" reply.

/// One question from the person and Sedge's answer to it.
struct ChatTurn: Identifiable {
    let id = UUID()
    /// What the person asked.
    var question: String
    /// Sedge's reply.
    var answer: ChatAnswer
}

/// Sedge's reply: a lead, an optional bold point, a smaller detail line, and optional extras.
struct ChatAnswer {
    /// The opening words, e.g. "More than usual."
    var lead: String
    /// The main point, shown in bold after the lead.
    var point: String?
    /// A smaller line with the figures behind the answer.
    var detail: String?
    /// A spending card, shown above the question as in the design.
    var breakdown: Breakdown?
    /// A small bar chart, e.g. one bar per month.
    var chart: [ChatBar]?
    /// The words of a link to the what-if screen, e.g. "Compare a small change →".
    var whatIfLink: String?
    /// A question back to the person, answered with a tap.
    var quickCheck: QuickCheck?
}

/// One labeled dollar amount: a bar in a breakdown card or a chart.
struct ChatBar: Identifiable {
    var label: String
    var amount: Double
    var id: String { label }
}

/// A spending card: a title and period, the total, how it compares, and a bar per part.
struct Breakdown {
    /// E.g. "Food & dining".
    var title: String
    /// E.g. "Jun 1–30".
    var period: String
    var total: Double
    /// E.g. "$64 above your usual pace".
    var comparison: String
    var bars: [ChatBar]
}

/// A short question for the person. A tap is sent through `ask_user`, so the reply is saved
/// (and shown in Saved answers) exactly like one the assistant asked for.
struct QuickCheck {
    var question: String
    /// Small lines under the question, e.g. the store and date.
    var details: [String]
    /// The replies that get saved, two or three (`ask_user` takes two to four, and the
    /// design has room for three buttons with "Later"). "Later" is always added and saves nothing.
    var options: [String]
    /// The fact the reply is saved under, e.g. "own_transfer_2026_06_20".
    var factKey: String
}

// MARK: - The screen

/// Ask a question about the chosen data, as a chat. No model is wired in yet, so a typed
/// question is answered with "The assistant isn't connected yet." Debug builds launched with
/// `-sampleChat YES` show the design's sample conversation, worked out from this data.
struct AskView: View {
    let database: SedgeDatabase
    /// Switches the main tab, for the toolbar buttons and the card's trends link.
    var open: (MainTab) -> Void = { _ in }
    @State private var turns: [ChatTurn] = []
    @State private var question = ""
    /// True when the turns are the sample, so the screen says it is demo state.
    @State private var isDemo = false

    private var blank: Bool { question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(turns) { TurnView(turn: $0, database: database, open: open) }
            }
            .padding(.bottom, 16)
        }
        // A new answer pushes the conversation up, so the newest turn stays in view.
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
        .overlay {
            if turns.isEmpty {
                ContentUnavailableView("Ask about your money", image: "tab-ask",
                                       description: Text("For example, how much did I spend at Netflix this year?").foregroundStyle(Color.muted))
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .background(Color.background)
        .toolbar {
            // The design's own drawings, the same ones as the Trends and Accounts tabs.
            ToolbarItem(placement: .topBarLeading) {
                Button("Explore spending", image: .tabTrends) { open(.trends) }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Accounts", image: .tabAccounts) { open(.accounts) }
            }
        }
        .task {
            #if DEBUG
            // `.task` runs each time the tab shows, so the sample is only made once.
            guard turns.isEmpty, UserDefaults.standard.bool(forKey: "sampleChat") else { return }
            do {
                turns = [try ChatTurn.sample(in: database)]
                isDemo = true
            } catch {
                print("Could not make the sample conversation:", error)
            }
            #endif
        }
    }

    /// The question box with its send button, and the line that says where answers come from.
    private var composer: some View {
        VStack(spacing: 7) {
            HStack(alignment: .bottom, spacing: 2) {
                TextField("Question", text: $question,
                          prompt: Text("Ask about your money…").foregroundStyle(Color.muted), axis: .vertical)
                    .font(.subheadline)
                    .lineLimit(1...5)
                    .padding(.vertical, 12)
                    .onSubmit(send)
                Button("Send", image: .chatSend, action: send)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(blank ? Color.muted : Color.ink)
                    // Apple's minimum tap area, around the 20-point arrow.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .disabled(blank)
            }
            .padding(.leading, 16)
            .padding(.trailing, 2)
            .background(Color.surface, in: RoundedRectangle(cornerRadius: 23))
            .overlay(RoundedRectangle(cornerRadius: 23).stroke(Color.line))
            HStack(spacing: 4) {
                Image(.chatLocal).accessibilityHidden(true)
                Text(isDemo ? "Local analysis · demo state" : "Local analysis")
            }
            .font(.note)
            .foregroundStyle(Color.muted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.background)
    }

    private func send() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        turns.append(ChatTurn(question: text, answer: ChatAnswer(lead: "The assistant isn't connected yet.")))
        question = ""
    }
}

/// One turn as the design draws it: the breakdown card, the question, the answer, then the quick check.
private struct TurnView: View {
    let turn: ChatTurn
    let database: SedgeDatabase
    let open: (MainTab) -> Void
    /// What the quick check got back, shown in place of its buttons once tapped.
    @State private var reply: String?
    /// Paper and Carbon Soft use different tokens for a few pieces (bar tracks, button fills).
    @Environment(\.colorScheme) private var colorScheme

    /// The design's label and amount columns, grown with the reader's text size.
    @ScaledMetric(relativeTo: .caption) private var labelWidth = 70.0
    @ScaledMetric(relativeTo: .caption) private var amountWidth = 45.0

    private var dark: Bool { colorScheme == .dark }

    var body: some View {
        let answer = turn.answer
        VStack(alignment: .leading, spacing: 0) {
            if let breakdown = answer.breakdown {
                breakdownCard(breakdown)
                    .padding(.horizontal, 18)
                    .padding(.top, 15)
                    // Carbon Soft rules the card off from the chat; Paper leaves it open.
                    .overlay(alignment: .bottom) {
                        if dark { Color.line.frame(height: 1) }
                    }
            }

            Text("You · \(turn.question)")
                .font(.row)
                .foregroundStyle(Color.muted)
                .padding(.horizontal, 20)
                .padding(.top, 16)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    Image(.chatSedge).accessibilityHidden(true)
                    Text("Sedge").font(.row.weight(.semibold))
                }
                .foregroundStyle(Color.accent)
                .padding(.bottom, 10)

                if let point = answer.point {
                    Text("\(answer.lead) \(Text(point).fontWeight(.semibold))").font(.answer)
                } else {
                    Text(answer.lead).font(.answer)
                }
                if let detail = answer.detail {
                    Text(detail)
                        .font(.row)
                        .foregroundStyle(Color.muted)
                        .padding(.top, 14)
                }
                if let chart = answer.chart {
                    Chart(chart) { BarMark(x: .value("Label", $0.label), y: .value("Amount", $0.amount)) }
                        // `second` is only for chart marks: it is too light for text in Paper.
                        .foregroundStyle(Color.second)
                        .chartYAxis { AxisMarks(format: .currency(code: "USD").precision(.fractionLength(0))) }
                        .frame(height: 120)
                        .padding(.top, 14)
                }
                if let link = answer.whatIfLink {
                    NavigationLink {
                        WhatIfView(database: database).navigationTitle("What if")
                    } label: {
                        Text(link).font(.link).frame(minHeight: 44)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 29)

            if let check = answer.quickCheck {
                quickCheckCard(check)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
            }
        }
    }

    private func breakdownCard(_ card: Breakdown) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.title).font(.cardTitle)
                Spacer()
                Text(card.period).font(.note).foregroundStyle(Color.muted)
            }
            Text(card.total, format: .dollars).font(.bigValue)
            Text(card.comparison).font(.note).foregroundStyle(Color.muted)
            ForEach(card.bars) { bar in
                HStack(spacing: 8) {
                    Text(bar.label).frame(width: labelWidth, alignment: .leading)
                    // Each bar is its share of the card's total.
                    Capsule()
                        .fill(dark ? Color.line : Color.soft)
                        .frame(height: 7)
                        .overlay(alignment: .leading) {
                            GeometryReader { space in
                                Capsule().fill(Color.accent)
                                    .frame(width: space.size.width * min(max(card.total > 0 ? bar.amount / card.total : 0, 0), 1))
                            }
                        }
                    Text(bar.amount, format: .dollars).frame(width: amountWidth, alignment: .leading)
                }
                .font(.row)
                .frame(minHeight: 41)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(bar.label), \(bar.amount.formatted(.dollars))")
            }
            Button { open(.trends) } label: {
                Text("See trends & merchants →").font(.link).frame(minHeight: 44)
            }
        }
    }

    private func quickCheckCard(_ check: QuickCheck) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 0) {
                Text("A quick check").font(.footnote.bold())
                Text(check.question).font(.footnote)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(check.details, id: \.self) { Text($0) }
            }
            .font(.note)
            .foregroundStyle(Color.muted)
            if let reply {
                Text(reply).font(.row).foregroundStyle(Color.muted)
            } else {
                // Side by side as in the design; stacked when large text doesn't fit.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { buttons(check) }
                    VStack(spacing: 6) { buttons(check) }
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.group, in: RoundedRectangle(cornerRadius: 14))
    }

    /// The saved replies (the first filled in, as the likely one), then "Later".
    @ViewBuilder private func buttons(_ check: QuickCheck) -> some View {
        let choices: [String?] = check.options + [nil]
        ForEach(Array(choices.enumerated()), id: \.offset) { index, option in
            Button { Task { await answer(check, option) } } label: {
                Text(option ?? "Later")
                    .font(.row)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(index == 0 ? Color.contrast : Color.accent)
            .background(index == 0 ? Color.accent : (dark ? Color.soft : Color.surface),
                        in: RoundedRectangle(cornerRadius: 10))
        }
    }

    /// Sends the tap through `ask_user`, which saves a reply and skips saving "Later" (nil).
    private func answer(_ check: QuickCheck, _ option: String?) async {
        // Hides the buttons at once, so a second quick tap can't save a different reply.
        reply = "Saving…"
        let input = try? JSONSerialization.data(withJSONObject: [
            "question": check.question, "options": check.options, "fact_key": check.factKey,
        ])
        let result = await AskUser.run(input ?? Data(), database: database) { _ in option }
        if let saved = result.clarification?.answer {
            reply = "Saved: \(saved). Change it in Accounts › Saved answers."
        } else if result.clarification != nil {
            reply = "Not saved. It may be asked again."
        } else {
            reply = "Couldn't save the answer."
        }
    }
}

extension FormatStyle where Self == FloatingPointFormatStyle<Double>.Currency {
    /// Whole dollars, e.g. "$486", as the design shows card figures.
    static var dollars: Self { .currency(code: "USD").precision(.fractionLength(0)) }
}

// MARK: - The sample conversation (Debug only)

#if DEBUG
extension ChatTurn {
    /// The design's sample conversation, with every figure worked out from `database` by the
    /// assistant's own tools, so the demo shows real numbers. The wording around them is demo
    /// content, which is why the screen says "demo state".
    static func sample(in database: SedgeDatabase) throws -> ChatTurn {
        guard let asOf = try database.asOf() else { throw CocoaError(.fileReadNoSuchFile) }
        let now = monthToDate(asOf, monthsBack: 0)
        struct Compared: Decodable { let first, second: Double }

        // For each part of food, this month so far and the same days of each of the last three months.
        // shortcut: a month before the data starts counts as $0; fine for the sample people (data
        // from January), check the months exist before using this on a short bank history.
        var bars: [ChatBar] = [], usual: [Double] = []
        for (category, label) in [("groceries", "Groceries"), ("dining", "Dining"), ("coffee", "Coffee")] {
            let months = try (1...3).map { back in
                let then = monthToDate(asOf, monthsBack: back)
                return try call("compare_periods", ["category": category, "first_start": then.start, "first_end": then.end,
                                                    "second_start": now.start, "second_end": now.end], database) as Compared
            }
            bars.append(ChatBar(label: label, amount: months[0].second))
            usual.append(months.map(\.first).reduce(0, +) / 3)
        }
        let total = bars.map(\.amount).reduce(0, +)
        let gap = total - usual.reduce(0, +)
        let word = gap >= 0 ? "above" : "below"
        // The part that moved most in the same direction as the whole.
        let changes = zip(bars, usual).map { (label: $0.label, change: ($0.amount - $1) * (gap >= 0 ? 1 : -1)) }
        let mostly = changes.max { $0.change < $1.change }!.label
        let days = Int(asOf.suffix(2))!
        let gapText = abs(gap).formatted(.dollars)

        return ChatTurn(
            question: "Have I been overspending on food?",
            answer: ChatAnswer(
                lead: gap >= 0 ? "More than usual." : "Less than usual.",
                point: "\(mostly) accounts for most of the difference.",
                detail: "You’re \(gapText) \(word) the average for the same \(days) days of the last three months.",
                breakdown: Breakdown(title: "Food & dining",
                                     period: "\(now.start.displayDate(.dateTime.month(.abbreviated).day()))–\(days)",
                                     total: total, comparison: "\(gapText) \(word) your usual pace", bars: bars),
                whatIfLink: "Compare a small change →",
                quickCheck: try transferCheck(from: now.start, to: now.end, database)))
    }

    /// A quick check about this month's largest money move between accounts, or nil if none.
    private static func transferCheck(from start: String, to end: String, _ database: SedgeDatabase) throws -> QuickCheck? {
        struct Row: Decodable { let date, store, kind: String; let amount: Double }
        struct Found: Decodable { let rows: [Row] }
        // shortcut: only the newest 10 rows of $100 or more are looked at, which holds a transfer
        // or card payment for the sample people; page through `find_transactions` if one is missed.
        let found: Found = try call("find_transactions", ["start_date": start, "end_date": end, "min_amount": 100.0], database)
        guard let move = found.rows.filter({ ["transfer", "card_payment"].contains($0.kind) && $0.amount > 0 })
            .max(by: { $0.amount < $1.amount }) else { return nil }
        return QuickCheck(
            question: "Was this \(move.amount.formatted(.currency(code: "USD"))) transfer between your accounts?",
            details: ["\(move.store) · \(move.date.displayDate(.dateTime.month(.abbreviated).day()))",
                      "It may be excluded from spending."],
            options: ["Yes, mine", "No"],
            factKey: "own_transfer_\(move.date)")
    }

    /// Runs one of the assistant's tools and reads its JSON reply. A tool error doesn't decode, so it throws.
    private static func call<T: Decodable>(_ tool: String, _ input: [String: Any], _ database: SedgeDatabase) throws -> T {
        let reply = Tool.named(tool)!.call(try JSONSerialization.data(withJSONObject: input), database: database)
        return try JSONDecoder().decode(T.self, from: Data(reply.utf8))
    }

    /// The first of the month `monthsBack` months before `asOf` through the same day of that
    /// month, or its last day when the month is shorter (Mar 31 back one is Feb 1 to Feb 28).
    static func monthToDate(_ asOf: String, monthsBack: Int) -> (start: String, end: String) {
        let parts = asOf.split(separator: "-").compactMap { Int($0) } // year, month, day
        let index = parts[0] * 12 + parts[1] - 1 - monthsBack
        let year = index / 12, month = index % 12 + 1
        let calendar = Calendar(identifier: .gregorian)
        let length = calendar.range(of: .day, in: .month, for: calendar.date(from: DateComponents(year: year, month: month))!)!.count
        return (String(format: "%04d-%02d-01", year, month), String(format: "%04d-%02d-%02d", year, month, min(parts[2], length)))
    }
}
#endif

#Preview {
    NavigationStack {
        AskView(database: try! SedgeDatabase())
            .navigationTitle("Ask Sedge")
            .navigationBarTitleDisplayMode(.inline)
    }
}
