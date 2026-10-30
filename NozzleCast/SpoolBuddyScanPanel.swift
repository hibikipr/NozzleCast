import SwiftUI

/// What the Scan tab's SpoolBuddy mode knows: the last tag the SpoolBuddy read, its scale reading,
/// and whether it's online. iPhones can't read Bambu spool tags (MIFARE Classic, which Core NFC
/// doesn't support), so the SpoolBuddy reads them and Bambuddy broadcasts each result over its
/// event socket, which this listens to while the mode is on screen.
@Observable
final class SpoolBuddySession {
    enum Scan: Equatable {
        case waiting
        case matched(SpoolBuddyMatchedSpoolDTO, tagUID: String)
        /// `tagData` is what Bambuddy decoded from a Bambu tag, when it could.
        case unknown(tagUID: String, trayUUID: String?, tagData: SpoolBuddyTagDataDTO? = nil)
        case lookupFailed(spoolmanUnavailable: Bool)
    }

    struct Device: Equatable {
        var hostname: String?
        var online: Bool
        /// False for a SpoolBuddy with its scale off or broken, whose readings are ignored.
        var scaleWorks = true
    }

    struct Reading: Equatable {
        var grams: Double
        var stable: Bool
    }

    private(set) var scan: Scan = .waiting
    /// The inventory spool for a `.matched` scan, once found in `AppStore.spools`.
    private(set) var matchedSpool: Spool?
    private(set) var weight: Reading?
    /// Keyed by SpoolBuddy device id. Nil until the device list or a presence event arrives.
    private(set) var devices: [String: Device]?
    private(set) var stream: BambuddyEventStream?

    @ObservationIgnored private weak var store: AppStore?

    var connectionState: BambuddyEventStream.State { stream?.state ?? .idle }
    var anyDeviceOnline: Bool { devices?.values.contains(where: \.online) ?? false }
    /// The online SpoolBuddy, if any, the status line is about.
    var onlineDevice: Device? { devices?.values.first(where: \.online) }

    /// False with no Bambuddy server to listen to (demo data).
    @discardableResult
    func start(store: AppStore) -> Bool {
        self.store = store
        guard stream == nil else { return true }
        guard let stream = store.makeEventStream() else { return false }
        stream.onEvent = { [weak self] in self?.apply($0) }
        self.stream = stream
        stream.start()
        Task {
            guard let list = await store.spoolBuddyDevices() else { return }
            applyDeviceList(list)
        }
        return true
    }

    /// Bambuddy's registered devices. Only the list says whether a scale works; presence events
    /// that arrived meanwhile are newer than its `online`.
    func applyDeviceList(_ list: [BambuddySpoolBuddyDeviceDTO]) {
        var known = devices ?? [:]
        for device in list {
            let scaleWorks = (device.hasScale ?? true) && (device.scaleOk ?? true)
            if var current = known[device.deviceId] {
                current.scaleWorks = scaleWorks
                known[device.deviceId] = current
            } else {
                known[device.deviceId] = Device(hostname: device.hostname, online: device.online, scaleWorks: scaleWorks)
            }
        }
        devices = known
        if !known.values.contains(where: { $0.online && $0.scaleWorks }) { weight = nil }
    }

    func stop() {
        stream?.stop()
        stream = nil
    }

    /// Shows `spool` as the scanned one, after the app linked the unknown tag `tagUID` to it.
    /// Bambuddy announces nothing for a link, so this stands in for the match the next scan gets.
    func linked(_ spool: Spool, tagUID: String) {
        guard spool.id.hasPrefix("bb-"), let id = Int(spool.id.dropFirst(3)) else { return }
        scan = .matched(SpoolBuddyMatchedSpoolDTO(id: id, material: spool.material, colorName: spool.colorName, brand: spool.brand), tagUID: tagUID)
        matchedSpool = spool
    }

