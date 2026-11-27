// SPDX-License-Identifier: MPL-2.0
import AVKit
import SwiftUI
import UIKit

/// Shows the native player (`AVPlayerViewController`) full screen while `model` is set.
///
/// This is the UIKit edge of playback on iPhone and iPad: the system's controls, its audio and
/// subtitle menus, AirPlay, Picture in Picture and rotation come with it. Everything about what
/// plays and where it resumes is in `PlayerModel`.
struct PlayerPresenter: UIViewControllerRepresentable {
    let model: PlayerModel?
    /// `model.isFinished` and whether the app's own transport is up, read by the SwiftUI view
    /// that owns this, so that a change reaches `updateUIViewController`.
    let isFinished: Bool
    let usesOwnTransport: Bool
    /// Whether an end screen is up (`model.ending`): it then takes the taps.
    let showsEnding: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let host = UIViewController()
        host.view.isUserInteractionEnabled = false
        host.view.backgroundColor = .clear
        return host
    }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        context.coordinator.update(
            model: model, isFinished: isFinished, usesOwnTransport: usesOwnTransport, showsEnding: showsEnding, host: host)
    }

    @MainActor
    final class Coordinator: NSObject, @MainActor AVPlayerViewControllerDelegate, UIGestureRecognizerDelegate {
        private var presented: (model: PlayerModel, controller: AVPlayerViewController)?
        private var ownTransport: UIView?
        private var endScreen: UIView?
        private var extras: UIView?
        private var hideExtras: Task<Void, Never>?

        func update(model: PlayerModel?, isFinished: Bool, usesOwnTransport: Bool, showsEnding: Bool, host: UIViewController) {
            if let presented, presented.model !== model || isFinished {
                // The film played to its end, or the model went away (signed out, device removed).
                close()
            }
            if let presented {
                // While the server still writes the copy, the system's transport would show a
                // live broadcast. The app's own takes its place, and gives it back afterwards.
                presented.controller.showsPlaybackControls = !usesOwnTransport && !showsEnding
                ownTransport?.isHidden = !usesOwnTransport
                endScreen?.isHidden = !showsEnding
            }
            guard let model, !isFinished, presented == nil, host.view.window != nil else { return }

            do {
                // Films have sound with the silent switch on, and keep it when the screen locks.
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            } catch {
                // The session keeps its default category: playback still works, and follows the
                // silent switch.
            }

            let controller = AVPlayerViewController()
            controller.player = model.player
            controller.delegate = self
            controller.modalPresentationStyle = .fullScreen
            controller.showsPlaybackControls = !usesOwnTransport
            if model.isForKids {
                // Nothing that takes the film out of the kids screens.
                controller.allowsPictureInPicturePlayback = false
                controller.canStartPictureInPictureAutomaticallyFromInline = false
            }

            // The app's own views on top of the system player. They go above the player's view,
            // because its `contentOverlayView` lies under the controls and does not take taps.
            //
            // Subtitles stored as pictures: placed on the film's picture, which fills the view.
            let pictures = embed(PictureSubtitleOverlay(model: model), in: controller, fills: true) { view, parent in
                [
                    view.topAnchor.constraint(equalTo: parent.topAnchor),
                    view.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
                    view.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                    view.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
                ]
            }
            pictures.isUserInteractionEnabled = false

            // Subtitles the app draws itself: at the foot of the picture, and never in the way
            // of a tap.
            let subtitles = embed(SubtitleOverlay(model: model), in: controller) { view, parent in
                [
                    view.centerXAnchor.constraint(equalTo: parent.centerXAnchor),
                    view.widthAnchor.constraint(lessThanOrEqualTo: parent.widthAnchor),
                    view.bottomAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.bottomAnchor, constant: -120),
                ]
            }
            subtitles.isUserInteractionEnabled = false

            // The transport for a film that is still being prepared: over everything.
            let transport = embed(PreparingTransport(model: model) { [weak self] in self?.close() }, in: controller, fills: true) { view, parent in
                [
                    view.topAnchor.constraint(equalTo: parent.topAnchor),
                    view.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
                    view.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                    view.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
                ]
            }
            transport.isHidden = !usesOwnTransport
            ownTransport = transport

            // The message while a file is being prepared or cannot play, and Play Next.
            embed(PlayerStatusView(model: model) { [weak self] in self?.close() }, in: controller) { view, parent in
                [
                    view.centerXAnchor.constraint(equalTo: parent.centerXAnchor),
                    view.centerYAnchor.constraint(equalTo: parent.centerYAnchor),
                    view.widthAnchor.constraint(lessThanOrEqualTo: parent.widthAnchor),
                ]
            }
            embed(ReconnectingNotice(model: model), in: controller) { view, parent in
                [
                    view.centerXAnchor.constraint(equalTo: parent.centerXAnchor),
                    view.topAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.topAnchor, constant: 72),
                ]
            }.isUserInteractionEnabled = false
            // What comes at the end: Up Next, the suggestions, "Still watching?". Over everything,
            // and only while it is up, so that the system's controls keep their taps otherwise.
            let ending = embed(UpNextOverlay(model: model) { [weak self] in self?.close() }, in: controller, fills: true) { view, parent in
                [
                    view.topAnchor.constraint(equalTo: parent.topAnchor),
                    view.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
                    view.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
                    view.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
                ]
            }
            ending.isHidden = !showsEnding
            endScreen = ending
            embed(PlayNextButton(model: model), in: controller) { view, parent in
                [
                    view.trailingAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.trailingAnchor, constant: -24),
                    // Clear of the system's transport bar.
                    view.bottomAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.bottomAnchor, constant: -96),
                ]
            }

            // Skip Intro, where Play Next is later on: the two never show at the same time.
            embed(SkipIntroButton(model: model), in: controller) { view, parent in
                [
                    view.trailingAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.trailingAnchor, constant: -24),
                    view.bottomAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.bottomAnchor, constant: -96),
                ]
            }

            // Subtitles the system's menu does not have: a button of the app's own, under the
            // system's top row. It comes and goes with a tap on the picture, as the system's
            // controls do.
            let extras = embed(HStack(spacing: AppTheme.Space.m) {
                PlayerSendButton(model: model)
                KidsPlayerTVButton(model: model)
                ExtraSubtitlesButton(model: model)
            }, in: controller) { view, parent in
                [
                    view.trailingAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.trailingAnchor, constant: -20),
                    view.topAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.topAnchor, constant: 64),
                ]
            }
            self.extras = extras
            let tap = UITapGestureRecognizer(target: self, action: #selector(pictureTapped))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            controller.view.addGestureRecognizer(tap)
            showExtrasForAWhile()

            presented = (model, controller)
            // A search field that still has the keyboard would bring it back over the player.
            host.view.window?.endEditing(true)
            host.present(controller, animated: true)
        }

        @discardableResult
        private func embed<Content: View>(
            _ content: Content, in controller: AVPlayerViewController, fills: Bool = false,
            constraints: (_ view: UIView, _ parent: UIView) -> [NSLayoutConstraint]
        ) -> UIView {
            let hosting = UIHostingController(rootView: content.lobbyMotion())
            if !fills {
                // As large as its content and no larger, so taps beside it reach the player.
                hosting.sizingOptions = .intrinsicContentSize
            }
            hosting.view.backgroundColor = .clear
            hosting.view.translatesAutoresizingMaskIntoConstraints = false
            controller.addChild(hosting)
            controller.view.addSubview(hosting.view)
            NSLayoutConstraint.activate(constraints(hosting.view, controller.view))
            hosting.didMove(toParent: controller)
            return hosting.view
        }

        // MARK: The extra subtitles button

        @objc private func pictureTapped() {
            if extras?.alpha == 0 {
                showExtrasForAWhile()
            } else {
                setExtras(visible: false)
            }
        }

        /// Visible for as long as the system shows its own controls after a tap.
        private func showExtrasForAWhile() {
            setExtras(visible: true)
            hideExtras?.cancel()
            hideExtras = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(4))
                } catch {
                    return
                }
                // A paused film keeps its controls up.
                if self?.presented?.model.isPlaying == true {
                    self?.setExtras(visible: false)
                }
            }
        }

        private func setExtras(visible: Bool) {
            guard let extras else { return }
            if UIAccessibility.isReduceMotionEnabled {
                extras.alpha = visible ? 1 : 0
            } else {
                UIView.animate(withDuration: 0.2) { extras.alpha = visible ? 1 : 0 }
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            // The system player's own taps keep working.
            true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            // A tap on the button itself is the button's.
            guard let extras, let view = touch.view else { return true }
            return !view.isDescendant(of: extras)
        }

        // MARK: Closing

        /// Takes the player down from the app's side.
        private func close() {
            guard let presented else { return }
            forget()
            presented.controller.dismiss(animated: true)
            Task { await presented.model.close() }
        }

        private func forget() {
            presented = nil
            ownTransport = nil
            endScreen = nil
            extras = nil
            hideExtras?.cancel()
        }

        /// The viewer closed the player with its own button, or swiped it away.
        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willEndFullScreenPresentationWithAnimationCoordinator coordinator: any UIViewControllerTransitionCoordinator
        ) {
            coordinator.animate(alongsideTransition: nil) { [weak self] context in
                // An interactive swipe can be let go half-way: then the player stays.
                guard !context.isCancelled else { return }
                self?.playerWasDismissed()
            }
        }

        private func playerWasDismissed() {
            guard let presented else { return }
            forget()
            Task { await presented.model.close() }
        }
    }
}
