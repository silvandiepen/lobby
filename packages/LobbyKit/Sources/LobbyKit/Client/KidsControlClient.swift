// SPDX-License-Identifier: MPL-2.0
import Foundation

// When and what a kids viewer may do (`/v1/me/kids…`, `/v1/kids…`, `/v1/profiles/{id}/kids…`),
// as `docs/api.md` ("Kids control") describes it.

extension LobbyError {
    /// The child's plan does not allow this now (`403 kids_mode`). The app keeps what it has and
    /// fetches `GET /v1/me/kids` for the mode.
    public var isKidsMode: Bool {
        if case .server(403, "kids_mode", _) = self { return true }
        return false
    }
}

/// Which of Apple's push servers a device token belongs to.
public enum PushEnvironment: String, Sendable {
    case development, production
}

private struct RequestAnswer: Decodable {
    var request: KidsRequest
}

private func lengthFields(_ length: KidsLength?) -> [String: JSONValue] {
    switch length {
    case .minutes(let minutes): ["minutes": .number(Double(minutes))]
    case .until(let date): ["until": .number(Double(date.millisecondsSince1970))]
    case .nextSwitch: ["untilNext": .bool(true)]
    case nil: [:]
    }
}

/// A few fields of JSON, for bodies whose keys depend on what is said.
enum JSONValue: Encodable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value):
            if value == value.rounded(), abs(value) < 9e15 { try container.encode(Int64(value)) } else { try container.encode(value) }
        case .bool(let value): try container.encode(value)
        }
    }
}

extension LobbyClient {
    // MARK: The child's device, or a grown-up's in kids mode

    /// `GET /v1/me/kids`: the child's mode now, its plan and the signed copy for offline.
    ///
    /// - Parameter profileID: For kids mode on a grown-up's device; a bound device leaves it out.
    public func kidsMe(profileID: String? = nil) async throws -> KidsMe {
        try await get(["me", "kids"], query: profileID.map { [URLQueryItem(name: "profileId", value: $0)] } ?? [])
    }

    /// `PUT /v1/me/kids/place`: inside which place the device is. Never where it is.
    @discardableResult
    public func reportKidsPlace(_ report: KidsPlaceReport, profileID: String? = nil) async throws -> KidsNow {
        var body: [String: JSONValue] = [:]
        switch report {
        case .inside(let placeID):
            body["state"] = .string("inside")
            body["placeId"] = .string(placeID)
        case .outside: body["state"] = .string("outside")
        case .unknown: body["state"] = .string("unknown")
        }
        if let profileID { body["profileId"] = .string(profileID) }
        struct Answer: Decodable { var now: KidsNow }
        let answer: Answer = try await send("PUT", ["me", "kids", "place"], body: body)
        return answer.now
    }

    /// `POST /v1/me/kids/screen-time`: what this device counted offline.
    public func reportKidsScreenTime(day: String, seconds: Double, profileID: String? = nil) async throws {
        var body: [String: JSONValue] = ["day": .string(day), "seconds": .number(seconds.rounded())]
        if let profileID { body["profileId"] = .string(profileID) }
        var request = request("POST", ["me", "kids", "screen-time"])
        request.httpBody = try LobbyJSON.encoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await perform(request)
    }

    /// `POST /v1/me/kids/requests`: the child asks. The same question again is the one that waits.
    public func askKids(_ kind: KidsRequestKind, itemID: String? = nil, profileID: String? = nil) async throws -> KidsRequest {
        var body: [String: JSONValue] = ["kind": .string(kind.rawValue)]
        if let itemID { body["itemId"] = .string(itemID) }
        if let profileID { body["profileId"] = .string(profileID) }
        let answer: RequestAnswer = try await send("POST", ["me", "kids", "requests"], body: body)
        return answer.request
    }

    /// `GET /v1/me/kids/requests/{id}`.
    public func kidsRequest(_ id: String) async throws -> KidsRequest {
        let answer: RequestAnswer = try await get(["me", "kids", "requests", id])
        return answer.request
    }

