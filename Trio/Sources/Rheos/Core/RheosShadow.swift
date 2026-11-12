import Foundation

struct RheosShadowStatus: Codable, Equatable {
    var trained: Bool = false
    var source: String = "median"
    var mae: Double? = nil
    var networkMAE: Double? = nil
    var ridgeMAE: Double? = nil
    var baselineMAE: Double? = nil
    var sampleCount: Int = 0
}

struct RheosWeekComparison: Codable, Equatable, Identifiable {
    var id: String
    var start: Date
    var rheosMAE: Double?
    var networkMAE: Double? = nil
    var ridgeMAE: Double? = nil
    var trioMAE: Double?
    var actualInsulin: Double
    var meanShadowBasalFactor: Double
    var nearTarget100: Double?
    /// Always true. These numbers are not a counterfactual replay of the other system.
    var shadowOnly: Bool = true
    var summary: String
}

struct RheosPresetRun: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var started: Date
    var ends: Date
    var prompted: Bool
}

struct RheosMealEstimate: Codable, Equatable {
    var carbs: Double
    var fat: Double
    var protein: Double
    var kcal: Double?
    var note: String
}

enum RheosMealDraftStore {
    static let key = "rheos.mealDraft"

    @discardableResult
    static func save(_ estimate: RheosMealEstimate, defaults: UserDefaults = .standard) -> Bool {
        guard let data = try? JSONEncoder().encode(estimate) else { return false }
        defaults.set(data, forKey: key)
        return true
    }

    static func peek(defaults: UserDefaults = .standard) -> RheosMealEstimate? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(RheosMealEstimate.self, from: data)
    }

    static func take(defaults: UserDefaults = .standard) -> RheosMealEstimate? {
        let value = peek(defaults: defaults)
        defaults.removeObject(forKey: key)
        return value
    }
}

enum RheosRamp {
    /// First Scharf calendar day uses the 10–20% setting. Later days may step faster.
    /// A missing start date is treated as the first day.
    static func maxStep(now: Date, scharfSince: Date?, bounds: RheosBounds, calendar: Calendar) -> Double {
        let limits = bounds.sanitized()
        guard let scharfSince else { return limits.firstDayMaxChange }
        if calendar.isDate(scharfSince, inSameDayAs: now) { return limits.firstDayMaxChange }
        return limits.laterDayMaxChange
    }

    static func preview(learned: RheosHourlyFactors, step: Double, shadow: RheosShadowStatus) -> String {
        let noon = learned.basal.count == 24 ? learned.basal[12] : 1
        let accuracy: String
        if let mae = shadow.mae {
            accuracy = String(format: "Schatten-Prognosefehler %.1f mg/dL", mae)
            + (shadow.trained ? " (Core-ML-Kern, geprüft)." : " (Median, Core ML noch nicht trainiert).")
        } else {
            accuracy = "Noch keine Schatten-Prognosegüte."
        }
        return String(
            format: "Vorschau, noch nicht angewendet. Mittags-Basalfaktor %.2f, erster Schritt höchstens %.0f %%. %@ SMB und UAM bleiben Trios Algorithmus. Kein Bolus.",
            noon,
            step * 100,
            accuracy
        )
    }
}

