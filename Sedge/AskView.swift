//
//  AskView.swift
//  Sedge
//

import Charts
import GRDB
import SedgeCore
import SwiftUI

// MARK: - What a conversation shows

// These types only say what the Ask screen draws. The on-device model's answers fill them in.

/// One question from the person and Sedge's answer to it.
struct ChatTurn: Identifiable {
    let id = UUID()
    /// What the person asked.
    var question: String
    /// Sedge's reply, or nil while it is still being worked out.
    var answer: ChatAnswer?
}

/// Sedge's reply: a lead, an optional bold point, a smaller detail line, and optional extras.
/// Codable so a saved chat keeps each answer whole (`Chats` stores it as JSON).
struct ChatAnswer: Codable {
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
    /// The words of a link to the cash-flow screen, e.g. "Compare a small change →".
    var whatIfLink: String?
    /// A question back to the person, answered with a tap.
    var quickCheck: QuickCheck?
}

/// One labeled dollar amount: a bar in a breakdown card or a chart.
struct ChatBar: Identifiable, Codable {
    var label: String
    var amount: Double
    var id: String { label }
}

/// A spending card: a title and period, the total, how it compares, and a bar per part.
struct Breakdown: Codable {
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
struct QuickCheck: Codable {
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

/// The Ask screen's chat and the question it is working out. ContentView owns it, so it lasts through tab
/// switches, and ends it when other data is picked.
final class AskScreenState {
    let session = ChatSession()
    var question: Task<Void, Never>?

    /// Stops the question still running, so it holds no GPU or memory, and lets the screen it kept awake lock again.
    /// Called directly rather than from a deinit: once the question box was typed in, the window's scroll edge effect
    /// keeps the old box alive after the screen goes, and the box's SwiftUI settings hold this state, so a deinit never ran.
    func end() {
        question?.cancel()
        UIApplication.shared.isIdleTimerDisabled = false
        session.startNewSession() // a quick check still waiting takes "Later", so the question can end
    }
}

/// Ask a question about the chosen data, as a chat. The on-device model answers each question on
/// its own (as in the benchmark) while the thinking row shows; the first question asks to download
/// the model, and asking waits until it is here. Debug builds launched with `-sampleChat YES` show
/// the design's sample conversation, worked out from this data; `-demoThinking YES` and
/// `-demoTokenLimit YES` show the thinking row and the limit turn. Each settled question is saved
/// to the dataset's own file (`Chats`), so Previous chats can reopen it; the model never sees saved turns.
struct AskView: View {
    let database: SedgeDatabase
    /// The chat and its running question, owned by ContentView (see `AskScreenState`).
    let screen: AskScreenState
    /// The question box's text, owned by the tabs so Trends can type a question in for the person.
    @Binding var question: String
    /// Tells the tabs whether an older chat is on screen, so its title doesn't offer the data's Rename menu.
    @Binding var reopened: Bool
    /// Goes up by one each time Trends hands Ask a question; each time, a chat in use makes way for an empty one.
    var newChatRequests = 0
    /// Switches the main tab, for the card's trends link.
    var open: (MainTab) -> Void = { _ in }
    private var session: ChatSession { screen.session }
    /// True when the turns are demo content, which is never saved.
    @State private var isDemo = false
    /// True once the Debug demo state was set up, so coming back to the tab doesn't bring it back.
    @State private var demoLoaded = false
    @State private var showingChats = false
    /// Where the chat is scrolled to, so a new turn or a reopened chat can jump to its end.
    @State private var position = ScrollPosition()
    /// True while the "needs its on-device model" question is up.
    @State private var askingToDownload = false
    private let onDevice = OnDeviceModel.shared
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var blank: Bool { question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var limited: Bool { session.status == .tokenLimitReached }
    /// True while Ask shows the model's screen (declined, downloading or failed) instead of the chat.
    private var needsModel: Bool { onDevice.state != .ready && onDevice.state != .missing }
    /// One question at a time: sending waits until the last answer is in, and until the model is here.
    private var canSend: Bool { !blank && session.status == .idle && !needsModel }

    private var reduceMotion: Bool { Self.reducesMotion(system: systemReduceMotion) }

    /// The person's Reduce Motion setting (`system`). Debug builds launched with
    /// `-reduceMotion YES` act as if it were on, because a UI test can't switch the setting itself.
    /// Previous chats uses it too, so both screens follow the same rule.
    static func reducesMotion(system: Bool) -> Bool {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "reduceMotion") { return true }
        #endif
        return system
    }

