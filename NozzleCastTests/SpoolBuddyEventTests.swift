import Foundation
import Testing
@testable import NozzleCast

private final class BundleToken {}

/// A Bambuddy `/api/v1/ws` payload from `Fixtures/`. `spoolbuddy_tag_matched_local` and
/// `spoolbuddy_online` were recorded from a live Bambuddy 1.2.5.7 and SpoolBuddy; the rest follow
/// the shapes in its `backend/app/api/routes/spoolbuddy.py`.
func fixture(_ name: String) throws -> Data {
    let bundle = Bundle(for: BundleToken.self)
    let url = try #require(
        bundle.url(forResource: name, withExtension: "json")
            ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
        "missing fixture \(name).json"
    )
    return try Data(contentsOf: url)
}

struct SpoolBuddyEventDecodingTests {
    @Test func tagMatchedFromLocalInventory() throws {
        let event = SpoolBuddyEvent.decode(try fixture("spoolbuddy_tag_matched_local"))
        guard case .tagMatched(let device, let tag, let tray, let spool) = event else {
            Issue.record("decoded \(String(describing: event))")
            return
        }
        #expect(device == "sb-88a29e37dbb8")
        #expect(tag == "F6F0ECDF")
        #expect(tray == "36B6C12DB3DA4A39A50C275F510BD399")
        #expect(spool.id == 4)
        #expect(spool.material == "PLA")
        #expect(spool.subtype == "Basic")
        #expect(spool.colorName == "Cyan")
        #expect(spool.colorNameIsSynthesized == false)
        #expect(spool.rgba == "0086D6FF")
        #expect(spool.extraColors == nil)
        #expect(spool.brand == "Bambu Lab")
        #expect(spool.labelWeight == 1000)
        #expect(spool.coreWeight == 250)
        #expect(abs((spool.weightUsed ?? 0) - 952.92) < 0.001)
    }

    @Test func tagMatchedFromSpoolmanWithEmptyFields() throws {
        let event = SpoolBuddyEvent.decode(try fixture("spoolbuddy_tag_matched_spoolman"))
        guard case .tagMatched(_, let tag, let tray, let spool) = event else {
            Issue.record("decoded \(String(describing: event))")
            return
        }
        #expect(tag == "5D3E9A01")
        #expect(tray == nil)
        #expect(spool.id == 7)
        #expect(spool.brand == nil)
        #expect(spool.coreWeight == nil)
        #expect(spool.colorNameIsSynthesized == true)
        #expect(spool.extraColors == "EC984C,6CD4BC")
        #expect(spool.effectType == "silk")
    }

