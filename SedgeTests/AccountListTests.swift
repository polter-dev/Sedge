//
//  AccountListTests.swift
//  SedgeTests
//

import Foundation
import SedgeCore
import Testing
@testable import Sedge

/// The question names the account by bank and last digits, then falls back step by step.
@Test func accountNamingRule() {
    // Bank and last digits.
    #expect(ListedAccount.named("Plaid Checking", nickname: nil, institution: "Wells Fargo", mask: "0000") == "Wells Fargo ••0000")
    // No bank stored: the account's own name with the digits.
    #expect(ListedAccount.named("Plaid Checking", nickname: nil, institution: nil, mask: "0000") == "Plaid Checking ••0000")
    // No digits (the sample people): the name alone, even when the bank is known.
    #expect(ListedAccount.named("Checking", nickname: nil, institution: nil, mask: nil) == "Checking")
    #expect(ListedAccount.named("Checking", nickname: nil, institution: "Wells Fargo", mask: nil) == "Checking")
    // A nickname takes the name's place, with or without digits.
    #expect(ListedAccount.named("Plaid Checking", nickname: "Everyday", institution: "Wells Fargo", mask: "0000") == "Everyday ••0000")
    #expect(ListedAccount.named("Checking", nickname: "Everyday", institution: nil, mask: nil) == "Everyday")
    // VoiceOver hears the digits as words.
    #expect(ListedAccount.named("Plaid Checking", nickname: nil, institution: "Wells Fargo", mask: "0000", spoken: true) == "Wells Fargo ending in 0000")
}

/// One account with a nickname and no owner answer, in a fresh in-memory file.
private func databaseWithOneAccount() throws -> (SedgeDatabase, ListedAccount) {
    let database = try SedgeDatabase()
    let json = #"[{"account_id": "chk", "name": "Plaid Checking", "mask": "0000", "type": "depository", "subtype": "checking", "balances": {}}]"#
    try database.save(accounts: JSONDecoder().decode([Account].self, from: Data(json.utf8)), transactions: [], asOf: "2026-06-30")
    try Answers.setNickname("Everyday", account: "chk", in: database)
    return (database, try #require(try ListedAccount.all(in: database).first))
}

/// Answering on the Accounts screen saves the same owner and name as the account check does
/// when its name field is left as it was (it starts from the saved name).
@Test func answeringInPlaceSavesWhatTheCheckSaves() throws {
    for owner in [Answers.Owner.mine, .shared, nil] {
        let (inPlace, account) = try databaseWithOneAccount()
        let (check, _) = try databaseWithOneAccount()
        try AccountsListView.save(owner, for: account, in: inPlace)
        // What the account check saved before the two shared a save: its untouched name field,
        // then the owner unless the answer is Decide later.
        try Answers.setNickname(account.nickname ?? "", account: account.account_id, in: check)
        if let owner { try Answers.setOwner(owner, account: account.account_id, in: check) }
        let saved = try #require(try ListedAccount.all(in: inPlace).first)
        let checked = try #require(try ListedAccount.all(in: check).first)
        #expect(saved.owner == checked.owner && saved.nickname == checked.nickname)
        #expect(saved.owner == owner?.rawValue && saved.nickname == "Everyday")
    }
}

/// Later saves no owner, so the account is still one to answer at the top of the screen.
@Test func laterKeepsTheAccountAtTheTop() throws {
    let (database, account) = try databaseWithOneAccount()
    try AccountsListView.save(nil, for: account, in: database)
    #expect(try ListedAccount.all(in: database).filter { $0.owner == nil }.map(\.id) == ["chk"])
    try AccountsListView.save(.mine, for: account, in: database)
    #expect(try ListedAccount.all(in: database).filter { $0.owner == nil }.isEmpty)
}

/// Connecting saves the bank's name in the bank file, so the account reads "<bank> ••<last 4>";
/// a file without that name (a sample person's) keeps the account's own name.
@Test func connectingSavesTheBankName() async throws {
    let json = #"[{"account_id": "chk", "name": "Plaid Checking", "mask": "0000", "type": "depository", "subtype": "checking", "balances": {}}]"#
    let accounts = try JSONDecoder().decode([Account].self, from: Data(json.utf8))
    let bank = try SedgeDatabase()
    let failure = await finishConnecting(publicToken: "public-test", institution: "Wells Fargo", database: bank,
                                         exchange: { _ in },
                                         sync: { try $0.save(accounts: accounts, transactions: [], asOf: "2026-06-30") })
    #expect(failure == nil)
    #expect(try ListedAccount.all(in: bank).map { $0.displayName() } == ["Wells Fargo ••0000"])
    let noName = try SedgeDatabase()
    try noName.save(accounts: accounts, transactions: [], asOf: "2026-06-30")
    #expect(try ListedAccount.all(in: noName).map { $0.displayName() } == ["Plaid Checking ••0000"])
}

/// Connects one account with the given bank name and returns how the app names it.
private func accountNameAfterConnecting(institution: String) async throws -> [String] {
    let json = #"[{"account_id": "chk", "name": "Plaid Checking", "mask": "0000", "type": "depository", "subtype": "checking", "balances": {}}]"#
    let accounts = try JSONDecoder().decode([Account].self, from: Data(json.utf8))
    let bank = try SedgeDatabase()
    let failure = await finishConnecting(publicToken: "public-test", institution: institution, database: bank,
                                         exchange: { _ in },
                                         sync: { try $0.save(accounts: accounts, transactions: [], asOf: "2026-06-30") })
    #expect(failure == nil)
    return try ListedAccount.all(in: bank).map { $0.displayName() }
}

/// Link sends "" when it has no bank name; that must not replace the account's own name.
@Test func emptyBankNameFallsBackToAccountName() async throws {
    let names = try await accountNameAfterConnecting(institution: "")
    #expect(names == ["Plaid Checking ••0000"])
}

/// A name of only spaces counts as no name too, the same as a blank nickname.
@Test func blankBankNameFallsBackToAccountName() async throws {
    let names = try await accountNameAfterConnecting(institution: "   ")
    #expect(names == ["Plaid Checking ••0000"])
}