    /// Back to waiting for the next spool.
    func clearScan() {
        scan = .waiting
        matchedSpool = nil
    }

    func apply(_ event: SpoolBuddyEvent) {
        switch event {
        case .tagMatched(let deviceID, let tagUID, _, let spool):
            markOnline(deviceID)
            scan = .matched(spool, tagUID: tagUID)
            matchedSpool = store?.spool("bb-\(spool.id)")
            if matchedSpool == nil, let store {
                Task {
                    let found = await store.spool(bambuddyID: spool.id)
                    if case .matched(let current, _) = scan, current.id == spool.id { matchedSpool = found }
                }
            }
        case .unknownTag(let deviceID, let tagUID, let trayUUID, _, let tagData):
            markOnline(deviceID)
            scan = .unknown(tagUID: tagUID, trayUUID: trayUUID, tagData: tagData)
            matchedSpool = nil
        case .tagRemoved(_, let tagUID):
            switch scan {
            case .matched(_, let current) where current == tagUID, .unknown(let current, _, _) where current == tagUID:
                clearScan()
            default:
                break
            }
        case .weight(let deviceID, let grams, let stable):
            markOnline(deviceID)
            guard devices?[deviceID]?.scaleWorks != false else { return }
            weight = Reading(grams: grams, stable: stable)
        case .lookupError(let deviceID, let spoolmanUnavailable):
            markOnline(deviceID)
            scan = .lookupFailed(spoolmanUnavailable: spoolmanUnavailable)
            matchedSpool = nil
        case .online(let deviceID, let hostname):
            var known = devices ?? [:]
            known[deviceID] = Device(hostname: hostname ?? known[deviceID]?.hostname, online: true, scaleWorks: known[deviceID]?.scaleWorks ?? true)
            devices = known
        case .offline(let deviceID):
            var known = devices ?? [:]
            known[deviceID] = Device(hostname: known[deviceID]?.hostname, online: false, scaleWorks: known[deviceID]?.scaleWorks ?? true)
            devices = known
            if !anyDeviceOnline { weight = nil }
        }
    }

    /// Anything a device reports means it's up, even before its next presence broadcast.
    private func markOnline(_ deviceID: String) {
        var known = devices ?? [:]
        guard known[deviceID]?.online != true else { return }
        known[deviceID] = Device(hostname: known[deviceID]?.hostname, online: true, scaleWorks: known[deviceID]?.scaleWorks ?? true)
        devices = known
    }
}

/// The SpoolBuddy mode's capture screen: waits for a spool on the SpoolBuddy and shows what
/// Bambuddy identified it as.
struct SpoolBuddyScanPanel: View {
    var session: SpoolBuddySession
    var isAvailable: Bool
    var onEdit: (Spool) -> Void
    var onAssign: (Spool) -> Void
    var onLinkUnknown: (_ tagUID: String, _ trayUUID: String?) -> Void
    var onAddUnknown: (_ tagUID: String, _ trayUUID: String?, _ tagData: SpoolBuddyTagDataDTO?) -> Void

    @Environment(AppStore.self) private var store

