import Foundation

enum RheosBiologicalSex: String, Codable, Equatable, CaseIterable {
    case female
    case male
    case other
    case unspecified

    var title: String {
        switch self {
        case .female: return "Weiblich"
        case .male: return "Männlich"
        case .other: return "Divers"
        case .unspecified: return "Keine Angabe"
        }
    }
}

struct RheosBodySnapshot: Codable, Equatable, Identifiable {
    var id: String
    var date: Date
    var inputs: RheosBodyInputs
    var source: String
}

enum RheosBodyPrior {
    /// Hours with little glucose shrink toward 1. Body data makes that pull
    /// a bit stronger. The center stays 1, so body data is not an insulin number.
    static let plain = 4.0
    static let withBody = 6.0

    static func strength(for inputs: RheosBodyInputs) -> Double {
        inputs.weightKg == nil ? plain : withBody
    }
}

enum RheosBodyRecord {
    static func markingManual(_ inputs: RheosBodyInputs) -> RheosBodyInputs {
        var copy = inputs
        copy.manualFields = presentFields(copy)
        return copy
    }

    /// Health fills only fields the user has not typed.
    static func merging(current: RheosBodyInputs, health: RheosBodyInputs) -> RheosBodyInputs {
        var result = current
        let locked = Set(current.manualFields)
        if !locked.contains("ageYears"), let value = health.ageYears { result.ageYears = value }
        if !locked.contains("weightKg"), let value = health.weightKg { result.weightKg = value }
        if !locked.contains("heightCm"), let value = health.heightCm { result.heightCm = value }
        if !locked.contains("sex"), let value = health.sex, value != .unspecified { result.sex = value }
        if !locked.contains("bodyFatPercent"), let value = health.bodyFatPercent { result.bodyFatPercent = value }
        if let value = health.leanMassKg { result.leanMassKg = value }
        if !locked.contains("muscleMassKg"), let value = health.leanMassKg {
            result.muscleMassKg = value
            result.muscleComesFromLeanMass = true
        }
        return result
    }

    static func appending(
        _ history: [RheosBodySnapshot],
        inputs: RheosBodyInputs,
        source: String,
        now: Date
    ) -> [RheosBodySnapshot] {
        if let last = history.last, sameMeasurements(last.inputs, inputs), last.source == source {
            return history
        }
        var copy = history
        copy.append(RheosBodySnapshot(id: UUID().uuidString, date: now, inputs: inputs, source: source))
        return copy
    }

    static func sameMeasurements(_ lhs: RheosBodyInputs, _ rhs: RheosBodyInputs) -> Bool {
        lhs.ageYears == rhs.ageYears
            && lhs.weightKg == rhs.weightKg
            && lhs.heightCm == rhs.heightCm
            && lhs.sex == rhs.sex
            && lhs.bodyFatPercent == rhs.bodyFatPercent
            && lhs.muscleMassKg == rhs.muscleMassKg
            && lhs.leanMassKg == rhs.leanMassKg
            && lhs.muscleComesFromLeanMass == rhs.muscleComesFromLeanMass
    }

    static func presentFields(_ inputs: RheosBodyInputs) -> [String] {
        var fields: [String] = []
        if inputs.ageYears != nil { fields.append("ageYears") }
        if inputs.weightKg != nil { fields.append("weightKg") }
        if inputs.heightCm != nil { fields.append("heightCm") }
        if let sex = inputs.sex, sex != .unspecified { fields.append("sex") }
        if inputs.bodyFatPercent != nil { fields.append("bodyFatPercent") }
        if inputs.muscleMassKg != nil { fields.append("muscleMassKg") }
        return fields
    }
}

enum RheosBodyDraftMath {
    /// A textbook sketch for a conversation with the diabetes team.
    /// 0.4 U/kg in adulthood, 0.3 under 18, 0.2 from 65. Half of that as basal.
    /// ISF uses 1800/TDD and the carb ratio uses 500/TDD, both in mg/dL units.
    static func unitsPerKilogram(ageYears: Double?) -> Double {
        guard let ageYears, ageYears.isFinite else { return 0.4 }
        if ageYears < 18 { return 0.3 }
        if ageYears >= 65 { return 0.2 }
        return 0.4
    }

    static func draft(_ inputs: RheosBodyInputs) -> RheosBodyDraft {
        let noted = description(inputs)
        guard let weight = inputs.weightKg, weight > 0, weight < 400 else {
            return RheosBodyDraft(
                totalDailyDose: nil,
                basalPerHour: nil,
                isfMgdlPerUnit: nil,
                carbGramsPerUnit: nil,
                summary: (noted.isEmpty ? "Keine Körperdaten eingetragen. " : "Notiert: \(noted). ")
                    + "Ohne Gewicht gibt es keinen Entwurf. Nichts davon wird als Insulin übernommen."
            )
        }
        let perKg = unitsPerKilogram(ageYears: inputs.ageYears)
        let total = weight * perKg
        let basal = total * 0.5 / 24
        let isf = 1800 / total
        let carbs = 500 / total
        let ageNote = inputs.ageYears == nil ? " Alter fehlt, deshalb 0,40 Einheiten pro kg." : ""
        let muscleNote = inputs.muscleComesFromLeanMass
            ? " Die Muskelzahl ist die fettfreie Masse aus Health, nicht reine Muskelmasse."
            : ""
        return RheosBodyDraft(
            totalDailyDose: total,
            basalPerHour: basal,
            isfMgdlPerUnit: isf,
            carbGramsPerUnit: carbs,
            summary: "Entwurf zur Besprechung mit dem Diabetesteam, nicht angewendet. \(noted). Rechenhilfe: \(format(perKg)) Einheiten pro kg, Tagesdosis \(format(total)) E, Basal \(format(basal)) E/h, ISF \(format(isf)) mg/dL pro E, KH-Faktor \(format(carbs)) g pro E.\(ageNote)\(muscleNote) Rheos schreibt diese Zahlen nicht ins Profil und gibt kein Insulin. Im Lernmodell ziehen Körperdaten den Stundenfaktor nur etwas stärker gegen 1."
        )
    }

    private static func description(_ inputs: RheosBodyInputs) -> String {
        [
            inputs.ageYears.map { "Alter \(format($0)) Jahre" },
            inputs.sex.map { "Geschlecht \($0.title)" },
            inputs.weightKg.map { "Gewicht \(format($0)) kg" },
            inputs.heightCm.map { "Größe \(format($0)) cm" },
            inputs.bodyFatPercent.map { "Körperfett \(format($0)) %" },
            inputs.muscleMassKg.map { "Muskel/fettfreie Masse \(format($0)) kg" }
        ].compactMap { $0 }.joined(separator: ", ")
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
