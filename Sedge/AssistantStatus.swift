//
//  AssistantStatus.swift
//  Sedge
//

import Observation

/// What the assistant is doing, as the Ask screen shows it. Whatever answers questions reports
/// it through `ChatSession.report(_:)`; until something does, the screen reports it itself.
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
    /// While it is set, the screen shows the "answers best in a new chat" banner.
    private(set) var reopenedTitle: String?
    private(set) var status = AssistantStatus.idle
    /// The words next to the thinking row's sprout, picked when thinking starts.
    private(set) var phrase = ""

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

    /// Shows a new status. Starting to think picks a new phrase, never the one shown last time;
    /// it stays the same while the answer is worked out.
    func report(_ new: AssistantStatus) {
        if new == .thinking, status != .thinking {
            phrase = Self.phrases.filter { $0 != phrase }.randomElement()!
        }
        status = new
    }

    /// "Start new session" and New chat: clears the conversation so the person can ask again.
    /// The chat so far stays saved in Previous chats.
    func startNewSession() {
        turns = []
        chatID = nil
        reopenedTitle = nil
        status = .idle
    }

    /// Shows an older chat from Previous chats. New questions are added to it.
    func open(_ chat: Int64, titled title: String, turns: [ChatTurn]) {
        self.turns = turns
        chatID = chat
        reopenedTitle = title
        status = .idle
    }
}