    @Test func unknownTag() throws {
        #expect(SpoolBuddyEvent.decode(try fixture("spoolbuddy_unknown_tag")) == .unknownTag(
            deviceID: "sb-88a29e37dbb8", tagUID: "04A2B3C4",
            trayUUID: "A1B2C3D4E5F60718293A4B5C6D7E8F90", tagType: "mifare_classic_1k"
        ))
    }

    @Test func unknownTagWithoutTagDataHasNone() throws {
        guard case .unknownTag(_, _, _, _, let tagData) = SpoolBuddyEvent.decode(try fixture("spoolbuddy_unknown_tag")) else {
            Issue.record("not an unknown tag")
            return
        }
        #expect(tagData == nil)
    }

    /// The `tag_data` Bambuddy's own #2685 integration test expects for a cyan PLA Basic tag.
    @Test func unknownTagCarriesTheDecodedSpool() throws {
        guard case .unknownTag(let device, let tag, let tray, let type, let tagData) = SpoolBuddyEvent.decode(try fixture("spoolbuddy_unknown_tag_with_tag_data")),
              let tagData else {
            Issue.record("no tag data decoded")
            return
        }
        #expect(device == "sb-88a29e37dbb8")
        #expect(tag == "865947E2")
        #expect(tray == "36B6C12DB3DA4A39A50C275F510BD399")
        #expect(type == "mifare_classic")
        #expect(tagData == SpoolBuddyTagDataDTO(
            material: "PLA", subtype: "Basic", colorName: "Cyan", rgba: "0086D6FF", brand: "Bambu Lab", labelWeight: 1000,
            slicerFilament: "GFA00", slicerFilamentName: "Bambu PLA Basic", nozzleTempMin: 190, nozzleTempMax: 230,
            coreWeight: 250, variantId: "A00-B08", diameter: 1.75, dryingTemp: 55, dryingTime: 8
        ))
    }

    @Test func malformedTagDataStillDeliversTheUnknownTag() throws {
        let json = #"{"type": "spoolbuddy_unknown_tag", "device_id": "sb-1", "tag_uid": "AB", "tag_data": {"subtype": "Basic"}}"#
        #expect(SpoolBuddyEvent.decode(Data(json.utf8)) == .unknownTag(deviceID: "sb-1", tagUID: "AB", trayUUID: nil, tagType: nil, tagData: nil))
    }

    @Test func tagRemoved() throws {
        #expect(SpoolBuddyEvent.decode(try fixture("spoolbuddy_tag_removed")) == .tagRemoved(deviceID: "sb-88a29e37dbb8", tagUID: "F6F0ECDF"))
    }

    @Test func weight() throws {
        #expect(SpoolBuddyEvent.decode(try fixture("spoolbuddy_weight")) == .weight(deviceID: "sb-88a29e37dbb8", grams: 937.4, stable: true))
    }

    @Test func lookupErrors() throws {
        #expect(SpoolBuddyEvent.decode(try fixture("spoolbuddy_lookup_error")) == .lookupError(deviceID: "sb-88a29e37dbb8", spoolmanUnavailable: false))
        #expect(SpoolBuddyEvent.decode(try fixture("spoolman_unavailable_scan")) == .lookupError(deviceID: "sb-88a29e37dbb8", spoolmanUnavailable: true))
    }

    @Test func spoolmanOutageOutsideAScanIsIgnored() {
        let data = Data(#"{"type": "spoolman_unavailable", "device_id": "x", "context": "slot_assign"}"#.utf8)
        #expect(SpoolBuddyEvent.decode(data) == nil)
    }

    @Test func presence() throws {
        #expect(SpoolBuddyEvent.decode(try fixture("spoolbuddy_online")) == .online(deviceID: "sb-88a29e37dbb8", hostname: "spoolbuddy"))
        #expect(SpoolBuddyEvent.decode(try fixture("spoolbuddy_offline")) == .offline(deviceID: "sb-88a29e37dbb8"))
    }

    @Test func otherMessagesAreIgnored() throws {
        #expect(SpoolBuddyEvent.decode(try fixture("printer_status")) == nil)
        #expect(SpoolBuddyEvent.decode(Data(#"{"type": "pong"}"#.utf8)) == nil)
        #expect(SpoolBuddyEvent.decode(Data("not json".utf8)) == nil)
        // A known type missing what it needs.
        #expect(SpoolBuddyEvent.decode(Data(#"{"type": "spoolbuddy_weight", "device_id": "x"}"#.utf8)) == nil)
    }
}

@MainActor
struct SpoolBuddySessionTests {
    private func event(_ name: String) throws -> SpoolBuddyEvent {
        try #require(SpoolBuddyEvent.decode(try fixture(name)))
    }

    @Test func scanLifecycle() throws {
        let session = SpoolBuddySession()
        #expect(session.scan == .waiting)

        try session.apply(event("spoolbuddy_tag_matched_local"))
        guard case .matched(let spool, let tag) = session.scan else {
            Issue.record("scan is \(session.scan)")
            return
        }
        #expect(spool.id == 4)
        #expect(tag == "F6F0ECDF")
        #expect(session.anyDeviceOnline)

        // Lifting a different tag leaves the scan alone.
        session.apply(.tagRemoved(deviceID: "sb-88a29e37dbb8", tagUID: "FFFFFFFF"))
        #expect(session.scan != .waiting)

        try session.apply(event("spoolbuddy_tag_removed"))
        #expect(session.scan == .waiting)

        try session.apply(event("spoolbuddy_unknown_tag"))
        #expect(session.scan == .unknown(tagUID: "04A2B3C4", trayUUID: "A1B2C3D4E5F60718293A4B5C6D7E8F90"))
    }

