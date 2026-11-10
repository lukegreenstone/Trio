import Foundation

enum RheosAnalysis {
    static func stability(glucose: [RheosGlucosePoint]) -> RheosStability {
        let values = glucose.map(\.mgdl).filter { $0.isFinite && $0 > 0 }
        guard !values.isEmpty else {
            return RheosStability(
                sampleCount: 0,
                timeInTightRange: nil,
                timeInRange: nil,
                coefficientOfVariationPercent: nil,
                summary: "Noch keine Glukose im Rheos-Protokoll."
            )
        }
        let tight = Double(values.filter { (70 ... 140).contains($0) }.count) / Double(values.count)
        let range = Double(values.filter { (70 ... 180).contains($0) }.count) / Double(values.count)
        let cv = RheosStats.coefficientOfVariationPercent(values)
        let cvText = cv.map { String(format: "%.0f %%", $0) } ?? "–"
        return RheosStability(
            sampleCount: values.count,
            timeInTightRange: tight,
            timeInRange: range,
            coefficientOfVariationPercent: cv,
            summary: "Zeit 70–140 mg/dL \(percent(tight)), Zeit 70–180 mg/dL \(percent(range)), Variationskoeffizient \(cvText). Das ist eine Beschreibung, kein Dosierbefehl."
        )
    }

    static func hourlyGlucose(_ glucose: [RheosGlucosePoint], calendar: Calendar) -> [RheosHourlyGlucose] {
        var buckets: [Int: [Double]] = [:]
        for point in glucose where point.mgdl.isFinite && point.mgdl > 0 {
            let hour = calendar.component(.hour, from: point.date)
            buckets[hour, default: []].append(point.mgdl)
        }
        return (0 ..< 24).compactMap { hour in
            guard let values = buckets[hour], let median = RheosStats.median(values) else { return nil }
            return RheosHourlyGlucose(hour: hour, medianMgdl: median, count: values.count)
        }
    }

