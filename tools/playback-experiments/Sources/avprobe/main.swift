// SPDX-License-Identifier: MPL-2.0
// avprobe: opens a URL with the real AVFoundation stack and reports what a Lobby app would see.
//
// It waits for readyToPlay, measures the time to the first decoded video frame, lists the audio
// and subtitle options, seeks (by default to 95% of what is seekable), and checks that playback
// advances after the seek. Output is one JSON object on stdout.
//
//   swift run -c release avprobe <url> [--seek 0.95] [--play 4] [--timeout 60]
//                                      [--watch-seekable 30] [--cookie name=value]
//                                      [--audio <option index>] [--subtitle <option index>]
//
// With --subtitle the cues the player hands out after the seek are reported with their item
// time, which shows whether the subtitle rendition lines up with the picture.

import AVFoundation
import CoreMedia
import Foundation

struct Options {
    var url: URL
    var seekFraction = 0.95
    var playSeconds = 4.0
    var timeout = 60.0
    var watchSeekable = 0.0
    var cookie: String?
    var audioIndex: Int?
    var subtitleIndex: Int?
}

func parseOptions() -> Options {
    var arguments = Array(CommandLine.arguments.dropFirst())
    guard let first = arguments.first, !first.hasPrefix("--") else {
        FileHandle.standardError.write(Data("usage: avprobe <url-or-path> [--seek f] [--play s] [--timeout s] [--watch-seekable s] [--cookie k=v] [--audio n] [--subtitle n]\n".utf8))
        exit(2)
    }
    arguments.removeFirst()
    let url = first.contains("://") ? URL(string: first)! : URL(fileURLWithPath: first)
    var options = Options(url: url)
    var index = 0
    while index + 1 < arguments.count {
        let value = arguments[index + 1]
        switch arguments[index] {
        case "--seek": options.seekFraction = Double(value) ?? options.seekFraction
        case "--play": options.playSeconds = Double(value) ?? options.playSeconds
        case "--timeout": options.timeout = Double(value) ?? options.timeout
        case "--watch-seekable": options.watchSeekable = Double(value) ?? 0
        case "--cookie": options.cookie = value
        case "--audio": options.audioIndex = Int(value)
        case "--subtitle": options.subtitleIndex = Int(value)
        default: break
        }
        index += 2
    }
    return options
}

func milliseconds(since start: ContinuousClock.Instant) -> Int {
    let elapsed = ContinuousClock.now - start
    return Int(elapsed.components.seconds * 1000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
}

func fourCC(_ code: FourCharCode) -> String {
    let bytes = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff), UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
    return String(bytes: bytes, encoding: .ascii) ?? String(code)
}

/// Collects the subtitle cues AVPlayer delivers, with the item time it delivers them for.
@MainActor
final class CueCollector: NSObject, AVPlayerItemLegibleOutputPushDelegate {
    var cues: [[String: Any]] = []

    nonisolated func legibleOutput(
        _ output: AVPlayerItemLegibleOutput, didOutputAttributedStrings strings: [NSAttributedString],
        nativeSampleBuffers: [Any], forItemTime itemTime: CMTime
    ) {
        let texts = strings.map(\.string).filter { !$0.isEmpty }
        let seconds = itemTime.seconds
        // The output is told to call back on the main queue.
        MainActor.assumeIsolated {
            for text in texts { cues.append(["itemTime": seconds, "text": text]) }
        }
    }
}

@MainActor
func select(_ index: Int, _ characteristic: AVMediaCharacteristic, asset: AVAsset, item: AVPlayerItem) async -> Bool {
    guard let group = try? await asset.loadMediaSelectionGroup(for: characteristic), group.options.indices.contains(index) else {
        return false
    }
    item.select(group.options[index], in: group)
    return true
}

@MainActor
func seekableSeconds(_ item: AVPlayerItem) -> (start: Double, end: Double)? {
    guard let range = item.seekableTimeRanges.last?.timeRangeValue else { return nil }
    return (range.start.seconds, range.end.seconds)
}

