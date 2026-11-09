//
//  PreviousChatsView.swift
//  Sedge
//

import SedgeCore
import SwiftUI

/// Previous chats: a 300-point panel that springs in from the left over Ask, with the screen
/// dimmed behind it. It follows a finger dragged left and closes on a swipe or a tap on the dimmed
/// screen. Every saved chat in this dataset is listed in month cards, most recently used first.
/// Edit puts a minus circle on each row; it shows a Delete in the card, which asks first.
/// Ask presents it as a full-screen cover without the system animation, so the panel covers the
/// top and tab bars and moves by itself.
struct PreviousChatsView: View {
    let database: SedgeDatabase
    /// The chat on the Ask screen, marked with a dot.
    let openID: Int64?
    /// Opens the tapped chat on the Ask screen.
    let open: (Chats.Chat) -> Void
    /// Told each deleted chat's id, so Ask can leave a chat that no longer exists.
    let deleted: (Int64) -> Void
    @State private var chats: [Chats.Chat] = []
    /// False until the panel has sprung in, and again while it moves out.
    @State private var shown = false
    /// How far left a finger has dragged the panel; springs back to 0 when the finger lifts.
    @GestureState(wrappedValue: 0, resetTransaction: Transaction(animation: Self.openSpring))
    private var drag: CGFloat
    @State private var editing = false
    /// The row whose minus circle was tapped, so it shows Delete.
    @State private var armed: Int64?
    /// The chat the confirmation dialog asks about.
    @State private var confirming: Chats.Chat?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Ask's rule, so `-reduceMotion YES` fades the panel in UI tests as the setting does.
    private var reduceMotion: Bool { AskView.reducesMotion(system: systemReduceMotion) }

    private static let panelWidth: CGFloat = 300
    /// Opening and springing back settle with a little overshoot; closing and edits don't.
    private static let openSpring = Animation.spring(duration: 0.45, bounce: 0.18)
    private static let closeSpring = Animation.spring(duration: 0.3, bounce: 0)
    /// Reduce Motion replaces every slide with a cross-fade.
    private var fade: Animation { .easeInOut(duration: 0.25) }

