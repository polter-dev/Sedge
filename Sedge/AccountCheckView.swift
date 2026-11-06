//
//  AccountCheckView.swift
//  Sedge
//

import GRDB
import SedgeCore
import SwiftUI

/// One account as the Accounts tab lists it, with the person's answer about whose it is.
struct ListedAccount: Decodable, Identifiable, FetchableRecord {
    let account_id: String
    let name: String
    let mask: String?
    /// "mine" or "shared" (#76's answer), nil until answered.
    let owner: String?
    /// The person's own name for the account, nil when they haven't given one.
    let nickname: String?
    /// The bank's subtype, else its type (e.g. "checking", "credit card"), for the account's color.
    let kind: String
    /// The bank's current balance and its currency, when the bank gave one.
    let balance: Double?
    let currency: String?

    var id: String { account_id }
    /// The name the app shows: the person's own name, or the bank's.
    var title: String { nickname ?? name }

    /// The answer in plain words, shown next to the account.
    var ownerLabel: String {
        switch owner {
        case "mine": "Yours"
        case "shared": "Shared"
        default: "Later"
        }
    }

    static func all(in database: SedgeDatabase) throws -> [ListedAccount] {
        try database.dbQueue.read { db in
            try ListedAccount.fetchAll(db, sql: """
                SELECT account_id, name, mask, owner, nickname, COALESCE(subtype, type) AS kind,
                       json_extract(balances, '$.current') AS balance,
                       json_extract(balances, '$.iso_currency_code') AS currency
                FROM accounts ORDER BY COALESCE(nickname, name), account_id
                """)
        }
    }
}

/// "A quick check": asks whether an account is the person's own or shared, and lets them name it.
/// Yes, mine and Shared save through #76's answers; Decide later leaves the owner as it was. Every
/// answer saves the name (blank clears it) and closes the screen.
struct AccountCheckView: View {
    let database: SedgeDatabase
    let account: ListedAccount
    /// Which account this is of the ones asked about after connecting, e.g. (1, 4); nil when
    /// opened on its own from Your accounts.
    let step: (number: Int, of: Int)?
    /// The name being typed, starting from the saved one.
    @State private var nickname: String
    @Environment(\.dismiss) private var dismiss
    /// The tile grows with the text size, up to 56 pt.
    @ScaledMetric(relativeTo: .headline) private var tileSize = 44.0

