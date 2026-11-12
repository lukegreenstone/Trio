import Foundation

struct RheosBasalSlot: Equatable, Identifiable {
    var id: Int { hour }
    var hour: Int
    var current: Double
    var proposed: Double
}

struct RheosBasalProposal: Equatable {
    var slots: [RheosBasalSlot]
    var material: Bool
    var summary: String
}

enum RheosBasalRecommendation {
    /// Proposed hourly rates from the learned basal factors. Nothing here is written.
    static func propose(
        rates: [(minutes: Int, rate: Double)],
        factors: [Double],
        previous: [Double]?,
        dawnNote: String
    ) -> RheosBasalProposal {
        let slots = (0 ..< 24).map { hour -> RheosBasalSlot in
            let current = rate(at: hour, rates: rates)
            let factor = factors.count == 24 ? min(max(factors[hour], 0.7), 1.2) : 1
            let proposed = (current * factor * 1000).rounded() / 1000
            return RheosBasalSlot(hour: hour, current: current, proposed: max(proposed, 0))
        }
        let next = slots.map(\.proposed)
        let material = materiallyDifferent(previous: previous, next: next)
        let summary = "Vorschlag für das Trio-Basalprofil, noch nicht gespeichert und nicht an die Pumpe gesendet. "
            + (material ? "Die Stundenraten haben sich deutlich geändert. " : "Gegen den letzten Vorschlag ist wenig neu. ")
            + dawnNote
            + " Erst ein Tipp übernimmt das Profil. Trio kann es dann als Fallback ohne iPhone an die Pumpe geben."
        return RheosBasalProposal(slots: slots, material: material, summary: summary)
    }

    static func materiallyDifferent(previous: [Double]?, next: [Double], threshold: Double = 0.08) -> Bool {
        guard let previous, previous.count == next.count, !previous.isEmpty else { return true }
        let changes = zip(previous, next).map { old, new -> Double in
            guard old > 0 else { return new == 0 ? 0 : 1 }
            return abs(new - old) / old
        }
        let mean = changes.reduce(0, +) / Double(changes.count)
        return mean >= threshold
    }

    private static func rate(at hour: Int, rates: [(minutes: Int, rate: Double)]) -> Double {
        let minute = hour * 60
        let active = rates.filter { $0.minutes <= minute }.max { $0.minutes < $1.minutes }
            ?? rates.min { $0.minutes < $1.minutes }
        return active?.rate ?? 0
    }
}

struct RheosWakeSample: Equatable {
    var wakeHour: Double
    /// Rise from 05:00 to 08:00, mg/dL. Clock-bound.
    var clockRise: Double
    /// Rise from wake to 90 minutes later, mg/dL.
    var wakeRise: Double
}

enum RheosWakeKind: String, Codable, Equatable {
    case dawn
    case feetOnFloor
    case unclear
}

struct RheosWakeState: Codable, Equatable {
    var enabled: Bool = false
    var confirmed: Bool = false
    var kind: String = RheosWakeKind.unclear.rawValue
    var lastWake: Date? = nil
    var pattern: String = ""
}

enum RheosWake {
    /// Early and late mornings. A clock-bound rise stays in the basal proposal.
    /// A wake-bound rise is a morning window, not a change of the saved basal file.
    static func classify(_ samples: [RheosWakeSample]) -> RheosWakeKind {
        let early = samples.filter { $0.wakeHour < 7 }
        let late = samples.filter { $0.wakeHour >= 8 }
        guard early.count >= 3, late.count >= 3 else { return .unclear }
        let clockGap = abs(median(early.map(\.clockRise)) - median(late.map(\.clockRise)))
        let wakeGap = abs(median(early.map(\.wakeRise)) - median(late.map(\.wakeRise)))
        if clockGap < 15, wakeGap >= 20 { return .dawn }
        if wakeGap < 15, clockGap >= 20 { return .feetOnFloor }
        return .unclear
    }

    static func samples(glucose: [RheosGlucosePoint], sleepEnds: [Date], calendar: Calendar) -> [RheosWakeSample] {
        sleepEnds.compactMap { wake in
            let hour = calendar.component(.hour, from: wake)
            let minute = calendar.component(.minute, from: wake)
            let day = calendar.startOfDay(for: wake)
            guard let at5 = nearest(glucose, day.addingTimeInterval(5 * 3600)),
                  let at8 = nearest(glucose, day.addingTimeInterval(8 * 3600)),
                  let atWake = nearest(glucose, wake),
                  let later = nearest(glucose, wake.addingTimeInterval(90 * 60)) else { return nil }
            return RheosWakeSample(
                wakeHour: Double(hour) + Double(minute) / 60,
                clockRise: at8 - at5,
                wakeRise: later - atWake
            )
        }
    }