    /// The chats last used in one month, under a label such as "JUNE".
    struct Month {
        let title: String
        var chats: [Chats.Chat]
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // The scrim: `ink` at 35 %, as drawn, dimming less as the panel is dragged away.
            // Tapping it closes the panel.
            Color.ink.opacity(shown ? 0.35 * (1 + min(drag, 0) / Self.panelWidth) : 0)
                .ignoresSafeArea()
                .gesture(dragToClose(tapCloses: true))
                .accessibilityLabel("Close")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(.default, close)
            // Always in the tree, parked off the left edge until `shown`, so the open and close
            // springs and the drag all move one view instead of inserting and removing it.
            if reduceMotion {
                panel.opacity(shown ? 1 : 0)
            } else {
                panel.offset(x: shown ? drag : -Self.panelWidth)
            }
        }
        .presentationBackground(.clear)
        // VoiceOver's two-finger scrub closes it, like a sheet.
        .accessibilityAction(.escape, close)
        .onAppear {
            // Read before the panel moves, so the cards ride in with it instead of popping in later.
            do { chats = try Chats.list(in: database) } catch { print("Could not list the chats:", error) }
            withAnimation(reduceMotion ? fade : Self.openSpring) { shown = true }
        }
        .confirmationDialog("Delete “\(confirming?.title ?? "")”?",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { chat in
            // No destructive role: that paints the button system red, and the design keeps Delete in ink.
            Button("Delete") { delete(chat) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Chats").font(.title2.weight(.semibold))
                Spacer()
                if !chats.isEmpty {
                    Button(editing ? "Done" : "Edit") {
                        withAnimation(Self.closeSpring) {
                            editing.toggle()
                            armed = nil
                        }
                    }
                    .font(editing ? .answer.weight(.semibold) : .answer)
                }
            }
            .foregroundStyle(Color.ink)
            ScrollView {
                if chats.isEmpty {
                    empty
                } else {
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(Array(Self.months(chats).enumerated()), id: \.element.title) { index, month in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(month.title)
                                    .font(.row.weight(.semibold))
                                    .tracking(0.6)
                                    .foregroundStyle(Color.muted)
                                    .padding(.leading, 4)
                                card(month.chats)
                            }
                            // Each card rises in a beat after the one above, Profile's tile recipe.
                            .opacity(shown ? 1 : 0)
                            .offset(y: shown || reduceMotion ? 0 : 8)
                            .animation(reduceMotion ? fade
                                       : .spring(duration: 0.35, bounce: 0).delay(0.06 + 0.04 * Double(index)), value: shown)
                        }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .frame(width: Self.panelWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        // A 1-point `line` on the right edge and a soft shadow set the panel off the dimmed screen.
        // The shadow sits on the background only, so the cards and text don't cast one.
        .background { Color.background.shadow(color: .black.opacity(0.2), radius: 12).ignoresSafeArea() }
        .overlay(alignment: .trailing) { Color.line.frame(width: 1).ignoresSafeArea() }
        // Behind the rows' buttons and the list's own scrolling, which still win.
        // shortcut: a pull that starts on a chat row is that row's tap, so a full list is only
        // pulled from its header, its gaps or the scrim; a UIKit pan that cancels the row would fix it.
        .gesture(dragToClose(tapCloses: false))
        // Still in the tree while it moves out, so a tap then must not open a chat.
        .allowsHitTesting(shown)
    }

    /// One month's chats in an inset `group` card, with hairlines between the rows.
    private func card(_ chats: [Chats.Chat]) -> some View {
        VStack(spacing: 0) {
            ForEach(chats) { chat in
                if chat.id != chats.first?.id {
                    // Inset past the minus circles in edit mode, as drawn.
                    Color.line.frame(height: 1).padding(.leading, editing ? 44 : 14)
                }
                row(chat).transition(.opacity)
            }
        }
        .background(Color.group)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    /// The title over "Jun 30 · 3 questions", a dot on the open chat, and in edit mode a leading
    /// minus circle and, once it is tapped, an `ink` Delete at the trailing edge.
    private func row(_ chat: Chats.Chat) -> some View {
        HStack(spacing: 10) {
            if editing {
                Button { withAnimation(.easeOut(duration: 0.2)) { armed = armed == chat.id ? nil : chat.id } } label: {
                    Image(systemName: "minus.circle").font(.title3).frame(minHeight: 44).contentShape(Rectangle())
                }
                .foregroundStyle(Color.ink)
                .accessibilityLabel("Delete \(chat.title)")
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
            Button {
                if editing {
                    withAnimation(.easeOut(duration: 0.2)) { armed = nil }
                } else {
                    // The chat fades in under the scrim while the panel moves out.
                    withAnimation(reduceMotion ? fade : Self.closeSpring) { open(chat) }
                    close()
                }
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chat.title)
                            .font(.cardTitle)
                            .foregroundStyle(Color.ink)
                            // One line as drawn; at the largest text sizes the whole title wraps instead.
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        Text(Self.subtitle(chat)).font(.row).foregroundStyle(Color.muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if chat.id == openID {
                        Circle().fill(Color.ink).frame(width: 7, height: 7)
                    }
                }
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chatRow")
            .accessibilityAddTraits(chat.id == openID ? .isSelected : [])
            if armed == chat.id {
                Button { confirming = chat } label: {
                    Text("Delete")
                        .font(.cardTitle)
                        .foregroundStyle(Color.background)
                        // Grows with large text instead of clipping the word.
                        .padding(.horizontal, 12)
                        .frame(minWidth: 80)
                        .frame(maxHeight: .infinity)
                        .background(Color.ink)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .trailing))
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, armed == chat.id ? 0 : 14)
        // Lets Delete fill the row's height without making the row taller.
        .fixedSize(horizontal: false, vertical: true)
    }

    /// No saved chats yet: one `group` card in place of the months.
    private var empty: some View {
        Text("No chats yet")
            .font(.cardTitle)
            .foregroundStyle(Color.ink)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .padding(.horizontal, 16)
            .background(Color.group, in: RoundedRectangle(cornerRadius: 14))
    }

    /// Dragging left pulls the panel along (the scrim dims less as it goes); letting go past
    /// 90 points, or with a fast flick, closes it, and anything shorter springs it back.
    /// On the scrim (`tapCloses`) the same gesture also takes a plain tap as a close, so a pull
    /// that ends short can't be mistaken for one. Under Reduce Motion the panel stays put and the
    /// same swipe ends in the fade.
    private func dragToClose(tapCloses: Bool) -> some Gesture {
        DragGesture(minimumDistance: tapCloses ? 0 : 10)
            .updating($drag) { value, drag, _ in
                if !reduceMotion { drag = min(0, value.translation.width) }
            }
            .onEnded { value in
                let tapped = tapCloses && hypot(value.translation.width, value.translation.height) < 10
                if tapped || value.translation.width < -90 || value.predictedEndTranslation.width < -150 { close() }
            }
    }

    /// Moves the panel out, then closes the cover without the system's slide-down.
    private func close() {
        // A second close while the first is still moving would dismiss twice.
        guard shown else { return }
        withAnimation(reduceMotion ? fade : Self.closeSpring) { shown = false } completion: {
            var instant = Transaction()
            instant.disablesAnimations = true
            withTransaction(instant) { dismiss() }
        }
    }

    /// Deletes the chat the dialog asked about from the file, then from the list.
    private func delete(_ chat: Chats.Chat) {
        do {
            try Chats.delete(chat.id, in: database)
            deleted(chat.id)
            withAnimation(Self.closeSpring) {
                chats.removeAll { $0.id == chat.id }
                armed = nil
                if chats.isEmpty { editing = false }
            }
        } catch {
            print("Could not delete the chat:", error)
        }
    }

    /// The chats grouped by the month each was last used, keeping the list's newest-first order.
    /// Only each chat's own saved date is read, never today's. A month from an earlier year than
    /// the newest chat's also names its year, so two Junes don't look the same.
    static func months(_ chats: [Chats.Chat], calendar: Calendar = .current) -> [Month] {
        let newestYear = chats.first.map { calendar.component(.year, from: $0.updated) }
        var months: [Month] = []
        for chat in chats {
            if let last = months.last?.chats.first,
               calendar.isDate(last.updated, equalTo: chat.updated, toGranularity: .month) {
                months[months.count - 1].chats.append(chat)
            } else {
                let style = calendar.component(.year, from: chat.updated) == newestYear
                    ? Date.FormatStyle().month(.wide) : Date.FormatStyle().month(.wide).year()
                months.append(Month(title: chat.updated.formatted(style).uppercased(), chats: [chat]))
            }
        }
        return months
    }

    /// "Jun 30 · 3 questions": the day the chat was last used and how many questions it holds.
    static func subtitle(_ chat: Chats.Chat) -> String {
        let date = chat.updated.formatted(.dateTime.month(.abbreviated).day())
        return "\(date) · \(chat.questions) \(chat.questions == 1 ? "question" : "questions")"
    }
}
