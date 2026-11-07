//
//  PreviousChatsView.swift
//  Sedge
//

import SedgeCore
import SwiftUI

/// Previous chats: a 300-point panel that slides in from the left over Ask, with the screen
/// dimmed behind it. Every saved chat in this dataset is listed in month cards, most recently used
/// first. Edit puts a minus circle on each row; it shows a Delete in the card, which asks first.
/// Ask presents it as a full-screen cover without the system animation, so the panel covers the
/// top and tab bars and slides in by itself.
struct PreviousChatsView: View {
    let database: SedgeDatabase
    /// The chat on the Ask screen, marked with a dot.
    let openID: Int64?
    /// Opens the tapped chat on the Ask screen.
    let open: (Chats.Chat) -> Void
    /// Told each deleted chat's id, so Ask can leave a chat that no longer exists.
    let deleted: (Int64) -> Void
    @State private var chats: [Chats.Chat] = []
    /// False until the panel has slid in, and again while it slides out.
    @State private var shown = false
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

    /// The chats last used in one month, under a label such as "JUNE".
    struct Month {
        let title: String
        var chats: [Chats.Chat]
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // The scrim: `ink` at 35 %, as drawn. Tapping it closes the panel.
            Color.ink.opacity(shown ? 0.35 : 0)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
                .accessibilityLabel("Close")
                .accessibilityAddTraits(.isButton)
            if shown {
                panel.transition(reduceMotion ? .opacity : .move(edge: .leading))
            }
        }
        .presentationBackground(.clear)
        // VoiceOver's two-finger scrub closes it, like a sheet.
        .accessibilityAction(.escape, close)
        .onAppear { withAnimation(.easeOut(duration: 0.25)) { shown = true } }
        .task {
            do { chats = try Chats.list(in: database) } catch { print("Could not list the chats:", error) }
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
                        editing.toggle()
                        armed = nil
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
                        ForEach(Self.months(chats), id: \.title) { month in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(month.title)
                                    .font(.row.weight(.semibold))
                                    .tracking(0.6)
                                    .foregroundStyle(Color.muted)
                                    .padding(.leading, 4)
                                card(month.chats)
                            }
                        }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .frame(width: 300)
        .frame(maxHeight: .infinity, alignment: .top)
        // A 1-point `line` on the right edge and a soft shadow set the panel off the dimmed screen.
        // The shadow sits on the background only, so the cards and text don't cast one.
        .background { Color.background.shadow(color: .black.opacity(0.2), radius: 12).ignoresSafeArea() }
        .overlay(alignment: .trailing) { Color.line.frame(width: 1).ignoresSafeArea() }
    }

    /// One month's chats in an inset `group` card, with hairlines between the rows.
    private func card(_ chats: [Chats.Chat]) -> some View {
        VStack(spacing: 0) {
            ForEach(chats) { chat in
                if chat.id != chats.first?.id {
                    // Inset past the minus circles in edit mode, as drawn.
                    Color.line.frame(height: 1).padding(.leading, editing ? 44 : 14)
                }
                row(chat)
            }
        }
        .background(Color.group)
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
            }
            Button {
                if editing {
                    withAnimation(.easeOut(duration: 0.2)) { armed = nil }
                } else {
                    open(chat)
                    close()
                }
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chat.title)
                            .font(.subheadline.weight(.semibold))
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
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.background)
                        .frame(width: 80)
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
        VStack(spacing: 4) {
            Text("No chats yet").font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
            Text("Each chat is saved here once Sedge answers.").font(.footnote).foregroundStyle(Color.muted)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
        .background(Color.group, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Slides the panel out, then closes the cover without the system's slide-down.
    private func close() {
        withAnimation(.easeOut(duration: 0.25)) { shown = false } completion: {
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
            chats.removeAll { $0.id == chat.id }
            armed = nil
            if chats.isEmpty { editing = false }
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
