// SPDX-License-Identifier: MPL-2.0
import AVKit
import SwiftUI
import UIKit

/// The system's player (`AVPlayerViewController`): its transport, seeking with the remote, its
/// sound and subtitle menus. The app adds Skip Intro, Play Next and Try Again as the system's own buttons
/// over the picture, and the subtitles the film itself does not carry to the transport bar.
struct TVSystemPlayer: UIViewControllerRepresentable {
    let model: PlayerModel
    /// Read by the SwiftUI view that owns this, so that a change reaches the update below.
    let notice: BufferNotice?
    let offersSkipIntro: Bool
    let offersPlayNext: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = model.player
        // Leaving the player closes the film: nothing plays on in a corner.
        controller.allowsPictureInPicturePlayback = false
        // Frame rate and HDR of the film, when the viewer allows it in Settings.
        controller.appliesPreferredDisplayCriteriaAutomatically = true

        // Subtitles the app draws, under the system's controls.
        let subtitles = UIHostingController(rootView: SubtitleOverlay(model: model))
        subtitles.view.backgroundColor = .clear
        subtitles.view.isUserInteractionEnabled = false
        subtitles.view.translatesAutoresizingMaskIntoConstraints = false
        subtitles.sizingOptions = .intrinsicContentSize
        // Subtitles stored as pictures: placed on the film's picture, which fills the overlay.
        let pictures = UIHostingController(rootView: PictureSubtitleOverlay(model: model))
        pictures.view.backgroundColor = .clear
        pictures.view.isUserInteractionEnabled = false
        pictures.view.translatesAutoresizingMaskIntoConstraints = false
        if let overlay = controller.contentOverlayView {
            controller.addChild(pictures)
            overlay.addSubview(pictures.view)
            NSLayoutConstraint.activate([
                pictures.view.topAnchor.constraint(equalTo: overlay.topAnchor),
                pictures.view.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
                pictures.view.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
                pictures.view.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
            ])
            pictures.didMove(toParent: controller)
            controller.addChild(subtitles)
            overlay.addSubview(subtitles.view)
            NSLayoutConstraint.activate([
                subtitles.view.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
                subtitles.view.widthAnchor.constraint(lessThanOrEqualTo: overlay.widthAnchor),
                subtitles.view.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -100),
            ])
            subtitles.didMove(toParent: controller)
        }
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        let model = model
        let shown = Coordinator.Shown(
            tryAgain: notice == .stalled, skipIntro: offersSkipIntro,
            next: offersPlayNext && model.ending == nil ? model.upNext?.subtitle ?? "" : nil,
            subtitles: model.menuSubtitleOptions, selected: model.selectedSubtitleID,
            timing: model.showsSubtitles && !model.isForKids ? model.subtitleOffsetMs : nil)
        // Setting the buttons again takes the remote away from the one it is on.
        guard shown != context.coordinator.shown else { return }
        context.coordinator.shown = shown

        var actions: [UIAction] = []
        // The system's place for it: the remote goes to it by itself, one click skips.
        if shown.skipIntro {
            actions.append(UIAction(title: "Skip Intro", image: UIImage(systemName: "forward.fill")) { _ in model.skipIntro() })
        }
        if shown.tryAgain {
            actions.append(UIAction(title: "Try Again", image: UIImage(systemName: AppSymbol.refresh)) { _ in model.tryAgain() })
        }
        if let next = shown.next {
            actions.append(UIAction(
                title: next.isEmpty ? "Play Next" : "Play Next: \(next)", image: UIImage(systemName: "forward.end.fill")
            ) { _ in model.playNext() })
        }
        controller.contextualActions = actions

        var menus: [UIMenuElement] = []
        if !shown.subtitles.isEmpty {
            let off = UIAction(title: "Off", state: shown.selected == nil ? .on : .off) { _ in model.selectSubtitle(nil) }
            let options = shown.subtitles.map { option in
                UIAction(title: option.label, state: shown.selected == option.id ? .on : .off) { _ in model.selectSubtitle(option.id) }
            }
            menus.append(UIMenu(
                title: "More Subtitles", image: UIImage(systemName: "captions.bubble"), options: .singleSelection,
                children: [off] + options))
        }
        if let offset = shown.timing {
            var steps = [
                UIAction(title: "Earlier", image: UIImage(systemName: "gobackward")) { _ in
                    model.moveSubtitles(byMs: -PlayerModel.subtitleStepMs)
                },
                UIAction(title: "Later", image: UIImage(systemName: "goforward")) { _ in
                    model.moveSubtitles(byMs: PlayerModel.subtitleStepMs)
                },
            ]
            if offset != 0 {
                steps.append(UIAction(title: "In Time Again", image: UIImage(systemName: "arrow.uturn.backward")) { _ in
                    model.resetSubtitleTiming()
                })
            }
            menus.append(UIMenu(
                title: "Subtitle Timing", subtitle: SubtitleTiming.text(offset), image: UIImage(systemName: "timer"),
                children: steps))
        }
        controller.transportBarCustomMenuItems = menus
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        // The film goes on under the app's own controls, or ends with the model.
        controller.player = nil
    }

    @MainActor
    final class Coordinator {
        struct Shown: Equatable {
            var tryAgain = false
            var skipIntro = false
            /// The next episode's line. nil: Play Next is not offered.
            var next: String?
            var subtitles: [SubtitleOption] = []
            var selected: String?
            /// How far the subtitles on screen are moved; nil: none on screen.
            var timing: Int?
        }

        var shown: Shown?
    }
}

/// The picture alone, for the app's own controls to stand on.
struct TVPictureView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PictureView {
        let view = PictureView()
        view.backgroundColor = .black
        view.picture?.player = player
        view.picture?.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: PictureView, context: Context) {}

    static func dismantleUIView(_ view: PictureView, coordinator: ()) {
        view.picture?.player = nil
    }

    final class PictureView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var picture: AVPlayerLayer? { layer as? AVPlayerLayer }
    }
}
