import Foundation

/// A place the user records when the Medtrum patch is changed.
/// Trio already stores a site-change event and uses a rewind to reset autosens.
/// It does not store where on the body the patch sits, and it does not compare sites.
struct RheosPatchSite: Codable, Equatable, Identifiable {
    var id: String
    var place: String
    var started: Date
}

/// Suggestions only. Nothing here changes a dose, a limit, or a Trio alarm.
struct RheosCareReport: Equatable {
    var patchCheck: String?
    var compressionExcluded: [Date]
    var siteNotes: [String]
    var weekly: String
    var hypoSuggestion: String?
    var alcohol: String?
}

enum RheosCare {
    /// High glucose that is not falling despite insulin on board.
    /// Trio already has a high-glucose alarm. This does not replace it.
    static func patchCheck(dataset: RheosDataset, now: Date) -> String? {
        let windowStart = now.addingTimeInterval(-2 * 3600)
        let recent = dataset.glucose.filter { $0.date >= windowStart && $0.date <= now && $0.mgdl >= 250 }
            .sorted { $0.date < $1.date }
        guard recent.count >= 4,
              let first = recent.first,
              let last = recent.last,
              last.date.timeIntervalSince(first.date) >= 60 * 60,
              last.mgdl >= first.mgdl - 15
        else { return nil }
        let iob = dataset.states.filter { abs($0.date.timeIntervalSince(now)) <= 30 * 60 }.compactMap(\.iob).max() ?? 0
        let insulin = dataset.insulin.filter { $0.date >= windowStart && $0.date <= now }.reduce(0) { $0 + $1.units }
        guard iob >= 1.5 || insulin >= 2 else { return nil }
        return "Glukose bleibt hoch, obwohl Insulin da ist. Bitte Ketone messen und das Medtrum-Pflaster prüfen. Das ist nur ein Hinweis. Trios Hoch-Alarm bleibt unabhängig davon aktiv. Rheos gibt kein Insulin."
    }

    /// Night-time drops that fall too fast and bounce back. Those points are
    /// left out of learning. Trio's low alarms are not touched.
    static func compressionLows(glucose: [RheosGlucosePoint], calendar: Calendar) -> [Date] {
        let sorted = glucose.filter { $0.mgdl > 0 }.sorted { $0.date < $1.date }
        var excluded: [Date] = []
        guard sorted.count >= 3 else { return [] }
        for index in 1 ..< (sorted.count - 1) {
            let previous = sorted[index - 1]
            let point = sorted[index]
            let next = sorted[index + 1]
            let hour = calendar.component(.hour, from: point.date)
            guard hour >= 23 || hour < 7 else { continue }
            let downMinutes = point.date.timeIntervalSince(previous.date) / 60
            guard downMinutes > 0, downMinutes <= 12 else { continue }
            let drop = previous.mgdl - point.mgdl
            let rate = drop / downMinutes
            guard drop >= 40, rate >= 6, point.mgdl < 80 else { continue }
            let recoveryMinutes = next.date.timeIntervalSince(point.date) / 60
            guard recoveryMinutes > 0, recoveryMinutes <= 20 else { continue }
            let recovered = next.mgdl - point.mgdl
            guard recovered >= drop * 0.5 else { continue }
            excluded.append(point.date)
        }
        return excluded
    }

    static func excludingCompression(_ dataset: RheosDataset, calendar: Calendar) -> RheosDataset {
        let excluded = Set(compressionLows(glucose: dataset.glucose, calendar: calendar).map { $0.timeIntervalSince1970 })
        var copy = dataset
        copy.glucose = dataset.glucose.filter { !excluded.contains($0.date.timeIntervalSince1970) }
        return copy
    }