    var body: some View {
        ScrollView {
            // Not lazy: jumping to the end needs every turn's real height, and a chat is short.
            VStack(alignment: .leading, spacing: 0) {
                if session.reopenedTitle != nil {
                    NewChatBanner(newChat: newChat)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                }
                ForEach(session.turns) { TurnView(turn: $0, database: database, open: open) }
                // Both fade in over 0.25 seconds like any answer; Reduce Motion keeps the fade.
                // While the model waits on an `ask_user` question, its quick check stands in for the thinking row.
                if session.status == .thinking, let pending = session.pendingCheck {
                    QuickCheckCard(check: pending.check) { reply in
                        session.answerCheck(reply)
                        return "Saving…"
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .transition(.opacity)
                } else if session.status == .thinking {
                    ThinkingRow(phrase: session.phrase, moves: !reduceMotion)
                        // Changes the phrase every 2.2 seconds; ends when the row goes away.
                        .task { await session.cyclePhrases() }
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                        .transition(.opacity)
                }
                if limited {
                    LimitTurn(startNewSession: newChat, openChats: showChats)
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.25), value: session.status)
            // A plain VStack is only as wide as its widest line and the ScrollView centers it, so
            // a chat of short lines sat right of the margin. Full width keeps every chat at the left.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 16)
        }
        // A sent question, its answer and a reopened chat each jump to the end, so the newest turn
        // sits just above the question box. A bottom anchor alone left it behind the keyboard.
        .scrollPosition($position)
        // Any drag on the chat puts the keyboard away. Interactively, the finger first had to
        // travel down past the question box to reach the keyboard.
        .scrollDismissesKeyboard(.immediately)
        .overlay {
            if needsModel {
                // Covers the chat: nothing can be asked until the model is here.
                ModelScreen(state: onDevice.state, gigabytes: onDevice.gigabytes, download: onDevice.download)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.background)
            } else if session.turns.isEmpty && session.status == .idle {
                ContentUnavailableView {
                    Label("Ask about your money", image: "tab-ask")
                } description: {
                    ExampleQuestion(rotates: !reduceMotion, ask: ask).foregroundStyle(Color.muted)
                }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        .background(Color.background)
        // An older chat shows its own title, as in the design.
        .navigationTitle(session.reopenedTitle ?? "Ask Sedge")
        .toolbar {
            // Both symbols in one color: the app's two-color foregroundStyle would paint their
            // second layer `muted`, which fades on the dark top bar.
            ToolbarItem(placement: .topBarLeading) {
                Button("Previous chats", systemImage: "clock.arrow.circlepath", action: showChats)
                    .symbolRenderingMode(.monochrome)
                    // Opening another chat mid-answer would save that answer into the wrong chat.
                    .disabled(session.status == .thinking)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("New chat", systemImage: "square.and.pencil", action: newChat)
                    .symbolRenderingMode(.monochrome)
            }
        }
        .alert("Sedge needs its on-device model", isPresented: $askingToDownload) {
            Button("Download") { onDevice.download() }
            Button("Not now", role: .cancel) { onDevice.decline() }
        } message: {
            Text("About \(onDevice.gigabytes) GB, downloaded once.")
        }
        .fullScreenCover(isPresented: $showingChats) {
            // Deleting the chat on screen starts a new one, so the next question isn't saved
            // into a chat that is gone.
            PreviousChatsView(database: database, openID: session.chatID, open: openChat) {
                if $0 == session.chatID { newChat() }
            }
        }
        .onChange(of: session.reopenedTitle) { reopened = $1 != nil }
        // An empty chat is reused, so the handed question doesn't leave a blank chat behind.
        .onChange(of: newChatRequests) { if !session.turns.isEmpty || session.status != .idle { newChat() } }
        // A turn is saved once it settles: its answer came in, or the chat hit its limit. Watching
        // the status means whatever answers questions only has to report it.
        .onChange(of: session.status) { old, new in
            if old == .thinking { saveNewestTurn() }
            // iOS allows no GPU work once the phone locks, so the screen stays on while the model works.
            UIApplication.shared.isIdleTimerDisabled = new == .thinking
            // Covers sending (the thinking row appears) and the answer coming in.
            position.scrollTo(edge: .bottom)
        }
        .task {
            #if DEBUG
            // `.task` runs each time the tab shows, so the demo state is only set up once.
            guard !demoLoaded else { return }
            demoLoaded = true
            let defaults = UserDefaults.standard
            if defaults.bool(forKey: "sampleChat") {
                do {
                    session.turns = [try ChatTurn.sample(in: database)]
                    isDemo = true
                } catch {
                    print("Could not make the sample conversation:", error)
                }
            }
            if defaults.bool(forKey: "demoThinking") {
                // A question still being worked out, held there for screenshots and UI tests.
                session.turns.append(ChatTurn(question: "What about coffee?", answer: nil))
                session.report(.thinking)
                isDemo = true
            }
            if defaults.bool(forKey: "demoTokenLimit") {
                session.report(.tokenLimitReached)
                isDemo = true
            }
            #endif
        }
    }

    /// The question box with its send button.
    private var composer: some View {
        HStack(alignment: .bottom, spacing: 2) {
            TextField("Question", text: $question,
                      prompt: Text(limited ? "Start a new session to keep asking" : "Ask about your money…")
                          .foregroundStyle(Color.muted),
                      axis: .vertical)
                .font(.subheadline)
                .lineLimit(1...5)
                .padding(.vertical, 12)
                .onSubmit(send)
                // At the limit, or without the model, the box stays in place but takes no typing.
                .disabled(limited || needsModel)
            Button("Send", image: .chatSend, action: send)
                .labelStyle(.iconOnly)
                .foregroundStyle(canSend ? Color.contrast : Color.muted)
                // The glow: an accent circle with a soft accent shadow fades in behind the arrow.
                .background {
                    Circle()
                        .fill(Color.accent)
                        .frame(width: 34, height: 34)
                        .shadow(color: Color.accent.opacity(0.35), radius: 8)
                        .opacity(canSend ? 1 : 0)
                }
                .animation(.easeInOut(duration: 0.25), value: canSend)
                // Apple's minimum tap area, around the 20-point arrow.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .disabled(!canSend)
        }
        .padding(.leading, 16)
        .padding(.trailing, 2)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 23))
        .overlay(RoundedRectangle(cornerRadius: 23).stroke(Color.line))
        // While there is text, a soft underlay springs up 8 points beyond the box on every side.
        // As a background it grows with the box when the question wraps to more lines.
        .background {
            if !blank {
                RoundedRectangle(cornerRadius: 31)
                    .fill(Color.soft)
                    .padding(-8)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        .animation(blank || reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.7),
                   value: blank)
        .padding(.horizontal, 14)
        // The underlay's 8 points above and below, so it stays on this bar's background.
        .padding(.vertical, 8)
        .background(Color.background)
    }

    /// New chat (toolbar, banner and "Start new session"): an empty screen, ready for a question.
    private func newChat() {
        session.startNewSession()
        isDemo = false
    }

    /// Shows the Previous chats panel. The cover appears without the system's slide-up, so the
    /// panel can slide in from the left by itself.
    private func showChats() {
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { showingChats = true }
    }

    /// Saves the newest turn to the open chat, starting a saved chat on its first turn.
    /// Demo content is never saved.
    private func saveNewestTurn() {
        guard !isDemo, let turn = session.turns.last else { return }
        let answer = turn.answer.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        do {
            // The clock's time is only the label Previous chats shows.
            session.chatID = try Chats.append(question: turn.question, answer: answer, to: session.chatID,
                                              at: .now, in: database)
        } catch {
            print("Could not save the chat:", error)
        }
    }

    /// Shows a chat picked in Previous chats, with its saved answers.
    private func openChat(_ chat: Chats.Chat) {
        do {
            let turns = try Chats.turns(of: chat.id, in: database).map { saved in
                ChatTurn(question: saved.question,
                         answer: saved.answer.flatMap { try? JSONDecoder().decode(ChatAnswer.self, from: Data($0.utf8)) })
            }
            session.open(chat.id, titled: chat.title, turns: turns)
            isDemo = false
            position.scrollTo(edge: .bottom)
        } catch {
            print("Could not open the chat:", error)
        }
    }

    /// Asks `example` as if it were typed and sent.
    private func ask(_ example: String) {
        question = example
        send()
    }

    private func send() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        // The first question asks before downloading; the question stays in the box.
        guard onDevice.state == .ready else {
            askingToDownload = true
            return
        }
        let turn = ChatTurn(question: text, answer: nil)
        session.turns.append(turn)
        session.report(.thinking)
        question = ""
        // `ask_user` shows its question as a quick check and waits for the tap.
        let askPerson: AskPerson = { [session, id = turn.id] clarification in
            // After New chat the old question carries on unseen; it takes "Later" rather than show its card in the new chat.
            guard await session.turns.contains(where: { $0.id == id }) else { return nil }
            return await session.ask(QuickCheck(question: clarification.question, details: [], options: clarification.options,
                                         factKey: clarification.factKey))
        }
        // The question captures only what it needs, not this view, so the screen's state can go while it runs.
        screen.question = Task { [session, database, onDevice] in
            let outcome: Assistant.Outcome?
            do {
                outcome = await Assistant.run(text, database: database, model: try await onDevice.model(for: text), askPerson: askPerson)
            } catch {
                print("Could not load the on-device model:", error)
                outcome = nil
            }
            // The turn is gone if "Start new session" cleared the chat in the meantime.
            guard let index = session.turns.firstIndex(where: { $0.id == turn.id }) else { return }
            switch outcome {
            case .answer(let answer):
                // The value leads (a figure, a date, a name); the note is the plain sentence under it.
                session.turns[index].answer = answer.value.isEmpty
                    ? ChatAnswer(lead: answer.note)
                    : ChatAnswer(lead: answer.value, detail: answer.note.isEmpty ? nil : answer.note)
                session.report(.idle)
            case .contextFull:
                session.report(.tokenLimitReached)
            case .stepLimit, .crashed, nil:
                session.turns[index].answer = ChatAnswer(lead: "Sedge couldn't work that one out.")
                session.report(.idle)
            }
        }
    }
}

/// The empty screen's example question, a button that asks it. Each one stays 4 seconds, then
/// crossfades to the next, looping through all six. When `rotates` is false (Reduce Motion) it
/// keeps the first one.
private struct ExampleQuestion: View {
    let rotates: Bool
    let ask: (String) -> Void
    @State private var index = 0

