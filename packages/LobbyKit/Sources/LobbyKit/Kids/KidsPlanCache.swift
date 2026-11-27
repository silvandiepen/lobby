// SPDX-License-Identifier: MPL-2.0
import CryptoKit
import Foundation
import LobbyDirect

/// The clocks a child's device has: the one a person can set, and one nobody can.
public protocol KidsClock: Sendable {
    /// The device's own date and time, in milliseconds. Anyone can change it.
    var wallMs: Int64 { get }
    /// Milliseconds since the device started, also while it sleeps. Nobody can set it.
    var monotonicMs: Double { get }
    /// Different after every restart of the device, when the monotonic clock starts again.
    var bootSession: String { get }
}

/// The clocks of this device.
public struct SystemKidsClock: KidsClock {
    public init() {}

    public var wallMs: Int64 { Date().millisecondsSince1970 }

    public var monotonicMs: Double {
        // Goes on while the device sleeps, unlike CLOCK_UPTIME_RAW.
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000
    }

    public var bootSession: String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return "" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

public enum KidsPlanCacheError: Error, Equatable, Sendable {
    /// The signature is not the server's.
    case badSignature
    /// The server's key is not the one this device pinned.
    case keyChanged
    /// The copy is for another viewer or device, or unreadable.
    case notForThis
}

/// The signed copy of a child's plan that a device holds for when it has no server
/// (docs/kids-control.md, "Offline"), and the clock it is read with.
///
/// Now is the server's time at the last sync plus the monotonic time since, which a person
/// cannot change. After a restart that clock is gone: then the device clock, never earlier than
/// the latest time it trusted. When the two disagree by more than two minutes, the stricter of
/// both moments holds. A copy that ran out holds the strictest mode it names; none is Nothing.
public struct KidsPlanCache: Codable, Hashable, Sendable {
    /// More apart than this, the device clock was moved.
    public static let toleranceMs: Int64 = 2 * 60_000

    public var signed: SignedKidsPlan?
    /// The server's key, pinned the first time.
    public var publicKey: String?
    public var profileID: String?
    public var deviceID: String?
    /// The server's time at the last sync, and the monotonic clock then.
    public var anchorServerMs: Int64 = 0
    public var anchorMonotonicMs: Double = 0
    public var bootSession: String = ""
    /// The latest moment this device trusted. Never goes back.
    public var latestTrustedMs: Int64 = 0
    /// Video seconds counted on this device, per local day.
    public var watched: [String: Double] = [:]

    public init() {}

    /// What is inside the signed copy, when it is there and the server's.
    public var copy: KidsPlanCopy? {
        guard let signed, let publicKey, Self.verify(signed, publicKey: publicKey),
            let data = Data(base64URL: signed.payload)
        else { return nil }
        return try? LobbyJSON.decoder().decode(KidsPlanCopy.self, from: data)
    }

    static func verify(_ signed: SignedKidsPlan, publicKey: String) -> Bool {
        guard let raw = Data(base64URL: publicKey), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
            let payload = Data(base64URL: signed.payload), let signature = Data(base64URL: signed.signature)
        else { return false }
        return key.isValidSignature(signature, for: payload)
    }

    /// Takes what the server said, after checking it is the server's.
    ///
    /// - Parameter deviceID: This device's id: a copy for another one is refused.
    public mutating func accept(_ me: KidsMe, deviceID: String, clock: any KidsClock) throws {
        if let pinned = publicKey, pinned != me.publicKey { throw KidsPlanCacheError.keyChanged }
        guard Self.verify(me.signed, publicKey: me.publicKey) else { throw KidsPlanCacheError.badSignature }
        guard let data = Data(base64URL: me.signed.payload),
            let copy = try? LobbyJSON.decoder().decode(KidsPlanCopy.self, from: data),
            copy.profileId == me.profileId, copy.deviceId == deviceID
        else { throw KidsPlanCacheError.notForThis }
        if profileID != copy.profileId { watched = [:] }
        publicKey = me.publicKey
        signed = me.signed
        profileID = copy.profileId
        self.deviceID = deviceID
        anchorServerMs = max(me.serverTime, copy.issuedAt)
        anchorMonotonicMs = clock.monotonicMs
        bootSession = clock.bootSession
        latestTrustedMs = max(latestTrustedMs, anchorServerMs)
    }

    /// Forgets the pinned key and the copy, for a device that is paired anew.
    public mutating func forget() {
        self = KidsPlanCache()
    }

    /// The moments that may be now: the trusted one, and the device clock when they disagree.
    public func moments(_ clock: any KidsClock) -> [Int64] {
        let wall = clock.wallMs
        let trusted: Int64
        if !bootSession.isEmpty, clock.bootSession == bootSession {
            trusted = anchorServerMs + Int64(max(0, clock.monotonicMs - anchorMonotonicMs))
        } else {
            // Restarted: the monotonic clock began again. Never before what was trusted.
            trusted = max(wall, latestTrustedMs)
        }
        return abs(wall - trusted) > Self.toleranceMs ? [trusted, wall] : [trusted]
    }

    /// Notes the latest trusted moment, so a later restart cannot go back before it.
    public mutating func note(_ clock: any KidsClock) {
        latestTrustedMs = max(latestTrustedMs, moments(clock).first ?? 0)
    }

    /// Counts video watched on this device.
    public mutating func addVideo(seconds: Double, clock: any KidsClock) {
        guard let copy, let zone = TimeZone(identifier: copy.timeZone), seconds > 0 else { return }
        let day = KidsPlanResolver.localDay(zone, moments(clock).first ?? clock.wallMs)
        watched[day, default: 0] += seconds
    }

    /// What the child may do now without the server: the plan as it is, at the place this device says.
    public func now(place: KidsPlaceReport, clock: any KidsClock) -> KidsNow {
        guard let copy, let zone = TimeZone(identifier: copy.timeZone) else {
            return KidsNow(at: .resting(.offline))
        }
        let counted = watched
        let copied = copy.screenTime
        let context = KidsPlanContext(
            // Offline is not away: the plan as it is, with what last ran (docs/decisions.md, "Kids control").
            timeZone: zone, away: false, place: place,
            videoSeconds: { day in max(counted[day] ?? 0, day == copied.day ? copied.seconds : 0) },
            override: copy.override, grants: copy.grants)
        let moments = moments(clock)
        let states = moments.map { moment -> KidsNow in
            if moment > copy.validUntil || moment < copy.issuedAt - Self.toleranceMs {
                // Ran out, or a moment before it was made: the strictest it names.
                let strictest = KidsPlan(defaultMode: copy.plan.strictest, askStyle: copy.plan.askStyle, music: copy.plan.music)
                var now = KidsPlanResolver.resolve(strictest, KidsPlanContext(timeZone: zone, away: false, place: place), at: moment)
                now.at.reason = .offline
                now.until = nil
                now.next = nil
                return now
            }
            return KidsPlanResolver.resolve(copy.plan, context, at: moment)
        }
        guard var strictest = states.first else { return KidsNow(at: .resting(.offline)) }
        for state in states.dropFirst() where KidsPlanResolver.stricter(state.at, strictest.at) == state.at {
            strictest = state
        }
        return strictest
    }
}
