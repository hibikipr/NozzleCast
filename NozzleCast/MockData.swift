import Foundation

enum MockData {
    static let workshopX1C = "mock-workshop-x1c"
    static let garageA1 = "mock-garage-a1"
    static let officeP1S = "mock-office-p1s"

    static let sunsetOrange = "mock-spool-sunset-orange"
    static let onyxBlack = "mock-spool-onyx-black"
    static let cobaltBlue = "mock-spool-cobalt-blue"
    static let amberGold = "mock-spool-amber-gold"
    static let forestGreen = "mock-spool-forest-green"
    static let pureWhite = "mock-spool-pure-white"
    static let magentaPink = "mock-spool-magenta-pink"
    static let charcoalGrey = "mock-spool-charcoal-grey"
    static let clearPETG = "mock-spool-clear-petg"
    static let rainbowSilk = "mock-spool-rainbow-silk"
    static let sparkleBlack = "mock-spool-sparkle-black"
    static let panchromaYellowGlow = "mock-spool-panchroma-yellow-glow"
    static let panchromaYellowMatte = "mock-spool-panchroma-yellow-matte"

    static func makeSpools() -> [Spool] {
        [
            Spool(id: sunsetOrange, material: "PLA", colorName: "Sunset Orange", colorHex: "#E8622C", brand: "Bambu Lab", remainingPercent: 72, netWeightGrams: 1000, location: .ams(printerID: workshopX1C, amsIndex: 0, trayIndex: 0)),
            Spool(id: onyxBlack, material: "PLA", colorName: "Onyx Black", colorHex: "#1A1A1A", brand: "Bambu Lab", remainingPercent: 45, netWeightGrams: 1000, location: .ams(printerID: workshopX1C, amsIndex: 0, trayIndex: 1)),
            Spool(id: cobaltBlue, material: "PETG", colorName: "Cobalt Blue", colorHex: "#2A5FCC", brand: "Polymaker", remainingPercent: 88, netWeightGrams: 1000, location: .ams(printerID: workshopX1C, amsIndex: 0, trayIndex: 2)),
            Spool(id: amberGold, material: "PLA", colorName: "Amber Gold", colorHex: "#D9A426", brand: "eSun", remainingPercent: 30, netWeightGrams: 1000, location: .ams(printerID: garageA1, amsIndex: 0, trayIndex: 0)),
            Spool(id: forestGreen, material: "PLA", colorName: "Forest Green", colorHex: "#2F6B3A", brand: "Bambu Lab", remainingPercent: 100, netWeightGrams: 1000, location: .storage(name: nil)),
            Spool(id: pureWhite, material: "ABS", colorName: "Pure White", colorHex: "#F2F2F2", brand: "Bambu Lab", remainingPercent: 60, netWeightGrams: 1000, location: .ams(printerID: officeP1S, amsIndex: 0, trayIndex: 2)),
            Spool(id: magentaPink, material: "TPU", colorName: "Magenta Pink", colorHex: "#C22A7A", brand: "Overture", remainingPercent: 55, netWeightGrams: 500, location: .storage(name: nil)),
            Spool(id: charcoalGrey, material: "PETG", colorName: "Charcoal Grey", colorHex: "#4A4A4A", brand: "Polymaker", remainingPercent: 20, netWeightGrams: 1000, location: .storage(name: nil)),
            Spool(id: clearPETG, material: "PETG", colorName: "Clear", colorHex: "#D9E4E8", colorAlpha: 0.18, brand: "Bambu Lab", remainingPercent: 80, netWeightGrams: 1000, location: .storage(name: nil), effectType: "translucent"),
            Spool(id: rainbowSilk, material: "PLA", colorName: "Silk Multicolor", colorHex: "#E8622C", extraColorHexes: ["#D9A426", "#2A5FCC", "#C22A7A"], brand: "eSun", remainingPercent: 65, netWeightGrams: 1000, location: .storage(name: nil), subtype: "Multicolor", effectType: "multicolor"),
            Spool(id: sparkleBlack, material: "PLA", colorName: "Galaxy Black", colorHex: "#141414", brand: "Polymaker", remainingPercent: 40, netWeightGrams: 1000, location: .storage(name: nil), effectType: "sparkle"),
            Spool(id: panchromaYellowGlow, material: "PLA", colorName: "Yellow", colorHex: "#F2C230", brand: "Panchroma", remainingPercent: 90, netWeightGrams: 1000, location: .storage(name: nil), effectType: "glow"),
            Spool(id: panchromaYellowMatte, material: "PLA", colorName: "Yellow", colorHex: "#F2C230", brand: "Panchroma", remainingPercent: 75, netWeightGrams: 1000, location: .storage(name: nil), effectType: "matte"),
        ]
    }

    private static func amsUnit(_ trayIDs: [String?]) -> AMSUnit {
        AMSUnit(index: 0, trays: trayIDs.enumerated().map { AMSTray(amsIndex: 0, trayIndex: $0.offset, spoolID: $0.element) })
    }