    static let questions = [
        "How much did I spend at Netflix this year?",
        "What did groceries cost me last month?",
        "Have I been overspending on food?",
        "How much have I saved since January?",
        "What did rent and utilities cost in May?",
        "How much do I spend on coffee each month?",
    ]

    var body: some View {
        Button { ask(Self.questions[index]) } label: {
            ZStack {
                // Invisible copies of every question keep the slot as tall as the tallest one,
                // so the screen doesn't jump when a longer question wraps at large text sizes.
                ForEach(Self.questions, id: \.self) { chip($0).hidden() }
                // A new id makes this a new view, so the old question fades out as the new one fades in.
                chip(Self.questions[index])
                    .background(Color.surface, in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.line))
                    .id(index)
                    .transition(.asymmetric(insertion: .opacity.animation(.easeIn(duration: 0.3)),
                                            removal: .opacity.animation(.easeOut(duration: 0.3))))
            }
        }
        // Plain keeps the muted words; the default style would tint them the accent color.
        .buttonStyle(.plain)
        .accessibilityIdentifier("exampleQuestion")
        .task(id: rotates) {
            guard rotates else { index = 0; return }
            // 4 seconds fully shown plus the 0.3-second fade. Sleeping throws once the screen
            // goes away, which ends the loop.
            while (try? await Task.sleep(for: .seconds(4.3))) != nil {
                withAnimation { index = (index + 1) % Self.questions.count }
            }
        }
    }

