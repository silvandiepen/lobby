// SPDX-License-Identifier: MPL-2.0
#if !os(tvOS)
import LobbyKit
import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// Lets a category's row be dragged, and categories be dropped on it: before it, after it, or
    /// (on the middle of a top-level one) inside it. What cannot be done shows the not-allowed
    /// cursor and a sign on the row while dragging, and is never sent.
    ///
    /// - Parameter canHold: A top-level category, which others can go inside.
    func categoryDragging(_ id: String, canHold: Bool, model: CategoriesModel, isEnabled: Bool = true) -> some View {
        modifier(CategoryDragging(target: .row(id, canHold: canHold), model: model, isEnabled: isEnabled))
    }

    /// Categories dropped here go to the end of the group, at the top level.
    func categoryDropping(atEndOf groupID: String, model: CategoriesModel, isEnabled: Bool = true) -> some View {
        modifier(CategoryDragging(target: .end(groupID), model: model, isEnabled: isEnabled))
    }
}

private struct CategoryDragging: ViewModifier {
    enum Place: Equatable {
        case row(String, canHold: Bool)
        case end(String)
    }

    let target: Place
    let model: CategoriesModel
    let isEnabled: Bool

    @Environment(\.colorScheme) private var scheme
    @State private var height: CGFloat = 0
    @State private var hover: CategoryDropTarget?
    @State private var refusal: CategoryDropRefusal?

    func body(content: Content) -> some View {
        if isEnabled {
            dragging(content)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
                .overlay { indicator }
                .onDrop(of: [.plainText], delegate: Delegate(
                    target: target, height: { height }, model: model,
                    update: { hover = $0; refusal = $1 }))
                .accessibilityHint(refusal?.message ?? "")
        } else {
            content
        }
    }

    @ViewBuilder
    private func dragging(_ content: Content) -> some View {
        if case .row(let id, _) = target {
            content.onDrag {
                let ids = model.dragged(startingAt: id)
                model.dragging = ids
                return NSItemProvider(object: ids.joined(separator: ",") as NSString)
            }
        } else {
            content
        }
    }

    /// A line where they would go, a ring for inside, a sign for what cannot be.
    @ViewBuilder
    private var indicator: some View {
        let accent = Color.lobbyAccent(scheme)
        if let refusal {
            RoundedRectangle(cornerRadius: AppTheme.Radius.tile, style: .continuous)
                .strokeBorder(Color.lobbyFailure.opacity(0.7), lineWidth: 2)
                .overlay(alignment: .trailing) {
                    Image(systemName: "nosign")
                        .foregroundStyle(Color.lobbyFailure)
                        .padding(.trailing, AppTheme.Space.s)
                        .help(refusal.message)
                }
                .allowsHitTesting(false)
                .accessibilityIdentifier("categories.notAllowed")
        } else {
            switch hover {
            case .onto?:
                RoundedRectangle(cornerRadius: AppTheme.Radius.tile, style: .continuous)
                    .strokeBorder(accent, lineWidth: 2)
                    .allowsHitTesting(false)
            case .before?:
                VStack { line(accent); Spacer() }.allowsHitTesting(false)
            case .after?, .endOf?:
                VStack { Spacer(); line(accent) }.allowsHitTesting(false)
            case nil:
                EmptyView()
            }
        }
    }

    private func line(_ color: Color) -> some View {
        Capsule().fill(color).frame(height: 3)
    }

    private struct Delegate: DropDelegate {
        let target: Place
        let height: () -> CGFloat
        let model: CategoriesModel
        let update: (CategoryDropTarget?, CategoryDropRefusal?) -> Void

        private func spot(for info: DropInfo) -> CategoryDropTarget {
            switch target {
            case .row(let id, let canHold): DropZone.target(for: id, y: info.location.y, height: height(), canHold: canHold)
            case .end(let group): .endOf(group: group)
            }
        }

        @MainActor
        private func look(_ info: DropInfo) -> DropProposal {
            guard let ids = model.dragging else {
                update(nil, nil)
                return DropProposal(operation: .forbidden)
            }
            let place = spot(for: info)
            let refusal = model.refusal(dropping: ids, on: place)
            update(place, refusal)
            return DropProposal(operation: refusal == nil ? .move : .forbidden)
        }

        func validateDrop(info: DropInfo) -> Bool {
            MainActor.assumeIsolated { model.dragging != nil }
        }

        func dropEntered(info: DropInfo) {
            _ = MainActor.assumeIsolated { look(info) }
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            MainActor.assumeIsolated { look(info) }
        }

        func dropExited(info: DropInfo) {
            update(nil, nil)
        }

        func performDrop(info: DropInfo) -> Bool {
            MainActor.assumeIsolated {
                update(nil, nil)
                guard let ids = model.dragging else { return false }
                let place = spot(for: info)
                guard model.refusal(dropping: ids, on: place) == nil else {
                    model.dragging = nil
                    return false
                }
                Task { await model.drop(ids, on: place) }
                return true
            }
        }
    }
}
#endif