/// Polls the video output until a new frame is available for the current item time.
@MainActor
func waitForFrame(_ output: AVPlayerItemVideoOutput, timeout: Double) async -> Bool {
    let start = ContinuousClock.now
    while Double(milliseconds(since: start)) / 1000 < timeout {
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        if output.hasNewPixelBuffer(forItemTime: time), output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) != nil {
            return true
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}

@MainActor
func describeOptions(_ asset: AVAsset, _ characteristic: AVMediaCharacteristic, item: AVPlayerItem) async -> [[String: Any]] {
    guard let group = try? await asset.loadMediaSelectionGroup(for: characteristic) else { return [] }
    let selected = item.currentMediaSelection.selectedMediaOption(in: group)
    return group.options.map { option in
        [
            "name": option.displayName,
            "language": option.extendedLanguageTag ?? option.locale?.identifier ?? NSNull(),
            "mediaType": option.mediaType.rawValue,
            "isDefault": group.defaultOption == option,
            "isSelected": selected == option,
            "isForced": option.hasMediaCharacteristic(.containsOnlyForcedSubtitles),
            "playable": option.isPlayable,
        ]
    }
}

@MainActor
func describeTracks(_ item: AVPlayerItem) async -> [[String: Any]] {
    var result: [[String: Any]] = []
    for track in item.tracks {
        guard let assetTrack = track.assetTrack else { continue }
        var entry: [String: Any] = ["mediaType": assetTrack.mediaType.rawValue, "enabled": track.isEnabled]
        let descriptions = (try? await assetTrack.load(.formatDescriptions)) ?? []
        if let description = descriptions.first {
            entry["codec"] = fourCC(CMFormatDescriptionGetMediaSubType(description))
            let extensions = (CMFormatDescriptionGetExtensions(description) as? [String: Any]) ?? [:]
            if assetTrack.mediaType == .video {
                let dimensions = CMVideoFormatDescriptionGetDimensions(description)
                entry["width"] = Int(dimensions.width)
                entry["height"] = Int(dimensions.height)
                entry["bitsPerComponent"] = extensions["BitsPerComponent"] ?? NSNull()
                entry["transferFunction"] = extensions[kCVImageBufferTransferFunctionKey as String] ?? NSNull()
                entry["colorPrimaries"] = extensions[kCVImageBufferColorPrimariesKey as String] ?? NSNull()
                entry["hasMasteringDisplay"] = extensions[kCMFormatDescriptionExtension_MasteringDisplayColorVolume as String] != nil
                entry["hasContentLightLevel"] = extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo as String] != nil
                let atoms = (extensions["SampleDescriptionExtensionAtoms"] as? [String: Any]) ?? [:]
                entry["sampleDescriptionAtoms"] = Array(atoms.keys).sorted()
                let characteristics = (try? await assetTrack.load(.mediaCharacteristics)) ?? []
                entry["containsHDR"] = characteristics.contains(.containsHDRVideo)
            }
            if assetTrack.mediaType == .audio, let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
                entry["channels"] = Int(basic.pointee.mChannelsPerFrame)
                entry["sampleRate"] = basic.pointee.mSampleRate
            }
        }
        result.append(entry)
    }
    return result
}

