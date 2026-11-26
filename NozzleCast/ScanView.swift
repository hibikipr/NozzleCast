import SwiftUI
import PhotosUI
import NozzleCastShared

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
    /// As Bambuddy spells it (`BambuddyMaterials.canonical`): any name, not just the form's list.
    var material: String
    var colorName: String
    var colorHex: String
    var brand: String
    var netWeightGrams: Int
    var barcode: String?
    var alsoMatches: String?
    /// The product line, e.g. "Dual Matte" or "Glow" — Bambuddy's spool subtype.
    var subtype: String? = nil
    /// Bambuddy's `effect_type` ("dual-color", "glow", "matte"…), nil for none.
    var effectType: String? = nil
    /// "RRGGBB" per colour of a dual- or tri-colour roll, saved as the spool's extra colours.
    var extraColorHexes: [String] = []
    var nozzleTempMin: Int? = nil
    var nozzleTempMax: Int? = nil
    /// Which code found the filament and what kind it was, shown on the review screen.
    var matchedCode: String? = nil
    var matchedCodeIsSKU = false

    /// The spool fields beyond the form's material, colour, brand and weight.
    var createExtras: SpoolCreateExtras {
        var extras = SpoolCreateExtras()
        extras.subtype = subtype.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) }
        extras.effectType = effectType.flatMap { $0.isEmpty ? nil : $0 }
        extras.extraColors = extraColorHexes.isEmpty ? nil : extraColorHexes.joined(separator: ",")
        extras.nozzleTempMin = nozzleTempMin
        extras.nozzleTempMax = nozzleTempMax
        return extras
    }
}

