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

    var id: String { account_id }

    /// The answer in plain words, shown next to the account.
    var ownerLabel: String {
        switch owner {
        case "mine": "Yours"
        case "shared": "Shared"
        default: "Not answered"
        }
    }

    static func all(in database: SedgeDatabase) throws -> [ListedAccount] {
        try database.dbQueue.read { db in
            try ListedAccount.fetchAll(db, sql: "SELECT account_id, name, mask, owner FROM accounts ORDER BY name, account_id")
        }
    }
}

/// "A quick check": asks whether an account is the person's own or shared. Yes, mine and Shared
/// save through #76's answers; Later saves nothing. Any answer closes the screen.
struct AccountCheckView: View {
    let database: SedgeDatabase
    let account: ListedAccount
    @Environment(\.dismiss) private var dismiss

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
                AnswerStack {
                    AnswerButton("Yes, mine", chosen: account.owner == "mine", filled: account.owner != "shared") { answer(.mine) }
                    AnswerButton("Shared", chosen: account.owner == "shared") { answer(.shared) }
                    AnswerButton("Later", chosen: false) { dismiss() }
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

    private func answer(_ owner: Answers.Owner) {
        do {
            try Answers.setOwner(owner, account: account.account_id, in: database)
        } catch {
            print("Could not save the answer:", error)
        }
        dismiss()
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
                         account: ListedAccount(account_id: "1", name: "Rainy-day savings", mask: "1084", owner: nil))
    }
}