    /// A question's words with the chip's inner space, so the chip looks like a suggestion.
    private func chip(_ text: String) -> some View {
        Text(text).padding(.horizontal, 14).padding(.vertical, 8)
    }
}

/// The card at the top of an older chat: it can be continued, but a new chat answers best.
/// Side by side as in the design; at the largest text sizes the button goes under the words.
private struct NewChatBanner: View {
    let newChat: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { words; Spacer(minLength: 0); button }
            VStack(alignment: .leading, spacing: 0) { words.padding(.top, 12); button }
        }
        .padding(.leading, 13)
        .padding(.trailing, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.group, in: RoundedRectangle(cornerRadius: 12))
    }

    private var words: some View {
        Text("Sedge answers best in a new chat.").font(.footnote)
    }

    private var button: some View {
        Button(action: newChat) {
            Text("New chat")
                .font(.link)
                .padding(.horizontal, 10)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accent)
        // The toolbar has a "New chat" button too, so UI tests find this one by its id.
        .accessibilityIdentifier("bannerNewChat")
    }
}

/// "Sedge" with its sprout, above each of Sedge's replies.
private struct SedgeHeader: View {
    var body: some View {
        HStack(spacing: 7) {
            Image(.chatSedge).accessibilityHidden(true)
            Text("Sedge").font(.row.weight(.semibold))
        }
        .foregroundStyle(Color.chartNow)
    }
}