enum RheosShadowCompare {
    /// Shadow scores against the glucose that actually happened.
    /// Trio's column is distance from the saved target, not a second simulated loop.
    static func week(
        dataset: RheosDataset,
        fit: RheosCoreFit,
        now: Date,
        calendar: Calendar
    ) -> RheosWeekComparison {
        let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        let points = dataset.glucose.filter {
            $0.date >= start && $0.date <= now && $0.mgdl > 0
        }
        let insulin = dataset.insulin.filter { $0.date >= start && $0.date <= now }.reduce(0) { $0 + $1.units }
        let targetErrors = points.map { abs($0.mgdl - 100) }
        let trioMAE = targetErrors.isEmpty ? nil : targetErrors.reduce(0, +) / Double(targetErrors.count)
        let near = points.isEmpty ? nil : Double(points.filter { abs($0.mgdl - 100) <= 15 }.count) / Double(points.count)
        let meanBasal = fit.factors.basal.isEmpty ? 1 : fit.factors.basal.reduce(0, +) / Double(fit.factors.basal.count)
        let id = weekID(start, calendar: calendar)
        let netText = fit.weights.networkMAE.map { String(format: "%.1f", $0) } ?? "—"
        let ridgeText = fit.weights.ridgeMAE.map { String(format: "%.1f", $0) } ?? "—"
        let trioText = trioMAE.map { String(format: "%.1f", $0) } ?? "—"
        let summary = "Schattenvergleich \(id), kein kontrafaktisches Ergebnis. Netz \(netText) mg/dL, Ridge \(ridgeText) mg/dL, gewählt \(fit.chosen). Abstand zum Ziel 100 \(trioText) mg/dL. Tatsächliches Insulin \(String(format: "%.1f", insulin)) E. Mittlerer Schatten-Basalfaktor \(String(format: "%.2f", meanBasal))."
        return RheosWeekComparison(
            id: id,
            start: start,
            rheosMAE: fit.weights.mae,
            networkMAE: fit.weights.networkMAE,
            ridgeMAE: fit.weights.ridgeMAE,
            trioMAE: trioMAE,
            actualInsulin: insulin,
            meanShadowBasalFactor: meanBasal,
            nearTarget100: near,
            shadowOnly: true,
            summary: summary
        )
    }

    static func weekID(_ start: Date, calendar: Calendar) -> String {
        let year = calendar.component(.yearForWeekOfYear, from: start)
        let week = calendar.component(.weekOfYear, from: start)
        return String(format: "%d-W%02d", year, week)
    }
}

enum RheosSignalCatalog {
    static let names = [
        "Ruhepuls",
        "Herzfrequenz",
        "HRV (SDNN)",
        "Atemfrequenz",
        "Sauerstoffsättigung",
        "Handgelenktemperatur",
        "Schritte",
        "Aktivenergie",
        "Workout-Minuten",
        "Schlaf-Stunden"
    ]

    /// Only names Luke has accepted. Anything else stays out of the dosing features.
    static func values(accepted: [String], day: RheosWearableDay?) -> [Double] {
        let allowed = Set(accepted)
        return names.compactMap { name in
            guard allowed.contains(name) else { return nil }
            return scaled(name, day: day)
        }
    }

    static func scaled(_ name: String, day: RheosWearableDay?) -> Double {
        switch name {
        case "Ruhepuls": return ((day?.restingHeartRate ?? 60) - 60) / 10
        case "Herzfrequenz": return ((day?.heartRate ?? 70) - 70) / 20
        case "HRV (SDNN)": return (day?.hrvSDNN ?? 40) / 40
        case "Atemfrequenz": return (day?.respiratoryRate ?? 16) / 8
        case "Sauerstoffsättigung": return ((day?.oxygenSaturation ?? 0.97) - 0.95) / 0.05
        case "Handgelenktemperatur": return day?.wristTemperature ?? 0
        case "Schritte": return (day?.steps ?? 0) / 10_000
        case "Aktivenergie": return (day?.activeEnergy ?? 0) / 500
        case "Workout-Minuten": return (day?.workoutMinutes ?? 0) / 60
        case "Schlaf-Stunden": return (day?.sleepHours ?? 0) / 8
        default: return 0
        }
    }
}

enum RheosPresetPlan {
    static func missingMessage(name: String) -> String {
        "Kein gespeichertes Trio-Preset „\(name)“. Rheos erfindet keine Prozente und kein Ziel."
    }

    static func startedMessage(name: String, kind: String) -> String {
        "\(kind) „\(name)“ gestartet, mit der Dauer aus dem gespeicherten Preset. Kein Bolus und keine neuen Grenzen."
    }

    static func ends(started: Date, minutes: Double?) -> Date {
        let duration = minutes ?? (6 * 60)
        return started.addingTimeInterval(max(duration, 15) * 60)
    }
}

