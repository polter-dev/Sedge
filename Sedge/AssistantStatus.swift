//
//  AssistantStatus.swift
//  Sedge
//

import Observation

/// What the assistant is doing, as the Ask screen shows it. The on-device model's loop reports
/// it through `ChatSession.report(_:)`.
enum AssistantStatus: Equatable {
    /// Nothing in progress: the person can ask.
    case idle
    /// Working out an answer to the newest question. The screen shows the thinking row.
    case thinking
    /// The chat is as long as it can get. The screen shows the limit turn and "Start new session".
    case tokenLimitReached
}

/// One conversation on the Ask screen: its turns and what the assistant is doing.
/// `@Observable` makes SwiftUI redraw the screen whenever either changes.
@Observable final class ChatSession {
    var turns: [ChatTurn] = []
    /// The saved chat (`Chats`) these turns belong to, or nil until its first turn is saved.
    var chatID: Int64?
    /// The title of an older chat opened from Previous chats, or nil for a chat started here.
    /// While it is set, the screen's title is the chat's.
    private(set) var reopenedTitle: String?
    private(set) var status = AssistantStatus.idle
    /// The words next to the thinking row's sprout, picked when thinking starts and changed
    /// every `phraseSeconds` while it lasts.
    private(set) var phrase = ""
    /// Seconds each phrase shows before the next one pushes it out, as in the design.
    static let phraseSeconds = 2.2
    /// A question the model asked with `ask_user`, shown as a quick check while the answer waits,
    /// and how to hand the person's tap back (nil for "Later").
    private(set) var pendingCheck: (check: QuickCheck, reply: (String?) -> Void)?

    /// Shows `check` and waits for the person's tap. The `ask_user` tool calls this through `AskPerson`.
    func ask(_ check: QuickCheck) async -> String? {
        await withCheckedContinuation { continuation in
            pendingCheck = (check, { continuation.resume(returning: $0) })
        }
    }

    /// Hands the tap (or nil) to the waiting question and takes the card away. Resumes it only once.
    func answerCheck(_ reply: String?) {
        let pending = pendingCheck
        pendingCheck = nil
        pending?.reply(reply)
    }

    /// The design's ten placeholder phrases for the thinking row.
    static let phrases = [
        "Understanding your money…",
        "Checking your transactions…",
        "Looking at this month…",
        "Adding things up…",
        "Comparing with your usual…",
        "Sorting out the details…",
        "Reading your accounts…",
        "Finding the pattern…",
        "Double-checking the numbers…",
        "Nearly there…",
    ]

    /// Shows a new status. Starting to think picks a new phrase, never the one shown last time.
    func report(_ new: AssistantStatus) {
        if new == .thinking, status != .thinking { nextPhrase() }
        status = new
    }

    /// While thinking, moves to a new phrase every `phraseSeconds`, never the one just shown.
    /// It returns once thinking ends, or when the calling task is cancelled because the thinking
    /// row went away. Tests pass their own `sleep` so they can step through without waiting.
    func cyclePhrases(sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async {
        while status == .thinking, (try? await sleep(.seconds(Self.phraseSeconds))) != nil, status == .thinking {
            nextPhrase()
        }
    }

    /// Picks one of the ten phrases at random, skipping the one showing now.
    private func nextPhrase() {
        phrase = Self.phrases.filter { $0 != phrase }.randomElement()!
    }

    /// "Start new session" and New chat: clears the conversation so the person can ask again.
    /// The chat so far stays saved in Previous chats.
    func startNewSession() {
        // A question still waiting on a quick check carries on as if skipped; its turn is gone.
        answerCheck(nil)
        turns = []
        chatID = nil
        reopenedTitle = nil
        status = .idle
    }

    /// Shows an older chat from Previous chats. New questions are added to it.
    func open(_ chat: Int64, titled title: String, turns: [ChatTurn]) {
        answerCheck(nil)
        self.turns = turns
        chatID = chat
        reopenedTitle = title
        status = .idle
    }
}