    private static func nearest(_ glucose: [RheosGlucosePoint], _ date: Date) -> Double? {
        glucose.filter { abs($0.date.timeIntervalSince(date)) <= 45 * 60 }.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }?.mgdl
    }

    static func minutesSinceWake(now: Date, wake: Date?) -> Double? {
        guard let wake, now >= wake else { return nil }
        return now.timeIntervalSince(wake) / 60
    }

    /// Feet-on-the-floor window: 15 to 120 minutes after waking, basal up and ISF down, inside the band.
    /// Schatten returns the same numbers with `apply` false so they are only logged.
    static func window(
        factors: RheosHourlyFactors,
        minutesSinceWake: Double?,
        kind: RheosWakeKind,
        enabled: Bool,
        confirmed: Bool,
        modeIsScharf: Bool,
        band: ClosedRange<Double>
    ) -> (factors: RheosHourlyFactors, apply: Bool, line: String) {
        guard kind == .feetOnFloor, let minutes = minutesSinceWake, minutes >= 15, minutes <= 120 else {
            return (factors, false, "")
        }
        var copy = factors
        let hour = min(23, max(0, Int(minutes / 60)))
        if copy.basal.count == 24 {
            copy.basal[hour] = min(max(copy.basal[hour] * 1.1, band.lowerBound), band.upperBound)
        }
        if copy.isf.count == 24 {
            copy.isf[hour] = min(max(copy.isf[hour] / 1.1, band.lowerBound), band.upperBound)
        }
        let apply = enabled && confirmed && modeIsScharf
        let line = apply
            ? " Aufwachfenster aktiv, Basal und ISF nur im Band. Trio-SMB gibt ab, Rheos gibt keinen Bolus."
            : " Nach dem Aufwachen würde Rheos Basal und ISF im Band anheben. Noch keine Wirkung."
        return (copy, apply, line)
    }

    static func shouldAskAgain(previous: String, current: RheosWakeKind) -> Bool {
        guard !previous.isEmpty, current != .unclear else { return false }
        return previous != current.rawValue
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }
}

enum RheosDynamicISF {
    static func neutralize(_ factors: RheosHourlyFactors, dynamicISFOn: Bool) -> RheosHourlyFactors {
        guard dynamicISFOn else { return factors }
        var copy = factors
        if !copy.isf.isEmpty { copy.isf = Array(repeating: 1, count: copy.isf.count) }
        return copy
    }

    /// Both pointing the same way for a while means the same need may be counted twice.
    static func doubleCountWarning(meanBasalFactor: Double, autosensRatio: Double?) -> String? {
        guard let autosensRatio else { return nil }
        if meanBasalFactor > 1.05, autosensRatio > 1.05 {
            return "Rheos-Basal und Autosens zeigen beide nach oben. Das kann doppelt zählen. Bitte mit dem Team prüfen. Rheos ändert Autosens nicht."
        }
        if meanBasalFactor < 0.95, autosensRatio < 0.95 {
            return "Rheos-Basal und Autosens zeigen beide nach unten. Das kann doppelt zählen. Bitte mit dem Team prüfen. Rheos ändert Autosens nicht."
        }
        return nil
    }
}

enum RheosDataQuality {
    /// Drops points that should not teach the model. Alarms are untouched.
    static func excludingUnusable(_ dataset: RheosDataset, calendar: Calendar, now: Date = Date()) -> RheosDataset {
        var copy = RheosCare.excludingCompression(dataset, calendar: calendar)
        let warmup = warmupDates(glucose: copy.glucose)
        let sites = siteDates(glucose: copy.glucose, sites: []) // patch sites live outside the dataset
        let occlusion = occlusionDates(glucose: copy.glucose, now: now)
        let blocked = warmup.union(sites).union(occlusion)
        copy.glucose = copy.glucose.filter { !blocked.contains($0.date.timeIntervalSince1970) }
        return copy
    }

    static func excludingUnusable(_ dataset: RheosDataset, sites: [RheosPatchSite], calendar: Calendar, now: Date = Date()) -> RheosDataset {
        var copy = excludingUnusable(dataset, calendar: calendar, now: now)
        let blocked = siteDates(glucose: dataset.glucose, sites: sites)
        copy.glucose = copy.glucose.filter { !blocked.contains($0.date.timeIntervalSince1970) }
        return copy
    }

    static func warmupDates(glucose: [RheosGlucosePoint]) -> Set<TimeInterval> {
        let sorted = glucose.filter { $0.mgdl > 0 }.sorted { $0.date < $1.date }
        guard sorted.count >= 2 else { return [] }
        var blocked = Set<TimeInterval>()
        for index in 1 ..< sorted.count {
            let gap = sorted[index].date.timeIntervalSince(sorted[index - 1].date)
            guard gap >= 45 * 60 else { continue }
            let start = sorted[index].date
            for point in sorted where point.date >= start && point.date <= start.addingTimeInterval(2 * 3600) {
                blocked.insert(point.date.timeIntervalSince1970)
            }
        }
        return blocked
    }