enum RheosMealParser {
    /// All-zero macros are a copied template, not a meal. Callers show a message instead.
    static func estimate(in text: String) -> RheosMealEstimate? {
        let stripped = stripFences(text)
        if let meal = object(in: stripped) { return meal }
        guard let regex = try? NSRegularExpression(pattern: #"\{[^{}]*\}"#),
              let match = regex.firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)),
              let range = Range(match.range, in: stripped) else { return nil }
        return object(in: String(stripped[range]))
    }

    static func stripFences(_ text: String) -> String {
        var copy = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.hasPrefix("```") {
            if let firstNewline = copy.firstIndex(of: "\n") {
                copy = String(copy[copy.index(after: firstNewline)...])
            }
            if let fence = copy.range(of: "```", options: .backwards) {
                copy = String(copy[..<fence.lowerBound])
            }
        }
        return copy.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func object(in text: String) -> RheosMealEstimate? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let carbs = number(json["carbs"]) else { return nil }
        let fat = number(json["fat"]) ?? 0
        let protein = number(json["protein"]) ?? 0
        guard carbs > 0 || fat > 0 || protein > 0 else { return nil }
        return RheosMealEstimate(
            carbs: carbs,
            fat: fat,
            protein: protein,
            kcal: number(json["kcal"]) ?? (4 * carbs + 9 * fat + 4 * protein),
            note: "Schätzung, bitte prüfen"
        )
    }

    static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String {
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
        }
        return nil
    }
}

enum RheosCloudContent {
    /// Chat content may be a string or a list of text parts. Never includes a secret.
    static func text(from content: Any?) -> String? {
        if let value = content as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let parts = content as? [String] {
            let joined = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }
        if let parts = content as? [[String: Any]] {
            return joinedText(parts.map { $0 as Any })
        }
        if let parts = content as? [Any] {
            return joinedText(parts)
        }
        return nil
    }

    private static func joinedText(_ parts: [Any]) -> String? {
        let joined = parts.compactMap { item -> String? in
            if let text = item as? String { return text }
            if let part = item as? [String: Any], let text = part["text"] as? String { return text }
            return nil
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }
}

enum RheosFPUSplit {
    /// Evening meals keep less of the fat/protein effect up front. The numbers
    /// are a proposal for Trio's existing FPU entry, not a bolus command.
    static func proposal(hour: Int, fat: Double, protein: Double) -> String {
        let fpu = (fat + protein) * 0.1
        guard fpu > 0 else {
            return "Wenig Fett und Protein. Trio kann die Kohlenhydrate normal eintragen. Rheos gibt keinen Bolus."
        }
        let nowShare = (hour >= 18 || hour < 5) ? 0.4 : 0.6
        return String(
            format: "Vorschlag mit Bestätigung: etwa %.0f %% der Mahlzeit jetzt, den Rest über Trios FPU-Verteilung (%.1f FPU, Warschau). Abends bleibt mehr hinten. Rheos ändert den Reduced-Bolus-Prozentsatz nicht und gibt keinen Bolus.",
            nowShare * 100,
            fpu
        )
    }
}

enum RheosChatSituation {
    static func advice(question: String, forecast: String) -> (kind: String, text: String)? {
        let asked = question.lowercased()
        if asked.contains("sport") || asked.contains("training") {
            return ("sport", "Sport: \(forecast) Bestätigung startet das gespeicherte Preset Sport, falls es existiert. Kein Bolus.")
        }
        if asked.contains("auftritt") || asked.contains("show") || asked.contains("bühne") {
            return ("showtime", "Auftritt: \(forecast) Bestätigung startet das gespeicherte Preset Showtime, falls es existiert. Kein Bolus.")
        }
        if asked.contains("krank") || asked.contains("fieber") {
            return ("krank", "Krank: \(forecast) Bestätigung startet das gespeicherte Preset Krank, falls es existiert. Keine Ketone-Erinnerung und kein Bolus.")
        }
        return nil
    }

    static func forecastLine(mae: Double?) -> String {
        if let mae {
            return String(format: "Schattenprognose, Fehler zuletzt %.0f mg/dL. ", mae)
        }
        return "Noch keine geprüfte Schattenprognose. "
    }
}