    @Test func anUnknownTagKeepsItsDecodedSpool() throws {
        let session = SpoolBuddySession()
        try session.apply(event("spoolbuddy_unknown_tag_with_tag_data"))
        guard case .unknown(let tag, _, let tagData) = session.scan else {
            Issue.record("scan is \(session.scan)")
            return
        }
        #expect(tag == "865947E2")
        #expect(tagData?.slicerFilamentName == "Bambu PLA Basic")
    }

    @Test func weightAndPresence() throws {
        let session = SpoolBuddySession()
        try session.apply(event("spoolbuddy_online"))
        #expect(session.devices?["sb-88a29e37dbb8"] == .init(hostname: "spoolbuddy", online: true))

        try session.apply(event("spoolbuddy_weight"))
        #expect(session.weight == .init(grams: 937.4, stable: true))

        try session.apply(event("spoolbuddy_offline"))
        #expect(session.devices?["sb-88a29e37dbb8"] == .init(hostname: "spoolbuddy", online: false))
        #expect(session.weight == nil)
    }

    @Test func readingsFromADeviceWithoutAWorkingScaleAreIgnored() throws {
        let session = SpoolBuddySession()
        session.applyDeviceList([
            BambuddySpoolBuddyDeviceDTO(deviceId: "sb-88a29e37dbb8", hostname: "spoolbuddy", online: true, hasScale: true, scaleOk: false),
        ])
        #expect(session.onlineDevice?.scaleWorks == false)

        try session.apply(event("spoolbuddy_weight"))
        #expect(session.weight == nil)

        // Presence events don't reset what the device list said about the scale.
        try session.apply(event("spoolbuddy_online"))
        #expect(session.onlineDevice?.scaleWorks == false)
    }

    @Test func linkingAnUnknownTagShowsTheSpool() throws {
        let session = SpoolBuddySession()
        try session.apply(event("spoolbuddy_unknown_tag"))
        let spool = Spool(id: "bb-12", material: "PETG", colorName: "Black", colorHex: "#000000", brand: "Elegoo", remainingPercent: 80, netWeightGrams: 1000, location: .storage(name: nil))
        session.linked(spool, tagUID: "04A2B3C4")

        guard case .matched(let dto, let tag) = session.scan else {
            Issue.record("scan is \(session.scan)")
            return
        }
        #expect(dto.id == 12)
        #expect(tag == "04A2B3C4")
        #expect(session.matchedSpool == spool)

        // Lifting the tag goes back to waiting, as for a scanned match.
        try session.apply(event("spoolbuddy_tag_removed").withTag("04A2B3C4"))
        #expect(session.scan == .waiting)
    }

    @Test func spoolTagFieldsDecode() throws {
        let data = Data(#"{"id": 4, "material": "PLA", "tag_uid": "F6F0ECDF", "tray_uuid": "36B6C12DB3DA4A39A50C275F510BD399"}"#.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let spool = try decoder.decode(BambuddySpoolDTO.self, from: data)
        #expect(spool.tagUid == "F6F0ECDF")
        #expect(spool.trayUuid == "36B6C12DB3DA4A39A50C275F510BD399")
    }

    @Test func deviceListDecodes() throws {
        let data = Data(#"[{"id": 1, "device_id": "sb-88a29e37dbb8", "hostname": "spoolbuddy", "online": true, "has_nfc": true, "has_scale": false, "scale_ok": false, "nfc_ok": true}]"#.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let list = try decoder.decode([BambuddySpoolBuddyDeviceDTO].self, from: data)
        #expect(list == [BambuddySpoolBuddyDeviceDTO(deviceId: "sb-88a29e37dbb8", hostname: "spoolbuddy", online: true, hasScale: false, scaleOk: false)])
    }
}

private extension SpoolBuddyEvent {
    /// The same removal, for another tag.
    func withTag(_ uid: String) -> SpoolBuddyEvent {
        guard case .tagRemoved(let device, _) = self else { return self }
        return .tagRemoved(deviceID: device, tagUID: uid)
    }
}

struct SpoolBuddyTagDataTests {
    private func cyanPLABasic() throws -> SpoolBuddyTagDataDTO {
        guard case .unknownTag(_, _, _, _, let tagData?) = SpoolBuddyEvent.decode(try fixture("spoolbuddy_unknown_tag_with_tag_data")) else {
            throw CancellationError()
        }
        return tagData
    }

    @Test func theFormStartsFromTheTag() throws {
        let form = try cyanPLABasic().scannedResult
        #expect(form.material == .pla)
        #expect(form.colorName == "Cyan")
        #expect(form.colorHex == "#0086D6")
        #expect(form.brand == "Bambu Lab")
        #expect(form.netWeightGrams == 1000)
    }

    @Test func anUntouchedFormSavesEverythingTheTagSays() throws {
        let tag = try cyanPLABasic()
        let form = tag.scannedResult
        #expect(tag.material(for: form) == "PLA")
        #expect(tag.createExtras(for: form) == SpoolCreateExtras(
            rgba: "0086D6FF", subtype: "Basic", coreWeight: 250, slicerFilament: "GFA00", slicerFilamentName: "Bambu PLA Basic",
            nozzleTempMin: 190, nozzleTempMax: 230
        ))
    }

