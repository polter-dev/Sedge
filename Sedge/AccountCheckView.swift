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
            try ListedAccount.fetchAll(db, sql: "SELECT account_id, name, mask, owner, nickname FROM accounts ORDER BY COALESCE(nickname, name), account_id")
        }
    }
}

/// "A quick check": asks whether an account is the person's own or shared, and lets them name it.
/// Yes, mine and Shared save through #76's answers; Later leaves the owner as it was. Every answer
/// saves the name (blank clears it) and closes the screen.
struct AccountCheckView: View {
    let database: SedgeDatabase
    let account: ListedAccount
    /// The name being typed, starting from the saved one.
    @State private var nickname: String
    @Environment(\.dismiss) private var dismiss

    init(database: SedgeDatabase, account: ListedAccount) {
        self.database = database
        self.account = account
        _nickname = State(initialValue: account.nickname ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Is this account yours?")
                    .font(.title.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(accountTitle(account.name, account.mask))
                    .font(.subheadline)
                    .accessibilityLabel(accountTitle(account.name, account.mask, spoken: true))
                    .padding(.top, 8)
                Text("Call it something (optional)")
                    .font(.row)
                    .foregroundStyle(.secondary)
                    .padding(.top, 18)
                HStack(spacing: 8) {
                    // The prompt is the bank's name, drawn gray until the person types.
                    TextField("Account name", text: $nickname, prompt: Text(account.name).foregroundStyle(Color.muted))
                        .font(.answer)
                        .foregroundStyle(Color.ink)
                        .padding(.vertical, 10)
                        // A prompt replaces the title for VoiceOver, so name the field explicitly.
                        .accessibilityLabel("Account name")
                    if !nickname.isEmpty {
                        Button("Clear name", systemImage: "xmark.circle") { nickname = "" }
                            .labelStyle(.iconOnly)
                            .font(.title3)
                            .foregroundStyle(Color.second)
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                }
                .padding(.leading, 12)
                .padding(.trailing, nickname.isEmpty ? 12 : 0)
                .frame(minHeight: 44)
                .background(Color.surface, in: .rect(cornerRadius: 10))
                .padding(.top, 6)
                Text("Leave it blank to keep the bank’s name.")
                    .font(.note)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                AnswerStack {
                    AnswerButton("Yes, mine", chosen: account.owner == "mine", filled: account.owner != "shared") { answer(.mine) }
                    AnswerButton("Shared", chosen: account.owner == "shared") { answer(.shared) }
                    AnswerButton("Later", chosen: false) { answer(nil) }
                }
                .padding(.top, 14)
                Text("This helps identify transfers and avoid counting your own money twice.")
                    .font(.note)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 19)
        }
        .background(Color.background)
        .navigationTitle("A quick check")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Saves the name, and the owner unless the answer is Later (nil), then closes the screen.
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

    func body(content: Content) -> some View {
        content
            .onChange(of: pending, initial: true) {
                guard pending else { return }
                pending = false
                do {
                    queue = try ListedAccount.all(in: database).filter { $0.owner == nil }
                } catch {
                    print("Could not read the accounts:", error)
                }
            }
            // Closing a sheet, by an answer or by swiping it down, moves on to the next account.
            .sheet(item: Binding(get: { queue.first }, set: { if $0 == nil, !queue.isEmpty { queue.removeFirst() } })) { account in
                NavigationStack { AccountCheckView(database: database, account: account) }
            }
    }
}

#Preview {
    NavigationStack {
        AccountCheckView(database: try! SedgeDatabase(),
                         account: ListedAccount(account_id: "1", name: "Rainy-day savings", mask: "1084", owner: nil, nickname: nil))
    }
}