struct ScanView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// A landscape phone is ~440pt tall, so the capture screen drops its title and trims the
    /// clearance for the floating tab bar to fit.
    private var isShort: Bool { verticalSizeClass == .compact }
    @Binding var selectedTab: RootTab

    @State private var mode: ScanMode = .barcode
    @State private var step: ScanStep = .capture
    @State private var result = ScannedResult(material: "PLA", colorName: "", colorHex: "#808080", brand: "", netWeightGrams: 1000, barcode: nil, alsoMatches: nil)
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
    /// A label photo picked from the library, read the same way as the live camera's.
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var lookupTask: Task<Void, Never>?
    @State private var isAddingSpool = false

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
            .onDisappear {
                isVisible = false
                lookupTask?.cancel()
                lookupTask = nil
            }
            .task(id: listensToSpoolBuddy) {
                guard listensToSpoolBuddy else { return }
                spoolBuddyAvailable = spoolBuddy.start(store: store)
                guard spoolBuddyAvailable else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(3600))
                }
                spoolBuddy.stop()
            }
            .onChange(of: mode) { _, newMode in
                lookupTask?.cancel()
                lookupTask = nil
                scannerBridge.reset()
                if newMode == .manual {
                    result = ScannedResult(material: "PLA", colorName: "", colorHex: "#808080", brand: "", netWeightGrams: 1000, barcode: nil, alsoMatches: nil)
                }
            }
            .onChange(of: scannerBridge.lastBarcode) { _, newBarcode in
                guard mode == .barcode, step == .capture, let newBarcode else { return }
                runBarcodeLookup(newBarcode)
            }
            .onChange(of: pickedPhoto) { _, item in
                guard let item else { return }
                pickedPhoto = nil
                lookupTask?.cancel()
                step = .loading
                lookupTask = Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          !Task.isCancelled,
                          let image = await ImageDownsampling.image(from: data, maxPixelSize: 2048) else {
                        guard !Task.isCancelled else { return }
                        step = .capture
                        lookupErrorMessage = String(localized: "Couldn't open that photo.")
                        return
                    }
                    guard !Task.isCancelled else { return }
                    let reading = await LabelImageReader.read(image)
                    guard !Task.isCancelled else { return }
                    runLabelRead(reading)
                }
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
            if !isShort {
                Text("Scan Filament")
                    .ncFont(size: 24, weight: .bold, relativeTo: .title)
            }

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
                        ?? ScannedResult(material: "PLA", colorName: "", colorHex: "#808080", brand: trayUUID != nil ? "Bambu Lab" : "", netWeightGrams: 1000, barcode: nil, alsoMatches: nil)
                    pendingTag = (tagUID, trayUUID)
                    pendingTagData = tagData
                    step = .review
                }
            )
        } else {
            scannerBody
        }
    }

    @ViewBuilder
    private var scannerBody: some View {
        if isShort {
            // Landscape: the camera takes the height, the caption and buttons sit beside it.
            HStack(spacing: 16) {
                scannerCamera
                VStack(spacing: 12) {
                    scannerCaption
                    Spacer()
                    scannerControls
                }
                .frame(width: 220)
            }
            .padding(.bottom, 72)
        } else {
            VStack(spacing: 20) {
                // Up to 360pt tall, but gives way on screens that can't fit it (the unfolded Duo).
                scannerCamera
                    .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 360)
                scannerCaption
                Spacer()
                scannerControls
                    .padding(.bottom, 100)
            }
        }
    }

    private var scannerCamera: some View {
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
                // Over the live camera too, not just the no-scanner placeholder: it's the cue
                // that the screen is scanning, and VisionKit's own highlight only appears once
                // something is recognized.
                ScanLine()
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
    }

    private var scannerCaption: some View {
        Group {
            if mode == .barcode {
                Text("Point at the box barcode")
            } else {
                Text("Photograph the filament label")
            }
        }
        .ncFont(size: 13, relativeTo: .footnote)
        .foregroundStyle(NCColor.textSecondary)
    }

    private var scannerControls: some View {
        VStack(spacing: 10) {
            if mode == .labelPhoto {
                Button {
                    runLabelRead(FilamentLabelReader.Reading(text: scannerBridge.liveText, barcodes: scannerBridge.liveBarcodes))
                } label: {
                    ZStack {
                        Circle().stroke(Color.white, lineWidth: 3).frame(width: 72, height: 72)
                        Circle().fill(Color.white).frame(width: 58, height: 58)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!labelHasContent)
                .opacity(labelHasContent ? 1 : 0.4)

                PhotosPicker(selection: $pickedPhoto, matching: .images) {
                    Label("Choose Photo", systemImage: "photo.on.rectangle")
                }
                .ncFont(size: 13, weight: .semibold, relativeTo: .footnote)
                .foregroundStyle(NCColor.accentLight)
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
                    FilamentSwatchView(colorHex: result.colorHex, extraColorHexes: result.extraColorHexes, subtype: result.subtype, effectType: result.effectType)
                        .frame(height: 90)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    if let code = result.matchedCode {
                        Text(result.matchedCodeIsSKU ? "Found by SKU \(code)" : "Found by barcode \(code)", comment: "Review screen: which code on the label found the filament")
                            .ncFont(size: 11.5, relativeTo: .caption)
                            .foregroundStyle(NCColor.textTertiary)
                    }
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
                    materialPickerField
                    labeledField(String(localized: "Color name", comment: "Filament field label"), text: $result.colorName)
                    labeledField(String(localized: "Subtype", comment: "Filament field label: the product line, e.g. Dual Matte"), text: Binding(
                        get: { result.subtype ?? "" },
                        set: { result.subtype = $0.isEmpty ? nil : $0 }
                    ))
                    if store.inventoryBackend != .spoolman {
                        effectField
                    }
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
                    HStack(spacing: 8) {
                        if isAddingSpool {
                            ProgressView()
                                .tint(NCColor.onAccent)
                        }
                        Text("Add to Inventory")
                    }
                    .ncFont(size: 16, weight: .semibold, relativeTo: .body)
                    .foregroundStyle(NCColor.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(NCColor.accent))
                }
                .disabled(isAddingSpool)
                .padding(.top, 4)
                .padding(.bottom, 100)
            }
        }
    }

    /// Bambuddy's Effect, read from the label or the product name; the swatch above follows it.
    private var effectField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Effect", comment: "Filament field label: Bambuddy's finish/effect")
                .ncFont(size: 12, weight: .medium, relativeTo: .caption)
                .foregroundStyle(NCColor.textSecondary)
            Picker("Effect", selection: Binding(
                get: { result.effectType ?? "" },
                set: { result.effectType = $0.isEmpty ? nil : $0 }
            )) {
                ForEach(SpoolEffectOptions.all, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .pickerStyle(.menu)
            .tint(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
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
                    HStack(spacing: 8) {
                        if isAddingSpool {
                            ProgressView()
                                .tint(canSubmitManual ? NCColor.onAccent : .white.opacity(0.6))
                        }
                        Text("Add to Inventory")
                    }
                    .ncFont(size: 16, weight: .semibold, relativeTo: .body)
                    .foregroundStyle(canSubmitManual ? NCColor.onAccent : .white.opacity(0.6))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(canSubmitManual ? NCColor.accent : NCColor.accent.opacity(0.35))
                    )
                }
                .disabled(!canSubmitManual || isAddingSpool)
                .padding(.top, 4)
                .padding(.bottom, 100)
            }
        }
    }

    /// Free text, as in Bambuddy, with its material list one tap away. Anything typed is saved as
    /// typed: Bambuddy accepts any material name.
    private var materialPickerField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Material")
                .ncFont(size: 12, weight: .medium, relativeTo: .caption)
                .foregroundStyle(NCColor.textSecondary)
            HStack(spacing: 8) {
                TextField("", text: $result.material)
                    .ncFont(size: 15, relativeTo: .subheadline)
                    .foregroundStyle(.white)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                Menu {
                    ForEach(BambuddyMaterials.common, id: \.self) { m in
                        Button(m) { result.material = m }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(NCColor.textTertiary)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
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
                    Text("\(addedSpool.materialWithSubtype) · \(addedSpool.colorName)")
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
                        .foregroundStyle(NCColor.onAccent)
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
        lookupTask?.cancel()
        step = .loading
        lookupTask = Task {
            let outcome = await FilamentLookupService.lookup(barcode: barcode)
            guard !Task.isCancelled else { return }
            result = outcome.result
            step = .review
            if let lookupError = outcome.lookupError {
                lookupErrorMessage = lookupError
            } else if !outcome.found, notifyIfMissing {
                notFoundNotice = true
            }
        }
    }

    private var labelHasContent: Bool {
        !scannerBridge.liveText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !scannerBridge.liveBarcodes.isEmpty
    }

    /// Looks a label up — its barcodes, then its SKU — and fills the form from the first hit or
    /// from what the label says.
    private func runLabelRead(_ reading: FilamentLabelReader.Reading) {
        lookupTask?.cancel()
        guard !reading.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !reading.barcodes.isEmpty else {
            step = .capture
            lookupErrorMessage = String(localized: "No text or barcode found in that photo.")
            return
        }
        step = .loading
        lookupTask = Task {
            let outcome = await FilamentLookupService.analyze(reading)
            guard !Task.isCancelled else { return }
            result = outcome.result
            step = .review
            if let lookupError = outcome.lookupError { lookupErrorMessage = lookupError }
        }
    }

    private func addToInventory() {
        guard !isAddingSpool else { return }
        isAddingSpool = true
        let material = BambuddyMaterials.canonical(pendingTagData?.material(for: result) ?? result.material)
        let colorName = result.colorName
        let colorHex = result.colorHex
        let brand = result.brand
        let netWeightGrams = result.netWeightGrams
        let tag = pendingTag
        let extras = pendingTagData?.createExtras(for: result) ?? result.createExtras
        Task {
            defer { isAddingSpool = false }
            guard let spool = await store.addSpool(
                material: material,
                colorName: colorName,
                colorHex: colorHex,
                brand: brand,
                netWeightGrams: netWeightGrams,
                tag: tag,
                extras: extras
            ) else { return }
            addedSpool = spool
            pendingTag = nil
            pendingTagData = nil
            step = .done
        }
    }

    private func reset() {
        lookupTask?.cancel()
        lookupTask = nil
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
                LinearGradient(colors: [.clear, NCColor.accent, .clear], startPoint: .leading, endPoint: .trailing)
            )
            .frame(height: 2)
            .shadow(color: NCColor.accent, radius: 6)
            .offset(y: animate ? 60 : -60)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    animate = true
                }
            }
    }
}