    /// The pink PETG on the user's SpoolBuddy: Bambuddy's tag_data carried F9C1BD80, and the
    /// spool NozzleCast created was saved F9C1BDFF, opaque.
    @Test func anUntouchedColourKeepsTheTagsAlpha() {
        let translucent = SpoolBuddyTagDataDTO(material: "PETG", subtype: "Translucent", colorName: "Translucent Pink", rgba: "F9C1BD80", effectType: "translucent")
        var form = translucent.scannedResult
        #expect(form.colorHex == "#F9C1BD")
        #expect(translucent.createExtras(for: form).rgba == "F9C1BD80")
        form.colorHex = "#123456"
        #expect(translucent.createExtras(for: form).rgba == nil)
    }

    @Test func aTagMaterialTheFormCantShowIsKeptWhileUntouched() {
        let asa = SpoolBuddyTagDataDTO(material: "ASA", rgba: "FFFFFFFF")
        var form = asa.scannedResult
        #expect(form.material == .abs) // the closest of the form's four
        #expect(asa.material(for: form) == "ASA")
        form.material = .petg
        #expect(asa.material(for: form) == "PETG")
    }

    @Test func aChangedMaterialDropsTheTagsProfileButKeepsTheCore() throws {
        let tag = try cyanPLABasic()
        var form = tag.scannedResult
        form.material = .petg
        let extras = tag.createExtras(for: form)
        #expect(extras.subtype == nil)
        #expect(extras.slicerFilament == nil)
        #expect(extras.nozzleTempMin == nil)
        #expect(extras.coreWeight == 250)
    }

    @Test func aChangedColourDropsTheTagsColourDetails() {
        let silk = SpoolBuddyTagDataDTO(material: "PLA", subtype: "Silk+", rgba: "EC984CFF", extraColors: "EC984C,6CD4BC", effectType: "silk")
        var form = silk.scannedResult
        #expect(silk.createExtras(for: form).extraColors == "EC984C,6CD4BC")
        #expect(silk.createExtras(for: form).effectType == "silk")
        form.colorHex = "#000000"
        #expect(silk.createExtras(for: form).extraColors == nil)
        #expect(silk.createExtras(for: form).effectType == nil)
        #expect(silk.createExtras(for: form).subtype == "Silk+")
    }

    @Test func aTagWithoutAColourStartsGrey() {
        let tag = SpoolBuddyTagDataDTO(material: "PETG", rgba: nil)
        #expect(tag.colorHex == nil)
        #expect(tag.scannedResult.colorHex == "#808080")
        #expect(tag.scannedResult.material == .petg)
    }
}

struct SpoolRGBATests {
    @Test func alphaRoundTripsThroughBambuddysRGBA() {
        #expect(AppStore.rgba(hex: "#f9c1bd", alpha: 1) == "F9C1BDFF")
        #expect(AppStore.rgba(hex: "#F9C1BD", alpha: Double(0x80) / 255) == "F9C1BD80")
        #expect(AppStore.rgba(hex: "F9C1BD", alpha: 0) == "F9C1BD00")
    }
}