    static func siteNotes(sites: [RheosPatchSite], glucose: [RheosGlucosePoint]) -> [String] {
        let ordered = sites.sorted { $0.started < $1.started }
        guard ordered.count >= 2 else {
            return ordered.isEmpty
                ? []
                : ["Stelle „\(ordered[0].place)“ ist notiert. Ein Vergleich braucht mindestens eine weitere Stelle."]
        }
        return ordered.enumerated().map { index, site in
            let end = index + 1 < ordered.count ? ordered[index + 1].started : .distantFuture
            let values = glucose.filter { $0.date >= site.started && $0.date < end && $0.mgdl > 0 }.map(\.mgdl)
            guard let median = RheosStats.median(values), values.count >= 8 else {
                return "„\(site.place)“: noch zu wenig Glukose für einen Vergleich."
            }
            let high = Double(values.filter { $0 > 180 }.count) / Double(values.count)
            return "„\(site.place)“: Median \(Int(median)) mg/dL, \(Int(high * 100)) % über 180. Nur ein Vergleich, keine Dosis."
        }
    }

    /// Seven-day snapshot for the diabetes team. Trio's Statistics screen already
    /// shows TITR, TIR and CV for the ranges you pick there. This is that same
    /// 70–140 / 70–180 / CV definition for the last week, plus what Rheos learned.
    static func weeklyReport(glucose: [RheosGlucosePoint], learned: String, now: Date) -> String {
        let start = now.addingTimeInterval(-7 * 24 * 3600)
        let week = glucose.filter { $0.date >= start && $0.date <= now && $0.mgdl > 0 }
        let stability = RheosAnalysis.stability(glucose: week)
        let hypos = week.filter { $0.mgdl < 70 }.count
        let hypoPercent = week.isEmpty ? 0 : Double(hypos) / Double(week.count) * 100
        let titr = stability.timeInTightRange.map { String(format: "%.0f %%", $0 * 100) } ?? "–"
        let tir = stability.timeInRange.map { String(format: "%.0f %%", $0 * 100) } ?? "–"
        let cv = stability.coefficientOfVariationPercent.map { String(format: "%.0f %%", $0) } ?? "–"
        return """
        Rheos-Wochenbericht (letzte 7 Tage). Trios Statistikansicht bleibt die laufende Ansicht.
        Zeit 70–140 mg/dL (TITR): \(titr)
        Zeit 70–180 mg/dL (TIR): \(tir)
        Variationskoeffizient: \(cv)
        Werte unter 70 mg/dL: \(hypos) (\(String(format: "%.0f", hypoPercent)) %)
        Was Rheos gelernt hat: \(learned)
        Das ist ein Bericht, keine Dosierung.
        """
    }

    /// Extrapolates the recent slope. The carb grams are the median of past
    /// treatments that were followed by a recovery from below 70. Trio already
    /// shows oref's carbs-required alarm; this does not replace it and does not log carbs.
    static func hypoSuggestion(dataset: RheosDataset, now: Date) -> String? {
        let recent = dataset.glucose.filter { $0.date <= now && now.timeIntervalSince($0.date) <= 40 * 60 && $0.mgdl > 0 }
            .sorted { $0.date < $1.date }
        guard recent.count >= 3, let last = recent.last, let first = recent.first else { return nil }
        let minutes = last.date.timeIntervalSince(first.date) / 60
        guard minutes >= 8 else { return nil }
        let slope = (last.mgdl - first.mgdl) / minutes
        guard slope < 0, last.mgdl > 70 else { return nil }
        let minutesTo70 = (last.mgdl - 70) / -slope
        guard minutesTo70 > 0, minutesTo70 <= 30 else { return nil }
        let learned = learnedHypoCarbs(dataset: dataset)
        if let learned {
            return "In etwa \(Int(minutesTo70.rounded())) Minuten könnte die Glukose unter 70 mg/dL liegen. Aus früheren Behandlungen liegt der Median bei \(Int(learned)) g Kohlenhydrate. Nur ein Vorschlag. Trios Alarm „Kohlenhydrate nötig“ bleibt separat. Rheos trägt nichts ein."
        }
        return "In etwa \(Int(minutesTo70.rounded())) Minuten könnte die Glukose unter 70 mg/dL liegen. Rheos hat noch zu wenige eigene Behandlungen, um eine Grammzahl zu nennen. Trios Alarm „Kohlenhydrate nötig“ kommt aus oref. Rheos trägt nichts ein."
    }

