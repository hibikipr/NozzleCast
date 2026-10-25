import Foundation
import Testing
@testable import NozzleCast

/// A socket that answers with a script of messages, then drops.
@MainActor
private final class ScriptedSocket: BambuddyWebSocket {
    let url: URL
    private var messages: [String]
    /// Waits for the client's ping before the first message, as Bambuddy only answers then.
    private let waitsForPing: Bool
    private(set) var sent: [String] = []
    private(set) var cancelled = false

    init(url: URL, messages: [String], waitsForPing: Bool) {
        self.url = url
        self.messages = messages
        self.waitsForPing = waitsForPing
    }

    func receive() async throws -> String {
        while waitsForPing && sent.isEmpty && !cancelled {
            await Task.yield()
        }
        guard !cancelled, !messages.isEmpty else { throw URLError(.networkConnectionLost) }
        return messages.removeFirst()
    }

    func send(_ text: String) async throws {
        sent.append(text)
    }

    func cancel() {
        cancelled = true
    }
}

/// Records what the stream does, connection by connection.
@MainActor
private final class Harness {
    var tokens: [Result<String?, Error>]
    var scripts: [[String]]
    var waitsForPing = false
    var sleepsBeforeStopping: Int
    private(set) var tokenFetches = 0
    private(set) var sockets: [ScriptedSocket] = []
    private(set) var sleeps: [Duration] = []
    private(set) var events: [SpoolBuddyEvent] = []
    private(set) var states: [BambuddyEventStream.State] = []

    init(tokens: [Result<String?, Error>], scripts: [[String]], sleepsBeforeStopping: Int) {
        self.tokens = tokens
        self.scripts = scripts
        self.sleepsBeforeStopping = sleepsBeforeStopping
    }

    func makeStream(baseURL: URL = URL(string: "http://bambuddy.local:8000")!) -> BambuddyEventStream {
        let stream = BambuddyEventStream(
            baseURL: baseURL,
            fetchToken: { [unowned self] in
                tokenFetches += 1
                return try tokens.removeFirst().get()
            },
            makeSocket: { [unowned self] url in
                let socket = ScriptedSocket(url: url, messages: scripts.isEmpty ? [] : scripts.removeFirst(), waitsForPing: waitsForPing)
                sockets.append(socket)
                return socket
            },
            sleep: { [unowned self] duration in
                sleeps.append(duration)
                if sleeps.count >= sleepsBeforeStopping { throw CancellationError() }
            },
            pingInterval: .seconds(3600)
        )
        stream.onEvent = { [unowned self] in events.append($0) }
        return stream
    }
}

private struct TokenRefused: Error {}

@MainActor
struct BambuddyEventStreamTests {
    @Test func everyReconnectFetchesAFreshTokenAndBacksOff() async throws {
        let pong = #"{"type":"pong"}"#
        let harness = Harness(
            tokens: [.success("t1"), .success("t2"), .success("t3"), .success("t4")],
            // Two refused handshakes, then one connection that works and later drops.
            scripts: [[], [], [pong], []],
            sleepsBeforeStopping: 4
        )
        let stream = harness.makeStream()
        await stream.run()

        #expect(harness.tokenFetches == 4)
        #expect(harness.sockets.map(\.url.absoluteString) == [
            "ws://bambuddy.local:8000/api/v1/ws?token=t1",
            "ws://bambuddy.local:8000/api/v1/ws?token=t2",
            "ws://bambuddy.local:8000/api/v1/ws?token=t3",
            "ws://bambuddy.local:8000/api/v1/ws?token=t4",
        ])
        // 1 s, 2 s, then back to 1 s once the third connection answered.
        #expect(harness.sleeps == [.seconds(1), .seconds(2), .seconds(1), .seconds(2)])
        let allClosed = harness.sockets.allSatisfy { $0.cancelled }
        #expect(allClosed)
        #expect(stream.state == .retrying(attempt: 2, reason: URLError(.networkConnectionLost).localizedDescription))
    }

    @Test func aRefusedTokenIsRetriedWithoutOpeningASocket() async throws {
        let harness = Harness(tokens: [.failure(TokenRefused()), .success("t2")], scripts: [[]], sleepsBeforeStopping: 2)
        await harness.makeStream().run()

        #expect(harness.tokenFetches == 2)
        #expect(harness.sockets.count == 1)
        #expect(harness.sockets.first?.url.absoluteString == "ws://bambuddy.local:8000/api/v1/ws?token=t2")
    }

    @Test func connectsWithoutATokenWhenTheServerHasNone() async throws {
        let harness = Harness(tokens: [.success(nil)], scripts: [[]], sleepsBeforeStopping: 1)
        await harness.makeStream().run()

        #expect(harness.sockets.first?.url.absoluteString == "ws://bambuddy.local:8000/api/v1/ws")
    }

    @Test func pingsAndDeliversSpoolBuddyEvents() async throws {
        let messages = try [
            #"{"type":"pong"}"#,
            String(decoding: fixture("printer_status"), as: UTF8.self),
            String(decoding: fixture("spoolbuddy_tag_matched_local"), as: UTF8.self),
            String(decoding: fixture("spoolbuddy_weight"), as: UTF8.self),
        ]
        let harness = Harness(tokens: [.success("t1")], scripts: [messages], sleepsBeforeStopping: 1)
        harness.waitsForPing = true
        await harness.makeStream().run()

        #expect(harness.sockets.first?.sent.first == #"{"type":"ping"}"#)
        #expect(harness.events.count == 2)
        guard case .tagMatched(_, _, _, let spool) = harness.events.first else {
            Issue.record("first event is \(String(describing: harness.events.first))")
            return
        }
        #expect(spool.id == 4)
        #expect(harness.events.last == .weight(deviceID: "sb-88a29e37dbb8", grams: 937.4, stable: true))
    }

    @Test func stopEndsTheLoop() async throws {
        let harness = Harness(tokens: Array(repeating: .success("t"), count: 100), scripts: [], sleepsBeforeStopping: 100)
        let stream = harness.makeStream()
        stream.start()
        await Task.yield()
        stream.stop()
        #expect(stream.state == .idle)
    }

    @Test func backoffIsCapped() {
        #expect((1...8).map(BambuddyEventStream.backoff(attempt:)) == [1, 2, 4, 8, 16, 30, 30, 30].map { .seconds($0) })
    }

    @Test(arguments: [
        ("http://10.0.0.5:8000", "ws://10.0.0.5:8000/api/v1/ws?token=abc"),
        ("https://bambuddy.example.com", "wss://bambuddy.example.com/api/v1/ws?token=abc"),
        ("https://example.com/bambuddy", "wss://example.com/bambuddy/api/v1/ws?token=abc"),
    ])
    func webSocketURL(base: String, expected: String) throws {
        let url = BambuddyEventStream.webSocketURL(baseURL: try #require(URL(string: base)), token: "abc")
        #expect(url?.absoluteString == expected)
    }
}
