// SPDX-License-Identifier: MPL-2.0
import LobbyKit
import SwiftUI

/// A child asks: the grown-ups who may decide see it at once, with three big answers. One tap
/// uses the usual length (until the next switch today, else an hour); "For…" offers others
/// (docs/kids-control.md, §4). Answered elsewhere, it says who answered and what, for a moment.
struct KidsAskPresenter: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { app.showsKidsScreens ? nil : app.kidsControl.questions.first }, set: { _ in })) {
                KidsAskSheet(question: $0)
                    .presentationDetents([.medium])
            }
            .overlay(alignment: .top) {
                if !app.showsKidsScreens, let done = app.kidsControl.answered.last {
                    Text(KidsAskText.answered(done))
                        .font(.headline)
                        .padding(.horizontal, AppTheme.Space.m)
                        .padding(.vertical, AppTheme.Space.s)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, AppTheme.Space.s)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .accessibilityIdentifier("kids.answered")
                }
            }
    }
}

private struct KidsAskSheet: View {
    let question: KidsRequest
    @Environment(AppModel.self) private var app
    @State private var isAnswering = false

    private var name: String { question.viewer?.name ?? "A child" }

    var body: some View {
        VStack(spacing: AppTheme.Space.l) {
            if let viewer = question.viewer {
                ProfileAvatar(name: viewer.name, color: viewer.color, avatar: viewer.avatar, size: 72)
            }
            Text(question.title.map { "\(name) wants to watch \($0.title)" } ?? "\(name) wants to open Lobby")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            HStack(spacing: AppTheme.Space.m) {
                answer("Watch", .watch)
                if question.kind == .open { answer("Listen", .listen) }
                answer(question.kind == .open ? "No" : "Not now", .no)
            }
            Menu("For…") {
                ForEach(KidsAskLength.choices, id: \.self) { choice in
                    Menu(choice.title) {
                        Button("Watch") { send(.watch, choice.length) }
                        if question.kind == .open { Button("Listen") { send(.listen, choice.length) } }
                    }
                }
            }
            .disabled(isAnswering)
        }
        .padding(AppTheme.Space.xl)
    }

    private func answer(_ title: String, _ answer: KidsAnswer) -> some View {
        Button(title) { send(answer, nil) }
            .buttonStyle(ProminentButtonStyle())
            .disabled(isAnswering)
    }

    private func send(_ answer: KidsAnswer, _ length: KidsLength?) {
        isAnswering = true
        Task {
            await app.answerKids(question.id, answer, length: length)
            isAnswering = false
        }
    }
}

/// The lengths a grown-up can pick besides the usual hour.
struct KidsAskLength: Hashable {
    var title: String
    var length: KidsLength

    static let choices: [KidsAskLength] = [
        KidsAskLength(title: "Until the next switch", length: .nextSwitch),
        KidsAskLength(title: "30 minutes", length: .minutes(30)),
        KidsAskLength(title: "1 hour", length: .minutes(60)),
        KidsAskLength(title: "2 hours", length: .minutes(120)),
    ]
}

extension View {
    /// Shows a child's question to the grown-up who may answer it.
    func answersKidsQuestions() -> some View {
        modifier(KidsAskPresenter())
    }
}