/// Shown while an answer is worked out: the sprout drawing itself next to a phrase that a light
/// band sweeps across, with a new phrase pushing up every 2.2 seconds. Side by side as in the
/// design; when the phrase doesn't fit beside it (largest text sizes) it wraps underneath.
struct ThinkingRow: View {
    /// Seconds for the light band to cross the phrase once, as in the design.
    static let shimmerSeconds = 1.9

    let phrase: String
    /// False with Reduce Motion: the sprout stays still, nothing sweeps, and phrases cross-fade.
    let moves: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { sprout; words }
            VStack(alignment: .leading, spacing: 4) { sprout; words }
        }
        .frame(minHeight: 28)
    }

    private var sprout: some View { ThinkingSprout(draws: moves) }

    private var words: some View {
        ZStack(alignment: .leading) {
            TimelineView(.animation(paused: !moves)) { context in
                Text(phrase).font(.footnote).foregroundStyle(shimmer(at: context.date))
            }
            // A new id makes each phrase a new view, so the old one leaves as the new one arrives.
            .id(phrase)
            .transition(moves ? .push(from: .bottom) : .opacity)
        }
        .clipped() // keeps the sliding phrases inside the row
        .animation(moves ? .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.45) : .easeInOut(duration: 0.3), value: phrase)
        // One element that reads the current phrase. It stays the same element as phrases change,
        // so VoiceOver keeps its place and doesn't announce each new phrase.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(phrase)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityIdentifier("thinkingRow")
    }

    /// The phrase's color: muted, with a band of ink sweeping left to right every `shimmerSeconds`.
    /// Without motion the band waits off the left edge, so the phrase is plain muted.
    private func shimmer(at date: Date) -> LinearGradient {
        let sweep = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.shimmerSeconds) / Self.shimmerSeconds
        // The band's middle, in fractions of the phrase's width: it starts just off the left edge
        // and ends just off the right, so it enters and leaves whole.
        let middle = moves ? -0.25 + 1.5 * sweep : -1
        return LinearGradient(colors: [.muted, .ink, .muted],
                              startPoint: UnitPoint(x: middle - 0.25, y: 0.5),
                              endPoint: UnitPoint(x: middle + 0.25, y: 0.5))
    }
}

