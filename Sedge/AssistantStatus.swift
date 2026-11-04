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

    /// "Start new session": clears the conversation so the person can ask again.
    func startNewSession() {
        turns = []
        status = .idle
    }
}
