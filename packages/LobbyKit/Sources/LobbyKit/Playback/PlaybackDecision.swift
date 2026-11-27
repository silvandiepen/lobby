// SPDX-License-Identifier: MPL-2.0
import VideoToolbox

/// What this device can decode beyond what every supported Apple device can.
public struct DeviceCapabilities: Hashable, Sendable {
    /// AV1 decoding in hardware (A17 Pro, M3 and later).
    public var hardwareAV1Decode: Bool

    public init(hardwareAV1Decode: Bool) {
        self.hardwareAV1Decode = hardwareAV1Decode
    }

    /// The capabilities of the device this runs on.
    public static func current() -> DeviceCapabilities {
        DeviceCapabilities(hardwareAV1Decode: VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1))
    }
}

/// How to play one file on one device.
public enum PlaybackDecision: Hashable, Sendable {
    /// Stream or download `/v1/assets/{id}/content` as it is.
    case direct
    /// The server repackages the file first: `LobbyClient.playback(assetID:)` says when the copy
    /// can be played.
    case needsPreparedPlayback
    case notPlayable(NotPlayableReason)
}

public enum NotPlayableReason: Hashable, Sendable {
    /// The file's drive is not connected to the server right now.
    case unavailable
    /// The picture has to be re-encoded, which the server does not do yet.
    case needsTranscode(message: String?)
    /// There is no usable video in the file.
    case unsupported(message: String?)
    /// A playability value from a newer server that this build does not know.
    case unknownPlayability(String, message: String?)

    /// The server's sentence for the viewer, when it sent one.
    public var serverMessage: String? {
        switch self {
        case .unavailable: nil
        case .needsTranscode(let message), .unsupported(let message), .unknownPlayability(_, let message): message
        }
    }
}

public enum PlaybackPlanner {
    // What AVFoundation plays as it is, from `apps/server/src/library/probe.ts`. Used only to
    // re-judge an AV1 file on a device that decodes AV1, where the server had to assume it cannot.
    private static let directContainers: Set<String> = ["mp4", "mov", "m4v"]
    private static let directAudioCodecs: Set<String> = ["aac", "ac3", "eac3", "mp3", "alac"]

    /// Decides how to stream a file from the server.
    ///
    /// The server's `playability` is the answer, with one exception the API names: a file marked
    /// `transcode` only because its picture is AV1 plays on a device that decodes AV1 in
    /// hardware. Directly if it is an MP4 with sound Apple plays, otherwise after repackaging.
    /// A picture the server converts (`convertible`) plays after preparing, like a repackaged one.
    public static func decide(for file: MediaFile, capabilities: DeviceCapabilities) -> PlaybackDecision {
        guard file.available else { return .notPlayable(.unavailable) }

        switch file.playability {
        case .direct:
            return .direct
        case .remux:
            return .needsPreparedPlayback
        case .transcode:
            if file.convertible == true { return .needsPreparedPlayback }
            guard capabilities.hardwareAV1Decode, file.video?.codec.lowercased() == "av1" else {
                return .notPlayable(.needsTranscode(message: file.playabilityReason))
            }
            let containerPlays = directContainers.contains(file.container.lowercased())
            let soundPlays = file.audio.isEmpty
                || file.audio.contains { directAudioCodecs.contains($0.codec.lowercased()) }
            return containerPlays && soundPlays ? .direct : .needsPreparedPlayback
        case .unsupported:
            return .notPlayable(.unsupported(message: file.playabilityReason))
        case .unknown(let value):
            return .notPlayable(.unknownPlayability(value, message: file.playabilityReason))
        }
    }
}