@MainActor
func run() async -> [String: Any] {
    let options = parseOptions()
    var report: [String: Any] = ["url": options.url.absoluteString]

    var assetOptions: [String: Any] = [:]
    if let cookie = options.cookie, let separator = cookie.firstIndex(of: "="), let host = options.url.host {
        let properties: [HTTPCookiePropertyKey: Any] = [
            .name: String(cookie[..<separator]), .value: String(cookie[cookie.index(after: separator)...]),
            .domain: host, .path: "/",
        ]
        if let httpCookie = HTTPCookie(properties: properties) {
            assetOptions[AVURLAssetHTTPCookiesKey] = [httpCookie]
        }
    }

    let start = ContinuousClock.now
    let asset = AVURLAsset(url: options.url, options: assetOptions)
    let item = AVPlayerItem(asset: asset)
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    item.add(output)
    let player = AVPlayer(playerItem: item)
    player.isMuted = true
    player.automaticallyWaitsToMinimizeStalling = true
    player.play()

    // Ready to play.
    while item.status == .unknown, Double(milliseconds(since: start)) / 1000 < options.timeout {
        try? await Task.sleep(for: .milliseconds(5))
    }
    report["readyMs"] = milliseconds(since: start)
    guard item.status == .readyToPlay else {
        report["status"] = item.status == .failed ? "failed" : "timeout"
        if let error = item.error as NSError? {
            report["error"] = "\(error.domain) \(error.code): \(error.localizedDescription)"
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                report["underlyingError"] = "\(underlying.domain) \(underlying.code): \(underlying.localizedDescription)"
            }
        }
        if let events = item.errorLog()?.events {
            report["errorLog"] = events.map { "\($0.errorDomain) \($0.errorStatusCode): \($0.errorComment ?? "")" }
        }
        return report
    }
    report["status"] = "readyToPlay"

    let firstFrame = await waitForFrame(output, timeout: options.timeout)
    report["firstFrameMs"] = firstFrame ? milliseconds(since: start) : NSNull()

    report["durationSeconds"] = item.duration.isNumeric ? item.duration.seconds : NSNull()
    report["durationIsIndefinite"] = item.duration.isIndefinite
    if let seekable = seekableSeconds(item) {
        report["seekableStart"] = seekable.start
        report["seekableEnd"] = seekable.end
    }
    report["presentationSize"] = "\(Int(item.presentationSize.width))x\(Int(item.presentationSize.height))"
    report["tracks"] = await describeTracks(item)
    report["audioOptions"] = await describeOptions(asset, .audible, item: item)
    report["subtitleOptions"] = await describeOptions(asset, .legible, item: item)

    let collector = CueCollector()
    let legible = AVPlayerItemLegibleOutput()
    if let index = options.audioIndex {
        report["audioSelected"] = await select(index, .audible, asset: asset, item: item)
    }
    if let index = options.subtitleIndex {
        legible.setDelegate(collector, queue: .main)
        legible.suppressesPlayerRendering = true
        item.add(legible)
        report["subtitleSelected"] = await select(index, .legible, asset: asset, item: item)
    }

    // How the seekable range grows while the server is still writing (live or event playlists).
    if options.watchSeekable > 0 {
        var samples: [[String: Any]] = []
        let watchStart = ContinuousClock.now
        while Double(milliseconds(since: watchStart)) / 1000 < options.watchSeekable {
            try? await Task.sleep(for: .seconds(1))
            let seekable = seekableSeconds(item)
            samples.append([
                "atMs": milliseconds(since: start),
                "seekableEnd": seekable?.end ?? NSNull(),
                "position": player.currentTime().seconds,
                "durationSeconds": item.duration.isNumeric ? item.duration.seconds : NSNull(),
            ])
        }
        report["seekableOverTime"] = samples
    }

    // Seek to a fraction of what is seekable right now, then check that playback advances.
    if options.seekFraction > 0, let seekable = seekableSeconds(item), seekable.end > seekable.start {
        let target = seekable.start + (seekable.end - seekable.start) * options.seekFraction
        let seekStart = ContinuousClock.now
        // Drain frames decoded before the seek so the next one counts.
        while output.hasNewPixelBuffer(forItemTime: output.itemTime(forHostTime: CACurrentMediaTime())) {
            _ = output.copyPixelBuffer(forItemTime: output.itemTime(forHostTime: CACurrentMediaTime()), itemTimeForDisplay: nil)
        }
        let finished = await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        var seek: [String: Any] = ["target": target, "finished": finished, "seekCompletedMs": milliseconds(since: seekStart)]
        let frame = await waitForFrame(output, timeout: options.timeout)
        seek["frameAfterSeekMs"] = frame ? milliseconds(since: seekStart) : NSNull()
        let before = player.currentTime().seconds
        try? await Task.sleep(for: .seconds(options.playSeconds))
        let after = player.currentTime().seconds
        seek["positionAfterSeek"] = before
        seek["positionAfterPlaying"] = after
        seek["advancedSeconds"] = after - before
        seek["advanced"] = after - before > options.playSeconds * 0.5
        report["seek"] = seek
    }

    if options.subtitleIndex != nil {
        report["cues"] = collector.cues
        report["subtitleOptionsAfter"] = await describeOptions(asset, .legible, item: item)
    }
    if options.audioIndex != nil {
        report["audioOptionsAfter"] = await describeOptions(asset, .audible, item: item)
        report["tracksAfter"] = await describeTracks(item)
    }
    if let event = item.accessLog()?.events.last {
        report["access"] = [
            "stalls": event.numberOfStalls,
            "bytesTransferred": event.numberOfBytesTransferred,
            "mediaRequests": event.numberOfMediaRequests,
            "indicatedBitrate": event.indicatedBitrate,
            "observedBitrate": event.observedBitrate,
            "droppedFrames": event.numberOfDroppedVideoFrames,
            "playbackType": event.playbackType ?? "",
        ]
    }
    if let events = item.errorLog()?.events, !events.isEmpty {
        report["errorLog"] = events.map { "\($0.errorDomain) \($0.errorStatusCode): \($0.errorComment ?? "")" }
    }
    if let error = item.error { report["error"] = error.localizedDescription }
    player.pause()
    return report
}

let report = await run()
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
print(String(data: data, encoding: .utf8)!)
exit((report["status"] as? String) == "readyToPlay" ? 0 : 1)