    var body: some View {
        // Scrolls so the card and its buttons stay reachable when the screen is short (landscape).
        ScrollView {
            VStack(spacing: 16) {
                if isAvailable {
                    statusRow
                    scanCard
                    weightRow
                } else {
                    unavailableCard
                }
            }
            .padding(.bottom, 100)
        }
        .scrollIndicators(.hidden)
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .ncFont(size: 13, weight: .medium, relativeTo: .footnote)
                .foregroundStyle(NCColor.textSecondary)
            Spacer()
            if session.connectionState == .connected, session.onlineDevice?.scaleWorks == false {
                Label {
                    Text("Scale off", comment: "SpoolBuddy scan mode: the SpoolBuddy's scale is disabled or broken, so no weight is shown")
                } icon: {
                    Image(systemName: "scalemass")
                }
                .ncFont(size: 12, relativeTo: .caption)
                .foregroundStyle(NCColor.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        switch session.connectionState {
        case .connected: session.anyDeviceOnline ? .green : .orange
        case .retrying: .red
        case .idle, .connecting: NCColor.textTertiary
        }
    }

    private var statusText: String {
        switch session.connectionState {
        case .idle, .connecting:
            return String(localized: "Connecting to Bambuddy…", comment: "SpoolBuddy scan mode: opening the live event connection")
        case .retrying(let attempt, _):
            return attempt > 2
                ? String(localized: "Can't reach Bambuddy's live updates. Retrying…", comment: "SpoolBuddy scan mode: event connection keeps failing")
                : String(localized: "Reconnecting to Bambuddy…", comment: "SpoolBuddy scan mode: event connection dropped")
        case .connected:
            guard let devices = session.devices else {
                return String(localized: "Connected", comment: "SpoolBuddy scan mode: connected, SpoolBuddy state not known yet")
            }
            if devices.isEmpty {
                return String(localized: "No SpoolBuddy registered with Bambuddy", comment: "SpoolBuddy scan mode status")
            }
            if let online = devices.values.first(where: \.online) {
                if let name = online.hostname, !name.isEmpty {
                    return String(localized: "\(name) is online", comment: "SpoolBuddy scan mode status; the SpoolBuddy's hostname")
                }
                return String(localized: "SpoolBuddy online", comment: "SpoolBuddy scan mode status")
            }
            return String(localized: "SpoolBuddy offline", comment: "SpoolBuddy scan mode status")
        }
    }

    private var scanCard: some View {
        VStack(spacing: 16) {
            switch session.scan {
            case .waiting:
                waitingContent
            case .matched(let dto, _):
                matchedContent(dto)
            case .unknown(let tagUID, let trayUUID, let tagData):
                unknownContent(tagUID: tagUID, trayUUID: trayUUID, tagData: tagData)
            case .lookupFailed(let spoolmanUnavailable):
                messageContent(
                    icon: "exclamationmark.triangle",
                    title: String(localized: "Lookup Failed", comment: "SpoolBuddy scan: Bambuddy couldn't look the tag up"),
                    message: spoolmanUnavailable
                        ? String(localized: "Bambuddy couldn't reach Spoolman to look this spool up. Place it again once Spoolman is back.", comment: "SpoolBuddy scan: lookup failed, Spoolman down")
                        : String(localized: "Bambuddy hit an error looking this spool up. Place it on the SpoolBuddy again.", comment: "SpoolBuddy scan: lookup failed")
                )
            }
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(hex: "#141414")))
    }

    private var waitingContent: some View {
        messageContent(
            icon: "sensor.tag.radiowaves.forward",
            title: String(localized: "Place a spool on your SpoolBuddy", comment: "SpoolBuddy scan: waiting for a tag"),
            message: String(localized: "The SpoolBuddy reads its RFID tag, and the spool opens here.", comment: "SpoolBuddy scan: waiting for a tag")
        )
    }

    private func messageContent(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            Image(systemName: icon)
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(NCColor.accentLight)
                .symbolEffect(.pulse, isActive: session.scan == .waiting)
            Text(title)
                .ncFont(size: 17, weight: .semibold, relativeTo: .headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text(message)
                .ncFont(size: 13, relativeTo: .footnote)
                .foregroundStyle(NCColor.textSecondary)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
    }

    private func matchedContent(_ dto: SpoolBuddyMatchedSpoolDTO) -> some View {
        let spool = session.matchedSpool
        return VStack(spacing: 14) {
            Group {
                if let spool {
                    spool.swatch
                } else {
                    Color(hex: "#" + String(dto.rgba?.prefix(6) ?? "808080"))
                }
            }
            .frame(width: 88, height: 88)
            .clipShape(Circle())

            VStack(spacing: 4) {
                Text(spool.map { "\($0.materialWithEffect) · \($0.colorName)" } ?? [dto.material, dto.colorName].compactMap { $0 }.joined(separator: " · "))
                    .ncFont(size: 18, weight: .bold, relativeTo: .headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text(spool?.brand ?? dto.brand ?? "")
                    .ncFont(size: 13, relativeTo: .footnote)
                    .foregroundStyle(NCColor.textSecondary)
                if let spool {
                    Text("\(spool.remainingPercent)% left · \(spool.locationCaption(printerName: store.printerName, amsUnitName: store.amsUnitName))", comment: "SpoolBuddy scan: scanned spool's remaining filament and where it is")
                        .ncFont(size: 12, relativeTo: .caption)
                        .foregroundStyle(NCColor.textTertiary)
                }
            }

            if let spool {
                HStack(spacing: 10) {
                    actionButton(String(localized: "Edit", comment: "SpoolBuddy scan: edit the scanned spool"), systemImage: "pencil", prominent: false) { onEdit(spool) }
                    actionButton(String(localized: "Assign to AMS", comment: "SpoolBuddy scan: assign the scanned spool to an AMS slot"), systemImage: "tray.and.arrow.down", prominent: true) { onAssign(spool) }
                }
            } else {
                ProgressView().tint(NCColor.accentLight)
            }
        }
    }

    private func unknownContent(tagUID: String, trayUUID: String?, tagData: SpoolBuddyTagDataDTO?) -> some View {
        VStack(spacing: 14) {
            messageContent(
                icon: "questionmark.circle",
                title: String(localized: "Unknown Spool", comment: "SpoolBuddy scan: the tag isn't linked to any spool"),
                message: trayUUID != nil
                    ? String(localized: "This Bambu Lab tag isn't linked to any spool in your inventory yet.", comment: "SpoolBuddy scan: unknown Bambu tag")
                    : String(localized: "This tag isn't linked to any spool in your inventory yet.", comment: "SpoolBuddy scan: unknown tag")
            )
            if let tagData {
                tagSummary(tagData)
            }
            HStack(spacing: 10) {
                actionButton(String(localized: "New Spool", comment: "SpoolBuddy scan: add the unknown spool to the inventory as a new spool"), systemImage: "plus", prominent: false) {
                    onAddUnknown(tagUID, trayUUID, tagData)
                }
                actionButton(String(localized: "Link to a Spool", comment: "SpoolBuddy scan: link the unknown tag to a spool already in the inventory"), systemImage: "link", prominent: true) {
                    onLinkUnknown(tagUID, trayUUID)
                }
            }
        }
    }

    /// What the tag says the roll is, so "New Spool" visibly starts from it.
    private func tagSummary(_ tagData: SpoolBuddyTagDataDTO) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color(hex: tagData.colorHex ?? "#808080"))
                .frame(width: 18, height: 18)
                .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(tagData.slicerFilamentName ?? [tagData.brand, tagData.material, tagData.subtype].compactMap { $0 }.joined(separator: " "))
                    .ncFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                    .foregroundStyle(.white)
                Text(String(localized: "From the tag: \(tagData.colorName ?? tagData.colorHex ?? "") · \(tagData.labelWeight ?? 1000) g", comment: "SpoolBuddy scan: an unknown Bambu tag's colour and net weight, as decoded from the tag"))
                    .ncFont(size: 12, relativeTo: .caption)
                    .foregroundStyle(NCColor.textSecondary)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.06)))
        .accessibilityElement(children: .combine)
    }

    private func actionButton(_ title: String, systemImage: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .ncFont(size: 15, weight: .semibold, relativeTo: .body)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(prominent ? NCColor.accent : Color.white.opacity(0.1))
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var weightRow: some View {
        if let weight = session.weight {
            HStack(spacing: 8) {
                Image(systemName: "scalemass")
                    .foregroundStyle(NCColor.textSecondary)
                Text("On scale: \(Int(weight.grams.rounded())) g", comment: "SpoolBuddy scale's live gross weight")
                    .ncFont(size: 14, weight: .semibold, relativeTo: .subheadline)
                    .foregroundStyle(.white)
                    .monospacedDigit()
                if let filament = filamentGrams(weight) {
                    Text("≈ \(filament) g of filament", comment: "Scale weight minus the empty spool's weight")
                        .ncFont(size: 13, relativeTo: .footnote)
                        .foregroundStyle(NCColor.textSecondary)
                        .monospacedDigit()
                }
                Spacer()
                if !weight.stable {
                    Text("Settling…", comment: "SpoolBuddy scale reading not yet stable")
                        .ncFont(size: 12, relativeTo: .caption)
                        .foregroundStyle(NCColor.textTertiary)
                }
            }
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
        }
    }

    /// The reading minus the matched spool's empty weight, when Bambuddy knows it.
    private func filamentGrams(_ weight: SpoolBuddySession.Reading) -> Int? {
        guard case .matched(let dto, _) = session.scan, let core = dto.coreWeight, weight.grams > Double(core) else { return nil }
        return Int((weight.grams - Double(core)).rounded())
    }

    private var unavailableCard: some View {
        messageContent(
            icon: "sensor.tag.radiowaves.forward",
            title: String(localized: "Connect to Bambuddy", comment: "SpoolBuddy scan mode without a server"),
            message: String(localized: "SpoolBuddy scans come through your Bambuddy server. Connect it in Settings to use this mode.", comment: "SpoolBuddy scan mode without a server")
        )
        .frame(maxWidth: .infinity, minHeight: 300)
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(hex: "#141414")))
    }
}