    static func makePrinters() -> [Printer] {
        [
            Printer(
                id: workshopX1C,
                name: "Workshop X1C",
                model: "X1 Carbon",
                imageAssetName: "PrinterX1C",
                state: .printing,
                jobFileName: "Articulated_Dragon_v2.3.mf",
                progress: 0.64,
                etaMinutesRemaining: 72,
                currentLayer: 140,
                totalLayers: 226,
                nozzle: TemperatureReading(current: 245, target: 245),
                bed: TemperatureReading(current: 60, target: 60),
                chamber: TemperatureReading(current: 42, target: nil),
                lightOn: true,
                amsUnits: [amsUnit([sunsetOrange, onyxBlack, cobaltBlue, nil])],
                fanSpeeds: FanSpeeds(partCooling: 100, auxiliary: 40, chamber: 20),
                activeTrayID: 0
            ),
            Printer(
                id: garageA1,
                name: "Garage A1",
                model: "A1",
                imageAssetName: "PrinterA1",
                state: .idle,
                jobFileName: nil,
                progress: nil,
                etaMinutesRemaining: nil,
                nozzle: TemperatureReading(current: 25, target: nil),
                bed: TemperatureReading(current: 24, target: nil),
                chamber: nil,
                lightOn: false,
                amsUnits: [amsUnit([amberGold, nil, nil, nil])]
            ),
            Printer(
                id: officeP1S,
                name: "Office P1S",
                model: "P1S",
                imageAssetName: "PrinterP1S",
                state: .paused,
                jobFileName: "Vase_Mode_Twist.mf",
                progress: 0.31,
                etaMinutesRemaining: 145,
                nozzle: TemperatureReading(current: 220, target: 230),
                bed: TemperatureReading(current: 55, target: 55),
                chamber: TemperatureReading(current: 38, target: nil),
                lightOn: true,
                amsUnits: [amsUnit([nil, nil, pureWhite, nil])]
            ),
        ]
    }

    static func makeQueue() -> [QueuedPrint] {
        [
            QueuedPrint(id: "mock-q-1", bambuddyID: 1, name: "Cable Clips x12", printerID: officeP1S, destination: "Office P1S", status: .pending, position: 1, isStaged: false, waitingReason: "Waiting for the printer to finish", estimatedDuration: 2 * 3600 + 40 * 60, filamentGrams: 38, filamentType: "PETG", filamentColorHex: "#1F2A44"),
            QueuedPrint(id: "mock-q-2", bambuddyID: 2, name: "Headphone Stand", printerID: garageA1, destination: "Garage A1", status: .pending, position: 2, isStaged: true, estimatedDuration: 5 * 3600 + 10 * 60, filamentGrams: 142, filamentType: "PLA", filamentColorHex: "#E2E2E2"),
            QueuedPrint(id: "mock-q-3", bambuddyID: 3, name: "Planter Insert", destination: "Any X1C", status: .pending, position: 3, isStaged: false, estimatedDuration: 3 * 3600, filamentGrams: 96, filamentType: "PLA", filamentColorHex: "#2E7D32"),
        ]
    }

    static func makePrintHistory() -> [PrintRecord] {
        let now = Date()
        func record(_ n: Int, _ name: String, _ printer: String, _ printerName: String, hoursAgo: Double, minutes: Double, grams: Double, type: String, color: String, outcome: PrintRecord.Outcome = .completed, archive: Int, verdict: PrintVerdict? = nil, failure: String? = nil) -> PrintRecord {
            PrintRecord(id: "mock-log-\(n)", logID: n, archiveID: archive, name: name, printerID: printer, printerName: printerName, outcome: outcome, startedAt: now.addingTimeInterval(-(hoursAgo * 3600 + minutes * 60)), finishedAt: now.addingTimeInterval(-hoursAgo * 3600), duration: minutes * 60, filamentGrams: grams, filamentType: type, filamentColorHex: color, cost: grams * 0.025, failureReason: failure, verdict: verdict, acceptsVerdict: false)
        }
        return [
            record(6, "Phone Stand", officeP1S, "Office P1S", hoursAgo: 1.5, minutes: 95, grams: 41, type: "PLA", color: "#FF6B35", archive: 16),
            record(5, "Gridfinity Bin 2x3", workshopX1C, "Workshop X1C", hoursAgo: 6, minutes: 140, grams: 64, type: "PLA", color: "#1E1E1E", archive: 15, verdict: .good),
            record(4, "Vase Mode Lamp Shade", garageA1, "Garage A1", hoursAgo: 20, minutes: 210, grams: 88, type: "PETG", color: "#F5F5F5", outcome: .failed, archive: 14, failure: "Spaghetti detected"),
            record(3, "Gridfinity Bin 2x3", workshopX1C, "Workshop X1C", hoursAgo: 30, minutes: 138, grams: 64, type: "PLA", color: "#1E1E1E", archive: 15, verdict: .reject),
            record(2, "Cable Clips x12", officeP1S, "Office P1S", hoursAgo: 52, minutes: 160, grams: 38, type: "PETG", color: "#1F2A44", archive: 12, verdict: .good),
            record(1, "Calibration Cube", garageA1, "Garage A1", hoursAgo: 70, minutes: 22, grams: 9, type: "PLA", color: "#4F7FE0", outcome: .cancelled, archive: 11),
        ]
    }
}