/// The turn shown when the chat reaches its length limit (design B4 tinted): a `group` card, not
/// an error, with a button that clears the chat so the person can keep asking and one that opens
/// Previous chats. The tints are `amountNow` and `nodeStore`; the 10 % fill is opacity only.
private struct LimitTurn: View {
    let startNewSession: () -> Void
    let openChats: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(.chatSedge).resizable().frame(width: 20, height: 20)
                    .foregroundStyle(Color.amountNow)
                    .accessibilityHidden(true)
                Text("This chat is full").font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
            }
            Text("Sedge has reached its limit for this chat. Start a new session to keep asking; this one stays in Previous chats.")
                .font(.footnote)
                .foregroundStyle(Color.muted)
                .padding(.bottom, 4)
            button("Start new session", weight: .semibold, fill: Color.nodeStore, action: startNewSession)
            button("Open previous chats", weight: .medium, fill: Color.amountNow.opacity(0.1), action: openChats)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.group, in: RoundedRectangle(cornerRadius: 14))
    }

    /// A full-width 44-point button with an `amountNow` label on a tinted fill.
    private func button(_ title: String, weight: Font.Weight, fill: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(weight))
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.amountNow)
        .background(fill, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// One turn as the design draws it: the breakdown card, the question, the answer, then the quick check.
private struct TurnView: View {
    let turn: ChatTurn
    let database: SedgeDatabase
    let open: (MainTab) -> Void
    /// Paper and Carbon Soft rule the breakdown card differently.
    @Environment(\.colorScheme) private var colorScheme

    /// The design's label and amount columns, grown with the reader's text size.
    @ScaledMetric(relativeTo: .caption) private var labelWidth = 70.0
    @ScaledMetric(relativeTo: .caption) private var amountWidth = 45.0

    private var dark: Bool { colorScheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let breakdown = turn.answer?.breakdown {
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

            // Until the answer is in, the screen shows the thinking row below the question instead.
            if let answer = turn.answer {
                VStack(alignment: .leading, spacing: 0) {
                    SedgeHeader().padding(.bottom, 10)

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
                            CashFlowView(database: database).navigationTitle("Cash flow")
                        } label: {
                            Text(link).font(.link).frame(minHeight: 44)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 29)

                if let check = answer.quickCheck {
                    QuickCheckCard(check: check) { await save(check, $0) }
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                }
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
                        .fill(Color.nodeStore)
                        .frame(height: 7)
                        .overlay(alignment: .leading) {
                            GeometryReader { space in
                                Capsule().fill(Color.chartNow)
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

    /// Sends the tap through `ask_user`, which saves a reply and skips saving "Later" (nil), and
    /// returns the line the card shows in place of its buttons.
    private func save(_ check: QuickCheck, _ option: String?) async -> String {
        let input = try? JSONSerialization.data(withJSONObject: [
            "question": check.question, "options": check.options, "fact_key": check.factKey,
        ])
        var result = await AskUser.run(input ?? Data(), database: database) { _ in option }
        // `ask_user` hands back a saved answer without asking. A tap is the person answering
        // again, so forget the old answer and save the tapped one. "Later" keeps the old one.
        if option != nil, let old = result.clarification, old.answeredFromMemory {
            try? AskUser.forget(old.factKey, in: database)
            result = await AskUser.run(input ?? Data(), database: database) { _ in option }
        }
        if let saved = result.clarification?.answer {
            return "Saved: \(saved). Change it in Accounts › Saved answers."
        } else if result.clarification != nil {
            return "Not saved. It may be asked again."
        } else {
            return "Couldn't save the answer."
        }
    }
}

/// A short question for the person with a button per reply and "Later" (design: a quick check).
/// A tap goes to `choose`, and the line it returns replaces the buttons. Used for an answer's
/// quick check and for a question the model asks with `ask_user` while its answer waits.
struct QuickCheckCard: View {
    let check: QuickCheck
    let choose: (String?) async -> String
    /// What the tap got back, shown in place of the buttons.
    @State private var reply: String?
    /// Paper and Carbon Soft use different fills for the other buttons.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
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
                    HStack(spacing: 6) { buttons }
                    VStack(spacing: 6) { buttons }
                }
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.group, in: RoundedRectangle(cornerRadius: 14))
    }

    /// The replies (the first filled in, as the likely one), then "Later".
    @ViewBuilder private var buttons: some View {
        let choices: [String?] = check.options + [nil]
        ForEach(Array(choices.enumerated()), id: \.offset) { index, option in
            Button {
                // Hides the buttons at once, so a second quick tap can't send a different reply.
                reply = "Saving…"
                Task { reply = await choose(option) }
            } label: {
                Text(option ?? "Later")
                    .font(.row)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(index == 0 ? Color.onNodeCategory : Color.accent)
            .background(index == 0 ? Color.nodeCategory : (colorScheme == .dark ? Color.soft : Color.surface),
                        in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// What Ask shows instead of the chat while the on-device model isn't here: the offer to download
/// it (after "Not now"), the download's progress, or a stopped download with Try again.
private struct ModelScreen: View {
    let state: OnDeviceModel.State
    let gigabytes: Int
    let download: () -> Void

    var body: some View {
        switch state {
        case .downloading(let fraction):
            ContentUnavailableView {
                Label("Downloading the on-device model", image: "tab-ask")
            } description: {
                VStack(spacing: 8) {
                    ProgressView(value: fraction).frame(maxWidth: 220)
                    Text(fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                }
                .foregroundStyle(Color.muted)
            }
        case .failed:
            ContentUnavailableView {
                Label("The download stopped", image: "tab-ask")
            } description: {
                Text("Sedge needs its on-device model to answer.").foregroundStyle(Color.muted)
            } actions: {
                Button("Try again", action: download)
            }
        default:
            ContentUnavailableView {
                Label("Sedge needs its on-device model", image: "tab-ask")
            } description: {
                Text("About \(gigabytes) GB, downloaded once.").foregroundStyle(Color.muted)
            } actions: {
                Button("Download", action: download)
            }
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
    /// content, which is why it is never saved as a chat.
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
        struct Move: Decodable, FetchableRecord { let date, store, kind: String; let amount: Double }
        // Read the table itself: `find_transactions` gives only the newest 10 rows, which can miss
        // the largest (Jordan has 18 June rows of $100 or more). Same store name as the tool shows.
        guard let move = try database.dbQueue.read({ db in
            try Move.fetchOne(db, sql: """
                SELECT t.date, COALESCE(m.name, t.name) AS store, t.kind, ROUND(t.amount, 2) AS amount
                FROM transactions t LEFT JOIN entities m ON m.id = t.merchant_id
                WHERE t.date BETWEEN ? AND ? AND t.kind IN ('transfer', 'card_payment') AND t.amount > 0
                ORDER BY t.amount DESC, t.date DESC LIMIT 1
                """, arguments: [start, end])
        }) else { return nil }
        let what = move.kind == "card_payment" ? "card payment" : "transfer"
        return QuickCheck(
            question: "Was this \(move.amount.formatted(.currency(code: "USD"))) \(what) between your accounts?",
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
        AskView(database: try! SedgeDatabase(), screen: AskScreenState(), question: .constant(""), reopened: .constant(false))
            .navigationBarTitleDisplayMode(.inline)
    }
}
