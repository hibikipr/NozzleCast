import SwiftUI

enum ScanMode: CaseIterable, Hashable {
    case barcode, labelPhoto, manual, spoolBuddy

    var label: String {
        switch self {
        case .barcode: String(localized: "Barcode", comment: "Scan mode: live barcode scanning")
        case .labelPhoto: String(localized: "Label Photo", comment: "Scan mode: photograph the printed label")
        case .manual: String(localized: "Manual", comment: "Scan mode: enter filament details by hand")
        case .spoolBuddy: String(localized: "SpoolBuddy", comment: "Scan mode: wait for a spool placed on the SpoolBuddy NFC reader and scale")
        }
    }
}

enum ScanStep {
    case capture, loading, review, done
}

struct ScannedResult {
    var material: FilamentMaterial
    var colorName: String
    var colorHex: String
    var brand: String
    var netWeightGrams: Int
    var barcode: String?
    var alsoMatches: String?
}

struct ScanView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Binding var selectedTab: RootTab

    @State private var mode: ScanMode = .barcode
    @State private var step: ScanStep = .capture
    @State private var result = ScannedResult(material: .pla, colorName: "", colorHex: "#808080", brand: "", netWeightGrams: 1000, barcode: nil, alsoMatches: nil)
    @State private var addedSpool: Spool?
    @State private var showAssignPicker = false
    @State private var scannerBridge = ScannerBridge()
    @State private var showManualCodeEntry = false
    @State private var manualCodeText = ""
    @State private var notFoundNotice = false
    @State private var lookupErrorMessage: String?
    @State private var spoolBuddy = SpoolBuddySession()
    @State private var spoolBuddyAvailable = true
    @State private var isVisible = false
    /// The NFC tag of the unknown spool being added from SpoolBuddy mode, linked to the new spool.
    @State private var pendingTag: (uid: String, trayUUID: String?)?
    /// What Bambuddy decoded from that tag, when it's a Bambu tag it could read: the form starts
    /// from it, and the spool gets its profile and core weight too.
    @State private var pendingTagData: SpoolBuddyTagDataDTO?
    @State private var editingSpool: Spool?
    @State private var assigningSpool: Spool?
    /// The unknown SpoolBuddy tag being linked to an existing spool.
    @State private var linkingTag: UnknownTag?

    struct UnknownTag: Identifiable {
        var uid: String
        var trayUUID: String?
        var id: String { uid }
    }

    /// Bambuddy's event socket only stays open while SpoolBuddy mode is on screen: iOS drops it in
    /// the background anyway.
    private var listensToSpoolBuddy: Bool {
        mode == .spoolBuddy && isVisible && scenePhase == .active
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                switch step {
                case .capture, .loading:
                    captureHeader
                default: EmptyView()
                }

                switch step {
                case .capture:
                    captureBody
                case .loading:
                    loadingBody
                case .review:
                    reviewBody
                case .done:
                    doneBody
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(NCColor.canvasBackground.ignoresSafeArea())
            .navigationBarHidden(true)
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
            .task(id: listensToSpoolBuddy) {
                guard listensToSpoolBuddy else { return }
                spoolBuddyAvailable = spoolBuddy.start(store: store)
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3600))
                }
                spoolBuddy.stop()
            }
            .onChange(of: mode) { _, newMode in
                scannerBridge.reset()
                if newMode == .manual {
                    result = ScannedResult(material: .pla, colorName: "", colorHex: "#808080", brand: "", netWeightGrams: 1000, barcode: nil, alsoMatches: nil)
                }
            }
            .onChange(of: scannerBridge.lastBarcode) { _, newBarcode in
                guard mode == .barcode, step == .capture, let newBarcode else { return }
                runBarcodeLookup(newBarcode)
            }
            .alert("Enter Code Manually", isPresented: $showManualCodeEntry) {
                TextField("Barcode or SKU", text: $manualCodeText)
                    .textInputAutocapitalization(.characters)
                Button("Look Up") {
                    let code = manualCodeText.trimmingCharacters(in: .whitespacesAndNewlines)
                    manualCodeText = ""
                    if !code.isEmpty { runBarcodeLookup(code, notifyIfMissing: true) }
                }
                Button("Cancel", role: .cancel) { manualCodeText = "" }
            }
            .alert("Not Found", isPresented: $notFoundNotice) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("No match in the Open Filament Database or SpoolmanDB-Community. Fill in the details below and it'll be added as entered.")
            }
            .alert("Lookup Failed", isPresented: Binding(
                get: { lookupErrorMessage != nil },
                set: { if !$0 { lookupErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(lookupErrorMessage ?? "")
            }
            .alert("Camera Issue", isPresented: Binding(
                get: { scannerBridge.failureMessage != nil },
                set: { if !$0 { scannerBridge.failureMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(scannerBridge.failureMessage ?? "")
            }
            .sheet(isPresented: $showAssignPicker) {
                if let addedSpool {
                    AssignPickerSheet(spool: addedSpool) {
                        showAssignPicker = false
                        reset()
                        selectedTab = .inventory
                    }
                }
            }
            .sheet(item: $editingSpool) { spool in
                EditSpoolSheet(spool: spool)
            }
            .sheet(item: $linkingTag) { tag in
                LinkTagSpoolPicker(tagUID: tag.uid) { spool in
                    store.linkTag(uid: tag.uid, trayUUID: tag.trayUUID, toSpool: spool.id)
                    spoolBuddy.linked(spool, tagUID: tag.uid)
                }
            }
            .sheet(item: $assigningSpool) { spool in
                AssignPickerSheet(spool: spool) {
                    assigningSpool = nil
                }
            }
        }
    }

    private var captureHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Scan Filament")
                .ncFont(size: 24, weight: .bold, relativeTo: .title)

            HStack(spacing: 2) {
                ForEach(ScanMode.allCases, id: \.self) { m in
                    Text(m.label)
                        .ncFont(size: 13, weight: .semibold, relativeTo: .footnote)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .foregroundStyle(mode == m ? .white : NCColor.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            Capsule().fill(mode == m ? NCColor.segmentThumb : .clear)
                        )
                        .onTapGesture { mode = m }
                }
            }
            .padding(2)
            .background(Capsule().fill(NCColor.segmentTrack))
        }
    }

    @ViewBuilder
    private var captureBody: some View {
        if mode == .manual {
            manualFormBody
        } else if mode == .spoolBuddy {
            SpoolBuddyScanPanel(
                session: spoolBuddy,
                isAvailable: spoolBuddyAvailable,
                onEdit: { editingSpool = $0 },
                onAssign: { assigningSpool = $0 },
                onLinkUnknown: { tagUID, trayUUID in linkingTag = UnknownTag(uid: tagUID, trayUUID: trayUUID) },
                onAddUnknown: { tagUID, trayUUID, tagData in
                    // Without decoded tag data (an older Bambuddy or SpoolBuddy daemon, or a
                    // non-Bambu tag) the form starts blank; a tray UUID still says it's a genuine
                    // Bambu Lab spool.
                    result = tagData?.scannedResult
                        ?? ScannedResult(material: .pla, colorName: "", colorHex: "#808080", brand: trayUUID != nil ? "Bambu Lab" : "", netWeightGrams: 1000, barcode: nil, alsoMatches: nil)
                    pendingTag = (tagUID, trayUUID)
                    pendingTagData = tagData
                    step = .review
                }
            )
        } else {
            scannerBody
        }
    }

    private var scannerBody: some View {
        VStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(hex: "#141414"))

                ScannerCameraGate(mode: mode == .barcode ? .barcode : .text, bridge: scannerBridge)
                    .id(mode)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                VStack {
                    HStack {
                        CornerBracket().frame(width: 28, height: 28)
                        Spacer()
                        CornerBracket().rotationEffect(.degrees(90)).frame(width: 28, height: 28)
                    }
                    Spacer()
                    if !ScannerAvailability.isSupported {
                        ScanLine()
                    }
                    Spacer()
                    HStack {
                        CornerBracket().rotationEffect(.degrees(-90)).frame(width: 28, height: 28)
                        Spacer()
                        CornerBracket().rotationEffect(.degrees(180)).frame(width: 28, height: 28)
                    }
                }
                .padding(20)
                .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 360)

            Group {
                if mode == .barcode {
                    Text("Point at the box barcode")
                } else {
                    Text("Photograph the filament label")
                }
            }
            .ncFont(size: 13, relativeTo: .footnote)
            .foregroundStyle(NCColor.textSecondary)

            Spacer()

            VStack(spacing: 10) {
                if mode == .labelPhoto {
                    Button {
                        runTextParse(scannerBridge.liveText)
                    } label: {
                        ZStack {
                            Circle().stroke(Color.white, lineWidth: 3).frame(width: 72, height: 72)
                            Circle().fill(Color.white).frame(width: 58, height: 58)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(scannerBridge.liveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(scannerBridge.liveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.4 : 1)
                } else {
                    Text("Scanning automatically…")
                        .ncFont(size: 12.5, weight: .medium, relativeTo: .caption)
                        .foregroundStyle(NCColor.textTertiary)
                        .frame(height: 72)
                }

                Button("or enter code manually") { showManualCodeEntry = true }
                    .ncFont(size: 12.5, relativeTo: .caption)
                    .foregroundStyle(NCColor.textTertiary)
            }
            .padding(.bottom, 100)
        }
    }

    private var loadingBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            cancelRow

            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(hex: "#141414"))
                    .frame(height: 360)
                    .opacity(0.5)

                VStack(spacing: 14) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(NCColor.accentLight)
                        .scaleEffect(1.3)
                    Text("Looking up filament…")
                        .ncFont(size: 13, weight: .medium, relativeTo: .footnote)
                        .foregroundStyle(.white)
                }
                .padding(24)
                .glassCard()
            }
        }
    }

    private var cancelRow: some View {
        HStack {
            Button {
                reset()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    private var reviewBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                cancelRow

                Text("Review Details")
                    .ncFont(size: 24, weight: .bold, relativeTo: .title)

                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(hex: result.colorHex))
                        .frame(height: 90)
                    if let also = result.alsoMatches {
                        Text("Also matches: \(also)")
                            .ncFont(size: 11.5, relativeTo: .caption)
                            .foregroundStyle(NCColor.textTertiary)
                    }
                    if let pendingTag {
                        Label {
                            Text("Linked to the SpoolBuddy tag \(pendingTag.uid)", comment: "Review screen: the new spool gets the scanned NFC tag")
                        } icon: {
                            Image(systemName: "sensor.tag.radiowaves.forward")
                        }
                        .ncFont(size: 11.5, relativeTo: .caption)
                        .foregroundStyle(NCColor.textTertiary)
                    }
                    if let pendingTagData {
                        Text("Filled in from the tag: \(pendingTagData.slicerFilamentName ?? pendingTagData.material)", comment: "Review screen: the details came from the scanned Bambu tag, followed by its filament name")
                            .ncFont(size: 11.5, relativeTo: .caption)
                            .foregroundStyle(NCColor.textTertiary)
                    }
                }

                VStack(spacing: 12) {
                    labeledField(String(localized: "Brand", comment: "Filament field label"), text: $result.brand)
                    labeledField(String(localized: "Material", comment: "Filament field label"), text: Binding(
                        get: { result.material.rawValue },
                        set: { newValue in
                            if let m = FilamentMaterial(rawValue: newValue) { result.material = m }
                        }
                    ))
                    labeledField(String(localized: "Color name", comment: "Filament field label"), text: $result.colorName)
                    labeledField(String(localized: "Net weight (g)", comment: "Filament field label"), text: Binding(
                        get: { String(result.netWeightGrams) },
                        set: { result.netWeightGrams = Int($0) ?? result.netWeightGrams }
                    ))
                    if result.barcode != nil {
                        labeledField(String(localized: "Barcode", comment: "Filament field label"), text: Binding(
                            get: { result.barcode ?? "" },
                            set: { result.barcode = $0.isEmpty ? nil : $0 }
                        ))
                    }
                }

                Button {
                    addToInventory()
                } label: {
                    Text("Add to Inventory")
                        .ncFont(size: 16, weight: .semibold, relativeTo: .body)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(NCColor.accent))
                }
                .padding(.top, 4)
                .padding(.bottom, 100)
            }
        }
    }

    private func labeledField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .ncFont(size: 12, weight: .medium, relativeTo: .caption)
                .foregroundStyle(NCColor.textSecondary)
            TextField("", text: text)
                .ncFont(size: 15, relativeTo: .subheadline)
                .foregroundStyle(.white)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
        }
    }

    private var manualFormBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Enter Filament Details")
                    .ncFont(size: 20, weight: .bold, relativeTo: .title3)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Filament color")
                        .ncFont(size: 12, weight: .medium, relativeTo: .caption)
                        .foregroundStyle(NCColor.textSecondary)
                    HStack(spacing: 12) {
                        ColorPicker("Filament color", selection: colorBinding, supportsOpacity: false)
                            .labelsHidden()
                        Text(result.colorHex.uppercased())
                            .ncFont(size: 14, relativeTo: .subheadline)
                            .foregroundStyle(.white)
                        Spacer()
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
                }

                VStack(spacing: 12) {
                    labeledField(String(localized: "Brand", comment: "Filament field label"), text: $result.brand)
                    materialPickerField
                    labeledField(String(localized: "Color name", comment: "Filament field label"), text: $result.colorName)
                    labeledField(String(localized: "Net weight (g)", comment: "Filament field label"), text: Binding(
                        get: { String(result.netWeightGrams) },
                        set: { result.netWeightGrams = Int($0) ?? result.netWeightGrams }
                    ))
                }

                Button {
                    addToInventory()
                } label: {
                    Text("Add to Inventory")
                        .ncFont(size: 16, weight: .semibold, relativeTo: .body)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(canSubmitManual ? NCColor.accent : NCColor.accent.opacity(0.35))
                        )
                }
                .disabled(!canSubmitManual)
                .padding(.top, 4)
                .padding(.bottom, 100)
            }
        }
    }

    private var materialPickerField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Material")
                .ncFont(size: 12, weight: .medium, relativeTo: .caption)
                .foregroundStyle(NCColor.textSecondary)
            Menu {
                ForEach(FilamentMaterial.allCases) { m in
                    Button(m.rawValue) { result.material = m }
                }
            } label: {
                HStack {
                    Text(result.material.rawValue)
                        .ncFont(size: 15, relativeTo: .subheadline)
                        .foregroundStyle(.white)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(NCColor.textTertiary)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
            }
        }
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: result.colorHex) },
            set: { result.colorHex = $0.toHexString() }
        )
    }

    private var canSubmitManual: Bool {
        !result.brand.trimmingCharacters(in: .whitespaces).isEmpty
            && !result.colorName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var doneBody: some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                Circle().fill(NCColor.accent.opacity(0.22)).frame(width: 88, height: 88)
                Image(systemName: "checkmark")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(NCColor.accentLight)
            }

            Text("Added to Inventory")
                .ncFont(size: 20, weight: .bold, relativeTo: .title3)

            if let addedSpool {
                HStack(spacing: 10) {
                    addedSpool.swatch.frame(width: 24, height: 24).clipShape(Circle())
                    Text("\(addedSpool.materialWithEffect) · \(addedSpool.colorName)")
                        .ncFont(size: 15, weight: .medium, relativeTo: .subheadline)
                        .foregroundStyle(.white)
                }
                .padding(12)
                .glassCard()
            }

            Spacer()

            VStack(spacing: 10) {
                Button {
                    showAssignPicker = true
                } label: {
                    Text("Assign to a Printer")
                        .ncFont(size: 16, weight: .semibold, relativeTo: .body)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(NCColor.accent))
                }
                Button {
                    reset()
                    selectedTab = .inventory
                } label: {
                    Text("Done")
                        .ncFont(size: 16, weight: .semibold, relativeTo: .body)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.1)))
                }
            }
            .padding(.bottom, 100)
        }
    }

    private func runBarcodeLookup(_ barcode: String, notifyIfMissing: Bool = false) {
        step = .loading
        Task {
            let outcome = await FilamentLookupService.lookup(barcode: barcode)
            result = outcome.result
            step = .review
            if let lookupError = outcome.lookupError {
                lookupErrorMessage = lookupError
            } else if !outcome.found, notifyIfMissing {
                notFoundNotice = true
            }
        }
    }

    private func runTextParse(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        step = .loading
        Task {
            let outcome = await FilamentLookupService.parse(text: trimmed)
            result = outcome.result
            step = .review
        }
    }

    private func addToInventory() {
        let spool = store.addSpool(
            material: pendingTagData?.material(for: result) ?? result.material.rawValue,
            colorName: result.colorName,
            colorHex: result.colorHex,
            brand: result.brand,
            netWeightGrams: result.netWeightGrams,
            tag: pendingTag,
            extras: pendingTagData?.createExtras(for: result) ?? SpoolCreateExtras()
        )
        addedSpool = spool
        pendingTag = nil
        pendingTagData = nil
        step = .done
    }

    private func reset() {
        step = .capture
        // SpoolBuddy mode stays put, ready for the next spool.
        if mode == .spoolBuddy {
            spoolBuddy.clearScan()
        } else {
            mode = .barcode
        }
        addedSpool = nil
        pendingTag = nil
        pendingTagData = nil
        scannerBridge.reset()
    }
}

private struct CornerBracket: View {
    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 10))
            path.addLine(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 10, y: 0))
        }
        .stroke(Color.white.opacity(0.6), lineWidth: 2)
    }
}

private struct ScanLine: View {
    @State private var animate = false

    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(colors: [.clear, Color(hex: "#4f7fe0"), .clear], startPoint: .leading, endPoint: .trailing)
            )
            .frame(height: 2)
            .shadow(color: Color(hex: "#4f7fe0"), radius: 6)
            .offset(y: animate ? 60 : -60)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    animate = true
                }
            }
    }
}
