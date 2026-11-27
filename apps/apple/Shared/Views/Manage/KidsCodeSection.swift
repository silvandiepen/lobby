// SPDX-License-Identifier: MPL-2.0
import SwiftUI

/// The code that leads out of kids mode where a device has no lock of its own: the Apple TV. One
/// for the household, kept on the server; a manager chooses it here.
struct KidsCodeSection: View {
    @Environment(AppModel.self) private var app
    @State private var isSet: Bool?
    @State private var code = ""
    @State private var problem: String?
    @State private var isSaving = false

    private var digits: String { String(code.filter(\.isNumber).prefix(4)) }

    var body: some View {
        Section {
            LabeledContent("Code", value: isSet == nil ? "…" : isSet == true ? "Chosen" : "None yet")
                .accessibilityIdentifier("manage.kidsCode.state")
            SecureField("Four digits", text: $code)
                #if !os(macOS)
                .keyboardType(.numberPad)
                #endif
                .onSubmit { save(digits) }
                .accessibilityIdentifier("manage.kidsCode.field")
            Button(isSet == true ? "Change Code" : "Choose Code", systemImage: AppSymbol.secret) { save(digits) }
                .disabled(digits.count != 4 || isSaving)
                .accessibilityIdentifier("manage.kidsCode.save")
            if isSet == true {
                Button("Remove Code", systemImage: AppSymbol.remove, role: .destructive) { save(nil) }
                    .disabled(isSaving)
            }
            if let problem {
                Text(problem).foregroundStyle(Color.lobbyWarning)
            }
        } header: {
            Label("Code for Grown-ups", systemImage: AppSymbol.secret)
        } footer: {
            Text("On an Apple TV a grown-up types these four digits to leave a child's pages. Without a code, only a manager can change that, from here. An Apple TV that belongs to a child cannot be left at all.")
        }
        .task { await look() }
    }

    private func look() async {
        do {
            isSet = try await app.hasKidsCode()
        } catch {
            problem = await app.managerProblem(error)
        }
    }

    private func save(_ code: String?) {
        guard code == nil || code?.count == 4 else { return }
        isSaving = true
        problem = nil
        Task {
            defer { isSaving = false }
            do {
                try await app.setKidsCode(code)
                self.code = ""
                isSet = code != nil
            } catch {
                problem = await app.managerProblem(error)
            }
        }
    }
}