    init(database: SedgeDatabase, account: ListedAccount, step: (number: Int, of: Int)? = nil) {
        self.database = database
        self.account = account
        self.step = step
        _nickname = State(initialValue: account.nickname ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let step {
                    // One dot per account asked about after connecting, the current one in the accent.
                    HStack(spacing: 6) {
                        ForEach(1...step.of, id: \.self) { number in
                            Circle().fill(number == step.number ? Color.accent : Color.line).frame(width: 8, height: 8)
                        }
                        Spacer(minLength: 8)
                        Text("Account \(step.number) of \(step.of)")
                            .font(.row.weight(.medium))
                            .foregroundStyle(Color.muted)
                    }
                    // VoiceOver reads the count once, not each dot.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Account \(step.number) of \(step.of)")
                    .padding(.bottom, 12)
                }
                Text("Is this account yours?")
                    .font(.title.bold())
                    .accessibilityAddTraits(.isHeader)
                accountCard
                    .padding(.top, 14)
                AccountAnswers(owner: account.owner, answer: answer)
                    .padding(.top, 18)
                Text("This helps identify transfers and avoid counting your own money twice.")
                    .font(.note)
                    .foregroundStyle(Color.muted)
                    .padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 19)
        }
        .background(Color.background)
        .navigationTitle("A quick check")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// The account in a card: a tile in its type's color, its name over where it came from and its
    /// balance, then the Name row.
    private var accountCard: some View {
        // "Just added" only fits right after connecting; opened from Your accounts it isn't new.
        let detail = [step == nil ? nil : "Just added from your bank",
                      account.balance.map { $0.formatted(.currency(code: account.currency ?? "USD")) }]
            .compactMap { $0 }.joined(separator: " · ")
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(account.name.prefix(1).uppercased())
                    .font(.headline)
                    .foregroundStyle(Color.onAccount)
                    .frame(width: min(tileSize, 56), height: min(tileSize, 56))
                    .background(Color.account(account.kind), in: .rect(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(accountTitle(account.name, account.mask))
                        .font(.answer.weight(.semibold))
                        .foregroundStyle(Color.ink)
                        .accessibilityLabel(accountTitle(account.name, account.mask, spoken: true))
                    if !detail.isEmpty {
                        Text(detail).font(.row).foregroundStyle(Color.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Rectangle().fill(Color.line).frame(height: 1).padding(.leading, 16)
            HStack(spacing: 12) {
                Text("Name").font(.answer).foregroundStyle(Color.ink)
                    .accessibilityHidden(true)
                // The prompt is the bank's name, drawn gray until the person types.
                TextField("Account name", text: $nickname, prompt: Text(account.name).foregroundStyle(Color.muted))
                    .font(.answer)
                    .foregroundStyle(Color.ink)
                    // A prompt replaces the title for VoiceOver, so name the field explicitly.
                    .accessibilityLabel("Account name")
                if !nickname.isEmpty {
                    Button("Clear name", systemImage: "xmark.circle") { nickname = "" }
                        .labelStyle(.iconOnly)
                        .font(.title3)
                        .foregroundStyle(Color.accent)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, nickname.isEmpty ? 16 : 4)
            .frame(minHeight: 44)
        }
        .background(Color.group, in: .rect(cornerRadius: 12))
    }

    /// Saves the name, and the owner unless the answer is Decide later (nil), then closes the screen.
    private func answer(_ owner: Answers.Owner?) {
        do {
            try Answers.setNickname(nickname, account: account.account_id, in: database)
            if let owner { try Answers.setOwner(owner, account: account.account_id, in: database) }
        } catch {
            print("Could not save the answer:", error)
        }
        dismiss()
    }
}

/// The three answers to "Is this account yours?", stacked full width: Yes, mine and Shared with
/// what each means, then Decide later as plain text. The saved answer is filled with the accent;
/// with none yet, Yes, mine is filled as the suggested one. `answer` gets nil for Decide later.
struct AccountAnswers: View {
    /// The saved answer: "mine", "shared" or nil.
    let owner: String?
    let answer: (Answers.Owner?) -> Void

    var body: some View {
        VStack(spacing: 8) {
            button("Yes, mine", "Only you spend from it", chosen: owner == "mine", filled: owner != "shared") { answer(.mine) }
            button("Shared", "Someone else uses it too", chosen: owner == "shared", filled: owner == "shared") { answer(.shared) }
            Button("Decide later") { answer(nil) }
                .font(.link)
                .foregroundStyle(Color.accent)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(.rect)
                .buttonStyle(.plain)
        }
    }

    /// One answer: filled with the accent, or outlined in it on the screen's color.
    private func button(_ title: String, _ meaning: String, chosen: Bool, filled: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title).font(.answer.weight(.medium))
                    // On the accent fill, the color made to sit on it.
                    .foregroundStyle(filled ? Color.contrast : Color.accent)
                Text(meaning).font(.row)
                    .foregroundStyle(filled ? Color.contrast : Color.muted)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(filled ? Color.accent : Color.background, in: .rect(cornerRadius: 10))
            .overlay {
                if !filled { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accent, lineWidth: 1.5) }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // The answer's name is its label; what it means is read after it.
        .accessibilityLabel(title)
        .accessibilityHint(meaning)
        // VoiceOver hears "Selected" only for a saved answer, not for the suggested one.
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// "Your accounts": every account with the person's answer, opened from the Accounts tab.
/// Accounts not answered yet ("Later") come first, marked with a dot; tapping one opens its check.
struct YourAccountsView: View {
    let database: SedgeDatabase
    @State private var accounts: [ListedAccount] = []

    var body: some View {
        List {
            Section {
                ForEach(accounts.filter { $0.owner == nil } + accounts.filter { $0.owner != nil }) { account in
                    NavigationLink {
                        AccountCheckView(database: database, account: account)
                    } label: {
                        AccountRow(account: account)
                    }
                    .accessibilityLabel(accountTitle(account.title, account.mask, spoken: true))
                    .accessibilityValue(account.ownerLabel)
                }
            } footer: {
                Text("Accounts you said “Later” about sit at the top with a dot. Tap any account to name it or change who it belongs to.")
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.group)
        }
        .themedBackground()
        // Runs again on coming back from a check, so a new name or answer shows.
        .task { reload() }
    }

    private func reload() {
        do {
            accounts = try ListedAccount.all(in: database)
        } catch {
            print("Could not read the accounts:", error)
        }
    }
}

/// One account on Your accounts: its name over the bank's name (or the question, while it is
/// unanswered), and the answer as the value.
private struct AccountRow: View {
    let account: ListedAccount

    var body: some View {
        let unanswered = account.owner == nil
        LabeledContent {
            Text(account.ownerLabel)
                .foregroundStyle(unanswered ? Color.accent : Color.secondary)
        } label: {
            HStack(spacing: 12) {
                if unanswered {
                    Circle().fill(Color.accent).frame(width: 8, height: 8)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(accountTitle(account.title, account.mask))
                    Text(unanswered ? "Is this account yours?" : account.name)
                        .font(.row)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// After a bank connection, asks "Is this account yours?" once for each account not answered
/// yet, one after another. The bank screen sets `pendingKey` after a sync that worked.
struct AccountChecksAfterConnecting: ViewModifier {
    static let pendingKey = "checkAccountsAfterConnecting"
    let database: SedgeDatabase
    /// Kept in the app's settings, so it still works when connecting from Welcome, whose
    /// screen is gone by the time the main tabs open.
    @AppStorage(pendingKey) private var pending = false
    /// The accounts still to ask about; the first one is showing.
    @State private var queue: [ListedAccount] = []
    /// Every account the queue started with, for the card's "Account N of M". Counted by place
    /// in this list, not by what is left, so a closing card keeps its own number.
    @State private var asked: [String] = []

    func body(content: Content) -> some View {
        content
            .onChange(of: pending, initial: true) {
                guard pending else { return }
                pending = false
                do {
                    queue = try ListedAccount.all(in: database).filter { $0.owner == nil }
                    asked = queue.map(\.id)
                } catch {
                    print("Could not read the accounts:", error)
                }
            }
            // Closing a sheet, by an answer or by swiping it down, moves on to the next account.
            .sheet(item: Binding(get: { queue.first }, set: { if $0 == nil, !queue.isEmpty { queue.removeFirst() } })) { account in
                NavigationStack { AccountCheckView(database: database, account: account, step: ((asked.firstIndex(of: account.id) ?? 0) + 1, asked.count)) }
            }
    }
}

#Preview {
    NavigationStack {
        AccountCheckView(database: try! SedgeDatabase(),
                         account: ListedAccount(account_id: "1", name: "Rainy-day savings", mask: "1084", owner: nil, nickname: nil,
                                                kind: "savings", balance: 11_000, currency: "USD"),
                         step: (2, 4))
    }
}