    static func learnedHypoCarbs(dataset: RheosDataset) -> Double? {
        let treatments = dataset.meals.filter { meal in
            meal.carbs > 0 && recoveredFromHypo(after: meal, glucose: dataset.glucose)
        }.map(\.carbs)
        guard treatments.count >= 3 else { return nil }
        return RheosStats.median(treatments)
    }

    /// Optional alcohol note plus a delayed-hypo observation. Does not start a temp target.
    static func alcoholNote(dataset: RheosDataset, alcoholDates: [Date], now _: Date) -> String? {
        let events = alcoholDates
        guard events.count >= 2 else {
            return events.isEmpty ? nil : "Alkohol ist notiert. Eine verzögerte Hypo-Einschätzung braucht mindestens zwei Nächte."
        }
        let alcoholHypos = events.filter { hypoBetween(start: $0.addingTimeInterval(4 * 3600), end: $0.addingTimeInterval(12 * 3600), glucose: dataset.glucose) }
        let alcoholRate = Double(alcoholHypos.count) / Double(events.count)
        let other = baselineNightHypoRate(dataset: dataset, excluding: events)
        guard alcoholRate >= other + 0.15 else {
            return "Nach Alkohol liegt die nächtliche Hypo-Häufigkeit bisher nicht klar über den anderen Nächten. Kein Temp-Target von Rheos."
        }
        return "Nach Alkohol folgt in \(Int(alcoholRate * 100)) % der Nächte eine Glukose unter 70 zwischen 4 und 12 Stunden später, häufiger als sonst. Vorschlag: in Trio ein Temp-Target prüfen, wenn du eines dafür angelegt hast. Rheos aktiviert es nicht und gibt kein Insulin."
    }

    static func report(
        dataset: RheosDataset,
        sites: [RheosPatchSite],
        alcoholDates: [Date],
        learned: String,
        now: Date,
        calendar: Calendar
    ) -> RheosCareReport {
        let learning = excludingCompression(dataset, calendar: calendar)
        return RheosCareReport(
            patchCheck: patchCheck(dataset: dataset, now: now),
            compressionExcluded: compressionLows(glucose: dataset.glucose, calendar: calendar),
            siteNotes: siteNotes(sites: sites, glucose: dataset.glucose),
            weekly: weeklyReport(glucose: dataset.glucose, learned: learned, now: now),
            hypoSuggestion: hypoSuggestion(dataset: learning, now: now),
            alcohol: alcoholNote(dataset: dataset, alcoholDates: alcoholDates, now: now)
        )
    }

    private static func recoveredFromHypo(after meal: RheosMealEvent, glucose: [RheosGlucosePoint]) -> Bool {
        let before = glucose.filter { meal.date.timeIntervalSince($0.date) >= 0 && meal.date.timeIntervalSince($0.date) <= 20 * 60 }
        let after = glucose.filter { $0.date.timeIntervalSince(meal.date) >= 0 && $0.date.timeIntervalSince(meal.date) <= 45 * 60 }
        guard before.contains(where: { $0.mgdl < 70 }) || after.contains(where: { $0.mgdl < 70 }) else { return false }
        return after.contains { $0.mgdl >= 80 }
    }

    private static func hypoBetween(start: Date, end: Date, glucose: [RheosGlucosePoint]) -> Bool {
        glucose.contains { $0.date >= start && $0.date <= end && $0.mgdl < 70 && $0.mgdl > 0 }
    }

    private static func baselineNightHypoRate(dataset: RheosDataset, excluding events: [Date]) -> Double {
        let nights = Set(dataset.glucose.map { Calendar.current.startOfDay(for: $0.date) })
        guard !nights.isEmpty else { return 0 }
        var hits = 0
        for night in nights {
            let overlapsAlcohol = events.contains { abs($0.timeIntervalSince(night)) < 18 * 3600 }
            if overlapsAlcohol { continue }
            let start = night.addingTimeInterval(23 * 3600)
            let end = night.addingTimeInterval(32 * 3600)
            if hypoBetween(start: start, end: end, glucose: dataset.glucose) { hits += 1 }
        }
        let considered = nights.filter { night in
            !events.contains { abs($0.timeIntervalSince(night)) < 18 * 3600 }
        }
        guard !considered.isEmpty else { return 0 }
        return Double(hits) / Double(considered.count)
    }
}