    /// `DELETE /v1/me/kids/requests/{id}`: the child takes it back.
    @discardableResult
    public func cancelKidsRequest(_ id: String) async throws -> KidsRequest {
        let answer: RequestAnswer = try await send("DELETE", ["me", "kids", "requests", id])
        return answer.request
    }

    // MARK: Push

    /// `PUT /v1/me/push`: where this device is told of a child's question, or a device that waits
    /// to be let in, when the app does not run.
    ///
    /// - Parameter token: The APNs device token, as Apple handed it over.
    public func registerPush(token: Data, environment: PushEnvironment) async throws {
        let body: [String: JSONValue] = [
            "token": .string(token.map { String(format: "%02x", $0) }.joined()),
            "environment": .string(environment.rawValue),
        ]
        var request = request("PUT", ["me", "push"])
        request.httpBody = try LobbyJSON.encoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await perform(request)
    }

    /// `DELETE /v1/me/push`.
    public func unregisterPush() async throws {
        try await sendDiscardingAnswer("DELETE", ["me", "push"])
    }

    // MARK: Grown-ups

    /// `GET /v1/kids/now`: each kids viewer's mode now, for the viewer list.
    public func kidsNow() async throws -> [String: KidsNow] {
        struct Answer: Decodable {
            struct Viewer: Decodable {
                var profileId: String
                var now: KidsNow
            }
            var viewers: [Viewer]
        }
        let answer: Answer = try await get(["kids", "now"])
        return Dictionary(answer.viewers.map { ($0.profileId, $0.now) }, uniquingKeysWith: { first, _ in first })
    }

    /// `GET /v1/kids/requests`: the questions that wait for this grown-up.
    public func waitingKidsRequests() async throws -> [KidsRequest] {
        struct Answer: Decodable { var requests: [KidsRequest] }
        let answer: Answer = try await get(["kids", "requests"])
        return answer.requests
    }

    /// `POST /v1/kids/requests/{id}/answer`. The first answer counts.
    public func answerKids(
        _ id: String, _ answer: KidsAnswer, length: KidsLength? = nil, titleOnly: Bool? = nil
    ) async throws -> KidsRequest {
        var body = lengthFields(length)
        body["answer"] = .string(answer.rawValue)
        if let titleOnly { body["titleOnly"] = .bool(titleOnly) }
        let reply: RequestAnswer = try await send("POST", ["kids", "requests", id, "answer"], body: body)
        return reply.request
    }

    /// `GET /v1/profiles/{id}/kids/plan`.
    public func kidsPlan(profileID: String) async throws -> KidsPlanView {
        try await get(["profiles", profileID, "kids", "plan"])
    }

    /// `PUT /v1/profiles/{id}/kids/plan`: the whole plan.
    public func setKidsPlan(_ plan: KidsPlan, profileID: String) async throws -> KidsPlanView {
        struct Body: Encodable { var plan: KidsPlan }
        return try await send("PUT", ["profiles", profileID, "kids", "plan"], body: Body(plan: plan))
    }

    /// `PUT /v1/profiles/{id}/kids/override`: "Nothing until 15:00".
    public func setKidsOverride(_ mode: KidsMode, length: KidsLength?, profileID: String) async throws -> KidsPlanView {
        var body = lengthFields(length)
        body["mode"] = .string(mode.rawValue)
        return try await send("PUT", ["profiles", profileID, "kids", "override"], body: body)
    }

    /// `DELETE /v1/profiles/{id}/kids/override`.
    public func endKidsOverride(profileID: String) async throws -> KidsPlanView {
        try await send("DELETE", ["profiles", profileID, "kids", "override"])
    }

    /// `PATCH /v1/profiles/{id}/kids/answer`: Watch to Listen, or back, for the answer that runs.
    public func switchKidsAnswer(_ answer: KidsAnswer, profileID: String) async throws -> KidsPlanView {
        try await send("PATCH", ["profiles", profileID, "kids", "answer"], body: ["answer": answer.rawValue])
    }

    /// `DELETE /v1/profiles/{id}/kids/answer`: ends the answer; the child asks again.
    public func endKidsAnswer(profileID: String) async throws -> KidsPlanView {
        try await send("DELETE", ["profiles", profileID, "kids", "answer"])
    }
}
