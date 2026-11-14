import Foundation
import Testing
@testable import NozzleCast

/// Records every request `URLSession.shared` sends while registered, and answers each with an
/// empty JSON object: the bodies are what's under test, not the responses.
nonisolated final class RecordingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [(method: String, path: String, body: [String: Any])] = []

    static func record(_ work: () async throws -> Void) async rethrows -> [(method: String, path: String, body: [String: Any])] {
        requests = []
        URLProtocol.registerClass(RecordingURLProtocol.self)
        defer { URLProtocol.unregisterClass(RecordingURLProtocol.self) }
        try await work()
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "bambuddy.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&chunk, maxLength: chunk.count)
                if n <= 0 { break }
                buffer.append(chunk, count: n)
            }
            stream.close()
            data = buffer
        }
        let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        Self.requests.append((request.httpMethod ?? "GET", request.url?.path ?? "", body))
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A spool added or linked from a scanned tag is sent the way Bambuddy's own SpoolBuddy kiosk
/// sends it (`SpoolBuddyDashboard.handleQuickAddToInventory` and its link handler).
@Suite(.serialized)
struct SpoolTagRequestTests {
    static func client(_ inventory: InventoryBackend) -> BambuddyAPIClient {
        BambuddyAPIClient(baseURL: URL(string: "https://bambuddy.test")!, apiKey: "test", inventory: inventory)
    }

    static let cyan = SpoolBuddyTagDataDTO(
        material: "PLA", subtype: "Basic", colorName: "Cyan", rgba: "0086D6FF", brand: "Bambu Lab", labelWeight: 1000,
        slicerFilament: "GFA00", slicerFilamentName: "Bambu PLA Basic", nozzleTempMin: 190, nozzleTempMax: 230,
        coreWeight: 250, variantId: "A00-B08", diameter: 1.75, dryingTemp: 55, dryingTime: 8
    )

    static func createSpool(_ client: BambuddyAPIClient, from tag: SpoolBuddyTagDataDTO) async {
        let form = tag.scannedResult
        let extras = tag.createExtras(for: form)
        // The empty `{}` response doesn't decode as a spool; only the request matters here.
        _ = try? await client.createSpool(
            material: tag.material(for: form), colorName: form.colorName,
            rgba: extras.rgba ?? AppStore.rgba(hex: form.colorHex, alpha: 1),
            brand: form.brand, labelWeight: form.netWeightGrams, extras: extras
        )
    }

    @Test func builtInNewSpoolIsLabelledAsTheKioskLabelsIt() async throws {
        let client = Self.client(.builtIn)
        let requests = try await RecordingURLProtocol.record {
            await Self.createSpool(client, from: Self.cyan)
            try await client.linkTag(spoolID: 7, tagUID: "865947E2", trayUUID: "36B6C12DB3DA4A39A50C275F510BD399", origin: .newSpool)
        }
        try #require(requests.count == 2)
        #expect(requests[0].body["core_weight"] as? Int == 250)
        #expect(requests[0].body["color_name"] as? String == "Cyan")
        #expect(requests[1].method == "PATCH")
        #expect(requests[1].path == "/api/v1/inventory/spools/7/link-tag")
        #expect(requests[1].body["tag_type"] as? String == "bambulab")
        #expect(requests[1].body["data_origin"] as? String == "spoolbuddy")
    }

    @Test func builtInLinkToAnExistingSpool() async throws {
        let client = Self.client(.builtIn)
        let requests = try await RecordingURLProtocol.record {
            try await client.linkTag(spoolID: 7, tagUID: "04A2B3C4", trayUUID: nil, origin: .existingSpool)
        }
        #expect(requests.first?.body["tag_type"] as? String == "generic")
        #expect(requests.first?.body["data_origin"] as? String == "nfc_link")
        #expect(requests.first?.body["tray_uuid"] == nil)
    }

    /// Bambuddy writes a sent core weight to the Spoolman spool's own `spool_weight` (#2908), so
    /// its kiosk sends none, and Spoolman's tag route takes only the tag.
    @Test func spoolmanSendsNoCoreWeightAndAPlainLink() async throws {
        let client = Self.client(.spoolman)
        let requests = try await RecordingURLProtocol.record {
            await Self.createSpool(client, from: Self.cyan)
            try await client.linkTag(spoolID: 7, tagUID: "865947E2", trayUUID: "36B6C12DB3DA4A39A50C275F510BD399", origin: .newSpool)
        }
        try #require(requests.count == 2)
        #expect(requests[0].body["core_weight"] == nil)
        #expect(requests[0].body["core_weight_catalog_id"] == nil)
        #expect(requests[0].body["slicer_filament"] as? String == "GFA00")
        #expect(requests[1].path == "/api/v1/spoolman/inventory/spools/7/tag")
        #expect(Set(requests[1].body.keys) == ["tag_uid", "tray_uuid"])
    }

    /// A colour Bambuddy's catalog doesn't know comes with no name, and the spool is sent without
    /// one rather than with an empty one.
    @Test func unnamedColourIsSentWithoutAName() async throws {
        var tag = Self.cyan
        tag.colorName = nil
        tag.rgba = "123456FF"
        let requests = await RecordingURLProtocol.record { await Self.createSpool(Self.client(.builtIn), from: tag) }
        #expect(requests.first?.body["color_name"] == nil)
        #expect(requests.first?.body["rgba"] as? String == "123456FF")
    }
}
