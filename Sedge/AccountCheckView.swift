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
    /// The bank's name, saved when it connected; nil in the sample people's files.
    let institution: String?

    var id: String { account_id }
    /// How the app names an account: "<bank> ••<last 4>", the account's own name with its last
    /// digits when the bank's name isn't known, or the name alone when there are no digits. The
    /// person's own name for it (a nickname) takes the place of either name.
    static func named(_ name: String, nickname: String?, institution: String?, mask: String?,
                      spoken: Bool = false) -> String {
        let base = nickname ?? (mask == nil ? nil : institution) ?? name
        guard let mask else { return base }
        return spoken ? "\(base) ending in \(mask)" : "\(base) ••\(mask)"
    }

    /// This account named by `named`.
    func displayName(spoken: Bool = false) -> String {
        Self.named(name, nickname: nickname, institution: institution, mask: mask, spoken: spoken)
    }

    /// Saves an answer to "Is this account yours?": the name (blank clears it), and the owner
    /// unless the answer is Decide later (nil). The account check and the Accounts screen share
    /// it, so an answer saves the same values wherever it is given.
    static func save(_ owner: Answers.Owner?, nickname: String, account id: String, in database: SedgeDatabase) throws {
        try Answers.setNickname(nickname, account: id, in: database)
        if let owner { try Answers.setOwner(owner, account: id, in: database) }
    }

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
                       json_extract(balances, '$.iso_currency_code') AS currency,
                       (SELECT value FROM meta WHERE key = 'institution_name') AS institution
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
    /// opened on its own from Accounts.
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
        // "Just added" only fits right after connecting; opened from Accounts it isn't new.
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
            try ListedAccount.save(owner, nickname: nickname, account: account.account_id, in: database)
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

/// "Accounts", opened from the Accounts tab. Each account not answered yet ("Later") is asked
/// about right here at the top, with the account check's answers; answering moves it down into
/// Answered, where tapping an account opens its check to rename it or change the answer.
struct AccountsListView: View {
    let database: SedgeDatabase
    @State private var accounts: [ListedAccount] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let toAnswer = accounts.filter { $0.owner == nil }
        let answered = accounts.filter { $0.owner != nil }
        List {
            if !toAnswer.isEmpty {
                Section {
                    ForEach(toAnswer) { account in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Is this account yours?").font(.headline)
                            Text(account.displayName())
                                .font(.subheadline)
                                .accessibilityLabel(account.displayName(spoken: true))
                            AccountAnswers(owner: nil) { answer($0, for: account) }
                                .padding(.top, 10)
                        }
                        .padding(.vertical, 5)
                        // Every card has the same three buttons, so each card is one group named
                        // for its account, and its answers are found inside it.
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(account.displayName(spoken: true))
                        // Answering slides the card up and fades it out (see `answer` for Reduce Motion).
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                } header: {
                    sectionHeader("To answer")
                }
                .listRowBackground(Color.group)
            }
            if !answered.isEmpty {
                Section {
                    ForEach(answered) { account in
                        NavigationLink {
                            AccountCheckView(database: database, account: account)
                        } label: {
                            AccountRow(account: account)
                        }
                        .accessibilityLabel(account.displayName(spoken: true))
                        .accessibilityValue(account.ownerLabel)
                    }
                } header: {
                    sectionHeader("Answered")
                }
                .listRowBackground(Color.group)
            }
        }
        .themedBackground()
        // Runs again on coming back from a check, so a new name or answer shows.
        .task { reload() }
    }

    /// A small capitals section title in the muted color, as the design draws it.
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote)
            .foregroundStyle(Color.muted)
            .textCase(.uppercase)
            .accessibilityAddTraits(.isHeader)
    }

    /// Saves what the account check saves when its name field is left as it was. Decide later
    /// (nil) saves no owner, so the account stays at the top.
    static func save(_ owner: Answers.Owner?, for account: ListedAccount, in database: SedgeDatabase) throws {
        try ListedAccount.save(owner, nickname: account.nickname ?? "", account: account.account_id, in: database)
    }

    /// Saves the answer, then moves the account into Answered.
    private func answer(_ owner: Answers.Owner?, for account: ListedAccount) {
        do {
            try Self.save(owner, for: account, in: database)
        } catch {
            print("Could not save the answer:", error)
        }
        // With Reduce Motion the account changes sections without sliding.
        withAnimation(reduceMotion ? nil : .snappy) { reload() }
    }

    private func reload() {
        do {
            accounts = try ListedAccount.all(in: database)
        } catch {
            print("Could not read the accounts:", error)
        }
    }
}

/// One answered account on Accounts: its name over its type, and the answer as the value.
private struct AccountRow: View {
    let account: ListedAccount

    var body: some View {
        LabeledContent {
            Text(account.ownerLabel).foregroundStyle(.secondary)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName())
                // "credit card" becomes "Credit card", as the design writes it.
                Text(account.kind.prefix(1).uppercased() + account.kind.dropFirst())
                    .font(.row)
                    .foregroundStyle(.secondary)
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
                                                kind: "savings", balance: 11_000, currency: "USD", institution: nil),
                         step: (2, 4))
    }
}