    static func dawn(dataset: RheosDataset, calendar: Calendar) -> RheosDawnObservation {
        let lateMeals = dataset.meals.filter { meal in
            calendar.component(.hour, from: meal.date) >= 20 && (meal.fat > 0 || meal.protein > 0)
        }
        var rises: [Double] = []
        for meal in lateMeals {
            let start = calendar.startOfDay(for: meal.date)
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: start),
                  let atOne = calendar.date(bySettingHour: 1, minute: 0, second: 0, of: nextDay),
                  let atFour = calendar.date(bySettingHour: 4, minute: 0, second: 0, of: nextDay),
                  let baseline = RheosStats.nearest(dataset.glucose, to: atOne, within: 45 * 60),
                  let four = RheosStats.nearest(dataset.glucose, to: atFour, within: 45 * 60)
            else { continue }
            rises.append(four - baseline)
        }
        let median = RheosStats.median(rises)
        let high = rises.filter { $0 > 20 }.count
        let summary: String
        if lateMeals.isEmpty {
            summary = "Keine späte Mahlzeit mit Fett oder Protein nach 20 Uhr im Protokoll."
        } else if rises.isEmpty {
            summary = "\(lateMeals.count) späte Mahlzeiten, aber noch kein vergleichbarer Wert um 1 Uhr und um 4 Uhr."
        } else {
            summary = "\(lateMeals.count) späte Mahlzeiten. Bei \(rises.count) Nächten liegt der Median des Anstiegs von etwa 1 Uhr auf etwa 4 Uhr bei \(formatted(median)) mg/dL. \(high) davon über 20 mg/dL. Nur Beschreibung."
        }
        return RheosDawnObservation(
            lateMealCount: lateMeals.count,
            nightsCompared: rises.count,
            nightsWithRiseOver20: high,
            medianRiseMgdl: median,
            summary: summary
        )
    }

    static func mealOutcomes(dataset: RheosDataset, calendar: Calendar) -> [RheosMealOutcome] {
        dataset.meals.map { meal in
            let plus2 = meal.date.addingTimeInterval(2 * 3600)
            let plus4 = meal.date.addingTimeInterval(4 * 3600)
            let before = RheosStats.nearest(dataset.glucose, to: meal.date, within: 45 * 60)
            let at2 = RheosStats.nearest(dataset.glucose, to: plus2, within: 45 * 60)
            let at4 = RheosStats.nearest(dataset.glucose, to: plus4, within: 45 * 60)
            var riseAt4: Double?
            if calendar.component(.hour, from: meal.date) >= 20 {
                let start = calendar.startOfDay(for: meal.date)
                if let nextDay = calendar.date(byAdding: .day, value: 1, to: start),
                   let atFour = calendar.date(bySettingHour: 4, minute: 0, second: 0, of: nextDay),
                   let four = RheosStats.nearest(dataset.glucose, to: atFour, within: 45 * 60),
                   let baseline = before {
                    riseAt4 = four - baseline
                }
            }
            return RheosMealOutcome(
                id: meal.id,
                date: meal.date,
                carbs: meal.carbs,
                fat: meal.fat,
                protein: meal.protein,
                note: meal.note,
                presetKey: presetKey(for: meal, calendar: calendar),
                delta2h: difference(at2, minus: before),
                delta4h: difference(at4, minus: before),
                riseAt4am: riseAt4,
                acknowledged: meal.acknowledged
            )
        }
    }

    static func presetKey(for meal: RheosMealEvent, calendar: Calendar) -> String {
        let trimmed = meal.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") {
            let tag = trimmed.dropFirst().split(separator: " ").first.map(String.init) ?? ""
            if !tag.isEmpty { return tag }
        }
        let hour = calendar.component(.hour, from: meal.date)
        if hour >= 20, meal.fat + meal.protein > 0 { return "spät und fettig" }
        if hour < 10 { return "morgens" }
        if hour < 16 { return "mittags" }
        return "abends"
    }

    static func contextProposals(dataset: RheosDataset, now: Date, calendar: Calendar) -> [RheosContextProposal] {
        var proposals: [RheosContextProposal] = []
        if let workout = dataset.workouts.first(where: { isRecentWorkout($0, now: now) }) {
            proposals.append(
                RheosContextProposal(
                    mode: .sport,
                    reason: "Training „\(workout.activity)“ endete innerhalb von 24 Stunden (\(formatted(workout.durationMinutes)) min). Vorschlag: vorhandenes Preset „Sport“ prüfen. Rheos setzt keinen Prozentsatz und keinen Bolus.",
                    presetName: RheosContextMode.sport.presetName
                )
            )
        }
        if let illness = illnessProposal(dataset: dataset, now: now, calendar: calendar) {
            proposals.append(illness)
        }
        let hour = calendar.component(.hour, from: now)
        if (10 ... 18).contains(hour), !hasRecentCarbs(dataset: dataset, now: now, hours: 16) {
            proposals.append(
                RheosContextProposal(
                    mode: .fasten,
                    reason: "Seit 16 Stunden keine Kohlenhydrate, und es ist Tag. Vorschlag nur, wenn das Preset „Fasten“ mit dem Team angelegt ist.",
                    presetName: RheosContextMode.fasten.presetName
                )
            )
        }
        let recentText = recentNotes(dataset: dataset, now: now, hours: 48).lowercased()
        if recentText.contains("urlaub") || recentText.contains("reise") {
            proposals.append(
                RheosContextProposal(
                    mode: .urlaub,
                    reason: "Eine Notiz enthält Urlaub oder Reise. Preset „Urlaub“ nur nach deiner Bestätigung.",
                    presetName: RheosContextMode.urlaub.presetName
                )
            )
        }
        if recentText.contains("showtime") || recentText.contains("auftritt") || recentText.contains("bühne") {
            proposals.append(
                RheosContextProposal(
                    mode: .showtime,
                    reason: "Eine Notiz enthält Showtime, Auftritt oder Bühne. Preset „Showtime“ nur nach deiner Bestätigung.",
                    presetName: RheosContextMode.showtime.presetName
                )
            )
        }
        return proposals
    }

    static func signalRelevance(dataset: RheosDataset, calendar: Calendar) -> [RheosSignalRelevance] {
        let signals: [(String, (RheosWearableDay) -> Double?)] = [
            ("Ruhepuls", { $0.restingHeartRate }),
            ("Herzfrequenz", { $0.heartRate }),
            ("HRV (SDNN)", { $0.hrvSDNN }),
            ("Atemfrequenz", { $0.respiratoryRate }),
            ("Sauerstoffsättigung", { $0.oxygenSaturation }),
            ("Handgelenktemperatur", { $0.wristTemperature }),
            ("Schritte", { $0.steps }),
            ("Aktivenergie", { $0.activeEnergy }),
            ("Workout-Minuten", { $0.workoutMinutes }),
            ("Schlaf-Stunden", { $0.sleepHours })
        ]
        var glucoseByDay: [Date: [Double]] = [:]
        for point in dataset.glucose where point.mgdl.isFinite && point.mgdl > 0 {
            glucoseByDay[calendar.startOfDay(for: point.date), default: []].append(point.mgdl)
        }
        return signals.map { name, extract in
            relevance(name: name, extract: extract, days: dataset.wearableDays, glucoseByDay: glucoseByDay, calendar: calendar)
        }
    }

    static func bodyDraft(_ inputs: RheosBodyInputs) -> RheosBodyDraft {
        let noted = [
            inputs.ageYears.map { "Alter \(formatted($0)) Jahre" },
            inputs.weightKg.map { "Gewicht \(formatted($0)) kg" },
            inputs.heightCm.map { "Größe \(formatted($0)) cm" }
        ].compactMap { $0 }
        let prefix = noted.isEmpty ? "Keine Körperdaten eingetragen. " : "Notiert: \(noted.joined(separator: ", ")). "
        return RheosBodyDraft(
            suggestedDailyInsulin: nil,
            summary: prefix + "Kein Startprofil. Die Formel für Basal, ISF und KH-Faktor legt das Team fest. Rheos rechnet daraus keine Insulinzahl und schreibt kein Profil."
        )
    }

    private static func relevance(
        name: String,
        extract: (RheosWearableDay) -> Double?,
        days: [RheosWearableDay],
        glucoseByDay: [Date: [Double]],
        calendar: Calendar
    ) -> RheosSignalRelevance {
        let paired: [(Date, Double, Double)] = days.compactMap { day in
            guard let signal = extract(day), signal.isFinite,
                  let values = glucoseByDay[calendar.startOfDay(for: day.day)],
                  let glucose = RheosStats.mean(values) else { return nil }
            return (calendar.startOfDay(for: day.day), signal, glucose)
        }.sorted { $0.0 < $1.0 }
        guard paired.count >= 10 else {
            return RheosSignalRelevance(
                signal: name,
                proposed: false,
                reason: "Zu wenige gemeinsame Tage (\(paired.count)). Signal wird nicht vorgeschlagen.",
                correlation: nil,
                baselineMAE: nil,
                modelMAE: nil
            )
        }
        let testCount = max(3, Int((Double(paired.count) * 0.3).rounded()))
        let train = paired.dropLast(testCount)
        let test = paired.suffix(testCount)
        guard train.count >= 7, test.count >= 3 else {
            return RheosSignalRelevance(
                signal: name,
                proposed: false,
                reason: "Zu wenig getrennte Tage für eine ehrliche Prüfung.",
                correlation: nil,
                baselineMAE: nil,
                modelMAE: nil
            )
        }
        let correlation = RheosStats.pearson(paired.map(\.1), paired.map(\.2))
        let trainMean = RheosStats.mean(train.map(\.2)) ?? 0
        let fit = RheosStats.linearFit(x: train.map(\.1), y: train.map(\.2))
        let modelErrors = test.map { sample -> Double in
            let predicted = (fit?.intercept ?? trainMean) + (fit?.slope ?? 0) * sample.1
            return abs(sample.2 - predicted)
        }
        let baselineErrors = test.map { abs($0.2 - trainMean) }
        let modelMAE = RheosStats.mean(modelErrors) ?? 0
        let baselineMAE = RheosStats.mean(baselineErrors) ?? 0
        let strong = (correlation.map { abs($0) >= 0.3 } ?? false)
        let better = baselineMAE > 0 && modelMAE <= baselineMAE * 0.95
        let proposed = strong && better
        let reason = proposed
            ? "Das Signal verbessert die Glukose-Schätzung auf den letzten Tagen. Nur ein Vorschlag, es im Lernmodell zu behalten. Keine Dosierung."
            : "Das Signal erklärt die Glukose hier nicht deutlich besser als der Tagesmittelwert. Es wird nicht vorgeschlagen."
        return RheosSignalRelevance(
            signal: name,
            proposed: proposed,
            reason: reason,
            correlation: correlation,
            baselineMAE: baselineMAE,
            modelMAE: modelMAE
        )
    }

    private static func illnessProposal(dataset: RheosDataset, now: Date, calendar: Calendar) -> RheosContextProposal? {
        let today = calendar.startOfDay(for: now)
        guard let current = dataset.wearableDays.first(where: { calendar.startOfDay(for: $0.day) == today })?.restingHeartRate else {
            return nil
        }
        let history = dataset.wearableDays.compactMap { day -> Double? in
            guard calendar.startOfDay(for: day.day) < today else { return nil }
            return day.restingHeartRate
        }
        guard history.count >= 5, let baseline = RheosStats.median(history), current > baseline + 10 else { return nil }
        return RheosContextProposal(
            mode: .krank,
            reason: "Ruhepuls heute \(formatted(current)) gegenüber deiner Basis \(formatted(baseline)). Das ist ein grobes Merkmal, kein Stresswert. Preset „Krank“ nur nach Bestätigung.",
            presetName: RheosContextMode.krank.presetName
        )
    }

    private static func isRecentWorkout(_ workout: RheosWorkout, now: Date) -> Bool {
        guard workout.durationMinutes >= 20 else { return false }
        let end = workout.start.addingTimeInterval(workout.durationMinutes * 60)
        return now >= workout.start && now.timeIntervalSince(end) <= 24 * 3600
    }

    private static func hasRecentCarbs(dataset: RheosDataset, now: Date, hours: Double) -> Bool {
        dataset.meals.contains { meal in
            meal.carbs > 0 && now.timeIntervalSince(meal.date) >= 0 && now.timeIntervalSince(meal.date) <= hours * 3600
        }
    }

    private static func recentNotes(dataset: RheosDataset, now: Date, hours: Double) -> String {
        let mealNotes = dataset.meals.filter { now.timeIntervalSince($0.date) <= hours * 3600 }.map(\.note)
        let notes = dataset.notes.filter { now.timeIntervalSince($0.date) <= hours * 3600 }.map(\.text)
        return (mealNotes + notes).joined(separator: " ")
    }

    private static func difference(_ later: Double?, minus earlier: Double?) -> Double? {
        guard let later, let earlier else { return nil }
        return later - earlier
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.0f %%", value * 100)
    }

    private static func formatted(_ value: Double?) -> String {
        guard let value else { return "–" }
        return String(format: "%.0f", value)
    }
}