/// Picks the inventory spool an unknown SpoolBuddy tag belongs to. Offers only spools with no tag
/// yet, most recently used first: Bambuddy refuses a tag that another spool already carries.
struct LinkTagSpoolPicker: View {
    var tagUID: String
    var onPick: (Spool) -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var pendingSpool: Spool?

    private var candidates: [Spool] {
        let untagged = store.spools
            .filter { !$0.hasTag && !$0.isArchived }
            .sorted { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return untagged }
        return untagged.filter { spool in
            [spool.material, spool.subtype ?? "", spool.colorName, spool.brand].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if candidates.isEmpty {
                    Text(searchText.isEmpty
                         ? String(localized: "Every spool in your inventory already has a tag.", comment: "Link tag picker: no spool without a tag")
                         : String(localized: "No spool without a tag matches.", comment: "Link tag picker: search found nothing"))
                        .ncFont(size: 14, relativeTo: .subheadline)
                        .foregroundStyle(NCColor.textSecondary)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                ForEach(candidates) { spool in
                    Button { pendingSpool = spool } label: {
                        SpoolListRow(spool: spool)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(hex: "#212121").ignoresSafeArea())
            .searchable(text: $searchText, prompt: Text("Search spools", comment: "Link tag picker search field"))
            .navigationTitle(String(localized: "Link Tag to a Spool", comment: "Link tag picker title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", comment: "Dismisses the link tag picker")) { dismiss() }
                }
            }
            .confirmationDialog(
                String(localized: "Link this tag?", comment: "Link tag picker confirmation title"),
                isPresented: Binding(get: { pendingSpool != nil }, set: { if !$0 { pendingSpool = nil } }),
                titleVisibility: .visible,
                presenting: pendingSpool
            ) { spool in
                Button(String(localized: "Link to \(spool.materialWithEffect) · \(spool.colorName)", comment: "Link tag picker: confirm linking the tag to this spool")) {
                    onPick(spool)
                    dismiss()
                }
            } message: { _ in
                Text("Tag \(tagUID) will open this spool whenever it's placed on the SpoolBuddy.", comment: "Link tag picker confirmation message; the tag's UID")
            }
        }
        .presentationDetents([.medium, .large])
    }
}
