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
                nozzle: TemperatureReading(current: 245, target: 245),
                bed: TemperatureReading(current: 60, target: 60),
                chamber: TemperatureReading(current: 42, target: nil),
                lightOn: true,
                amsUnits: [amsUnit([sunsetOrange, onyxBlack, cobaltBlue, nil])]
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
}