    static func siteDates(glucose: [RheosGlucosePoint], sites: [RheosPatchSite]) -> Set<TimeInterval> {
        var blocked = Set<TimeInterval>()
        for site in sites {
            for point in glucose where point.date >= site.started && point.date <= site.started.addingTimeInterval(6 * 3600) {
                blocked.insert(point.date.timeIntervalSince1970)
            }
        }
        return blocked
    }

    static func occlusionDates(glucose: [RheosGlucosePoint], now: Date) -> Set<TimeInterval> {
        let recent = glucose.filter { $0.date >= now.addingTimeInterval(-2 * 3600) && $0.mgdl >= 250 }
        guard recent.count >= 4,
              let first = recent.min(by: { $0.date < $1.date }),
              let last = recent.max(by: { $0.date < $1.date }),
              last.date.timeIntervalSince(first.date) >= 60 * 60,
              last.mgdl >= first.mgdl - 15
        else { return [] }
        return Set(recent.map { $0.date.timeIntervalSince1970 })
    }
}

struct RheosHourDecision: Codable, Equatable, Identifiable {
    var id: String
    var date: Date
    var hour: Int
    var basal: Double
    var isf: Double
    var carbRatio: Double
    var inputs: String
    var reason: String
    var autosensRatio: Double?
    var applied: Bool
}

enum RheosDecisionLog {
    static func entry(
        now: Date,
        factors: RheosHourlyFactors,
        inputs: String,
        reason: String,
        autosensRatio: Double?,
        applied: Bool
    ) -> RheosHourDecision {
        let hour = Calendar.current.component(.hour, from: now)
        return RheosHourDecision(
            id: "\(Int(now.timeIntervalSince1970))-\(hour)",
            date: now,
            hour: hour,
            basal: factors.basal.count == 24 ? factors.basal[hour] : 1,
            isf: factors.isf.count == 24 ? factors.isf[hour] : 1,
            carbRatio: factors.carbRatio.count == 24 ? factors.carbRatio[hour] : 1,
            inputs: inputs,
            reason: reason,
            autosensRatio: autosensRatio,
            applied: applied
        )
    }

    static func appending(_ log: [RheosHourDecision], _ entry: RheosHourDecision) -> [RheosHourDecision] {
        var copy = log.filter { $0.id != entry.id }
        copy.append(entry)
        if copy.count > 24 * 14 { copy.removeFirst(copy.count - 24 * 14) }
        return copy
    }
}

enum RheosLearningReport {
    static func local(decisionReason: String, shadow: String, confidence: String) -> String {
        "Lernbericht, lokal formuliert. \(decisionReason) \(shadow) Vertrauen: \(confidence). Das ist keine Therapieanweisung und kein Bolus."
    }

    static func confidence(samples: Int, trained: Bool) -> String {
        if trained, samples >= 500 { return "hoch genug für einen Schattenvergleich" }
        if samples >= 200 { return "noch dünn" }
        return "zu wenig Daten"
    }
}

enum RheosCloudPolicy {
    static let key = "rheos.cloudAnalysis"

    static func allowsCloud(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? false
    }
}

enum RheosUpkeep {
    static let exportKey = "rheos.lastExport"

    static func exportReminder(lastExport: Date?, hasData: Bool, now: Date) -> String? {
        guard hasData else { return nil }
        guard let lastExport else {
            return "Der Lernstand wurde noch nicht exportiert. Ein Export liegt nur bei dir."
        }
        if now.timeIntervalSince(lastExport) >= 14 * 86400 {
            return "Der letzte Export des Lernstands ist über 14 Tage her."
        }
        return nil
    }

    static func loopWarning(lastLoop: Date?, now: Date) -> String? {
        guard let lastLoop else { return "Kein Loop-Zeitpunkt gespeichert. Aktiv ist dann nur das Pumpenbasal." }
        if now.timeIntervalSince(lastLoop) >= 45 * 60 {
            return "Der Loop hat seit mindestens 45 Minuten nicht gerechnet. Aktiv ist das Pumpenbasal, nicht Rheos."
        }
        return nil
    }
}

enum RheosMealText {
    /// No sample numbers. A model copies 0,0,0 when the prompt shows that object.
    static func prompt(for description: String) -> String {
        """
        Schätze Kohlenhydrate, Fett und Protein in Gramm für diese Mahlzeit: \(description).
        Antworte nur mit einem JSON-Objekt. Die Schlüssel heißen carbs, fat, protein und kcal.
        Jeder Wert ist eine realistische Zahl in Gramm, kein Platzhalter. Eine echte Mahlzeit hat nicht bei allen drei Nährwerten 0. Kein Bolus.
        """
    }

    static let photoPrompt = """
    Schätze Kohlenhydrate, Fett und Protein in Gramm für das Foto.
    Antworte nur mit einem JSON-Objekt. Die Schlüssel heißen carbs, fat, protein und kcal.
    Jeder Wert ist eine realistische Zahl in Gramm, kein Platzhalter. Nicht alle drei Nährwerte dürfen 0 sein. Kein Bolus.
    """
}
