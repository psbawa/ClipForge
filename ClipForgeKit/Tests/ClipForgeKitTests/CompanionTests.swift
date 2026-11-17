import Foundation
import Network
import SwiftData
import Testing
@testable import ClipForgeKit

private func req(_ method: String, _ path: String, token: String? = nil, body: Data = Data()) -> LocalHTTPServer.Request {
    LocalHTTPServer.Request(method: method, path: path, query: [:], headers: token.map { [CompanionAPI.tokenHeader.lowercased(): $0] } ?? [:],
                            body: body, bodyFile: nil, remote: "192.168.1.5")
}

/// Pairing needs the live code, every other route needs a paired token, five wrong codes burn the code.
@MainActor @Test func companionPairingAndAuth() async throws {
    let (m, _, src) = try makeModel(channel: "UC_me")
    let saved = m.companionDevices
    defer { m.companionDevices = saved; PairedDevice.save(saved) }     // never leave a test device in the real Keychain
    m.companionDevices = []
    let rec = ClipRecord(Highlight(start: 0, end: 20, title: "Clutch", hook: "", score: 80, reason: "r"), style: .pop)
    rec.source = src; rec.status = .ready; m.context.insert(rec); try m.context.save()

    #expect(await m.handleCompanion(req("GET", "/v1/clips")).status == 401)
    #expect(await m.handleCompanion(req("POST", "/v1/pair", body: try JSONEncoder().encode(PairRequest(code: "111111", deviceName: "x")))).status == 409)  // no code active
    m.newPairCode()
    let code = try #require(m.companionPairCode)
    let wrong = code == "000000" ? "000001" : "000000"
    for _ in 0..<5 { _ = await m.handleCompanion(req("POST", "/v1/pair", body: try JSONEncoder().encode(PairRequest(code: wrong, deviceName: "x")))) }
    #expect(m.companionPairCode == nil)                                                      // burned after 5 wrong tries
    m.newPairCode()
    let ok = await m.handleCompanion(req("POST", "/v1/pair", body: try JSONEncoder().encode(PairRequest(code: m.companionPairCode!, deviceName: "Test iPhone"))))
    #expect(ok.status == 200 && m.companionPairCode == nil)                                  // single use
    let token = try JSONDecoder().decode(PairResponse.self, from: ok.body).token
    #expect(m.companionDevices.map(\.name) == ["Test iPhone"] && m.companionDevices[0].tokenHash != token)   // only the hash is stored

    let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
    let clips = try d.decode([CompanionClip].self, from: await m.handleCompanion(req("GET", "/v1/clips", token: token)).body)
    #expect(clips.map(\.title) == ["Clutch"] && clips[0].needsReview)
    #expect(await m.handleCompanion(req("GET", "/v1/clips", token: "forged")).status == 401)
    let approved = try d.decode(CompanionClip.self, from: await m.handleCompanion(req("POST", "/v1/clips/\(rec.id.uuidString)/approve", token: token)).body)
    #expect(approved.status == "approved" && rec.status == .approved)
    _ = await m.handleCompanion(req("POST", "/v1/clips/\(rec.id.uuidString)/title", token: token, body: try JSONEncoder().encode(TitleRequest(title: "New name"))))
    #expect(rec.title.hasPrefix("New name"))
    #expect(await m.handleCompanion(req("GET", "/v1/clips/\(UUID().uuidString)", token: token)).status == 404)
    m.unpair(m.companionDevices[0])
    #expect(await m.handleCompanion(req("GET", "/v1/status", token: token)).status == 401)    // unpaired phones lose access
}

@Test func companionAcceptsOnlyLocalAddresses() {
    func v4(_ s: String) -> NWEndpoint.Host { .ipv4(IPv4Address(s)!) }
    for ok in ["192.168.1.20", "10.0.0.5", "172.20.1.1", "127.0.0.1", "169.254.3.4"] { #expect(LocalHTTPServer.isLocal(v4(ok)), "\(ok)") }
    for bad in ["8.8.8.8", "172.32.0.1", "100.64.1.1", "203.0.113.9"] { #expect(!LocalHTTPServer.isLocal(v4(bad)), "\(bad)") }
    #expect(LocalHTTPServer.isLocal(.ipv6(IPv6Address("fe80::1")!)) && !LocalHTTPServer.isLocal(.ipv6(IPv6Address("2001:db8::1")!)))
}
