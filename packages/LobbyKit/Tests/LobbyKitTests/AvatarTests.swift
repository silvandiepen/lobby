// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing

@testable import LobbyKit

@Suite struct AvatarTests {
    private func profile(_ json: String) throws -> Profile {
        try LobbyJSON.decoder().decode(Profile.self, from: Data(json.utf8))
    }

    @Test func absentIsNotNoPicture() throws {
        let old = try profile(#"{"id":"p","name":"A","color":"red"}"#)
        #expect(old.avatar == nil)
        #expect(!old.saysAvatar)
        let none = try profile(#"{"id":"p","name":"A","color":"red","avatar":null}"#)
        #expect(none.avatar == nil)
        #expect(none.saysAvatar)
        #expect(try profile(#"{"id":"p","name":"A","color":"red","avatar":"from-a-newer-app"}"#).avatar == "from-a-newer-app")

        let known = Profile(id: "p", name: "A", color: "red", avatar: "panda")
        #expect(old.keepingUnsaid(of: known).avatar == "panda")
        #expect(old.keepingUnsaid(of: known).keepingUnsaid(of: known).saysAvatar)
        #expect(none.keepingUnsaid(of: known).avatar == nil)
        #expect(old.keepingUnsaid(of: Profile(id: "other", name: "A", color: "red", avatar: "fox")).avatar == nil)
    }

    @Test func whatIsKeptOnTheDeviceSaysTheSameWhenItIsReadBack() throws {
        for (avatar, says) in [(nil, false), (nil, true), ("panda", true)] as [(String?, Bool)] {
            let one = Profile(id: "p", name: "N", color: "blue", avatar: avatar, saysAvatar: says)
            #expect(try LobbyJSON.decoder().decode(Profile.self, from: LobbyJSON.encoder().encode(one)) == one)
        }
    }

    @Test func onlyThePictureIsSentAndNoneIsAnExplicitNull() async throws {
        let stub = StubServer { request in
            request.method == "POST"
                ? .json(201, #"{"id":"p2","name":"B","color":"blue","avatar":"owl","kids":null}"#)
                : .json(200, #"{"id":"p1","name":"A","color":"red","avatar":null,"kids":null}"#)
        }
        let client = try stub.client()
        #expect(try await client.setAvatar(nil, profileID: "p1").saysAvatar)
        let none = try #require(stub.recorded.last)
        #expect(none.method == "PUT")
        #expect(none.path == "/v1/profiles/p1/avatar")
        #expect(String(decoding: none.body, as: UTF8.self) == #"{"avatar":null}"#)
        _ = try await client.setAvatar("fox", profileID: "p1")
        #expect(try stub.recorded.last?.json() as? [String: String] == ["avatar": "fox"])
        #expect(try await client.createProfile(name: "B", color: "blue", avatar: "owl").avatar == "owl")
        #expect(try stub.recorded.last?.json().keys.sorted() == ["avatar", "color", "name"])
        _ = try await client.createProfile(name: "B", color: "blue")
        #expect(try stub.recorded.last?.json().keys.sorted() == ["color", "name"])
    }
}
