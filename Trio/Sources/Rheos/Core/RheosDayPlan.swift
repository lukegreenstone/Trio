import Foundation

struct RheosLateDigestion: Codable, Equatable, Identifiable {
    var id: String
    var mealID: String
    var mealDate: Date
    var noted: Date
    var until: Date
}

struct RheosOpenUAM: Codable, Equatable, Identifiable {
    var id: String
    var started: Date
    var rise: Double
    var mealID: String?
    var mealDate: Date?
}

enum RheosClockBand: String, Equatable, CaseIterable {
    case morning
    case day
    case evening
    case night

    static func of(hour: Int) -> RheosClockBand {
        switch hour {
        case 5 ..< 11: return .morning
        case 11 ..< 17: return .day
        case 17 ..< 22: return .evening
        default: return .night
        }
    }

    var title: String {
        switch self {
        case .morning: return "Morgen"
        case .day: return "Tag"
        case .evening: return "Abend"
        case .night: return "Nacht"
        }
    }
}

struct RheosAbsorptionPoint: Equatable {
    var hour: Int
    var carbs: Double
    var rise2h: Double
    var rise4h: Double
}

struct RheosAbsorptionBand: Equatable, Identifiable {
    var id: String { band.rawValue }
    var band: RheosClockBand
    var meals: Int
    var lateFraction: Double
    var immediateShare: Double
}

enum RheosAbsorption {
    /// Rise that arrives after the first two hours, as a fraction of the four-hour rise.
    static func lateFraction(rise2h: Double, rise4h: Double) -> Double {
        guard rise4h > 0 else { return 0 }
        return min(1, max(0, rise4h - max(rise2h, 0)) / rise4h)
    }

    /// Share of Trio's already-reduced bolus to give immediately. Evening stays smaller.
    static func immediateShare(lateFraction: Double, band: RheosClockBand, meals: Int) -> Double {
        let evening = band == .evening || band == .night
        if meals < 3 { return evening ? 0.6 : 1 }
        var share = 1 - min(max(lateFraction, 0), 0.8)
        share = min(max(share, 0.4), 1)
        if evening { share = min(share, 0.7) }
        return share
    }

    static func points(
        meals: [RheosMealEvent],
        glucose: [RheosGlucosePoint],
        late: [RheosLateDigestion] = [],
        calendar: Calendar
    ) -> [RheosAbsorptionPoint] {
        meals.compactMap { meal in
            guard meal.carbs >= 5 else { return nil }
            guard let start = nearest(glucose, meal.date),
                  let at2 = nearest(glucose, meal.date.addingTimeInterval(2 * 3600)),
                  let at4 = nearest(glucose, meal.date.addingTimeInterval(4 * 3600)) else { return nil }
            var rise4 = at4 - start
            if let mark = late.first(where: { $0.mealID == meal.id }),
               let atNote = nearest(glucose, mark.noted) {
                rise4 = max(rise4, atNote - start)
            }
            return RheosAbsorptionPoint(
                hour: calendar.component(.hour, from: meal.date),
                carbs: meal.carbs,
                rise2h: at2 - start,
                rise4h: rise4
            )
        }
    }

    static func bands(_ points: [RheosAbsorptionPoint]) -> [RheosAbsorptionBand] {
        RheosClockBand.allCases.compactMap { band in
            let rows = points.filter { RheosClockBand.of(hour: $0.hour) == band }
            guard !rows.isEmpty else { return nil }
            let late = median(rows.map { lateFraction(rise2h: $0.rise2h, rise4h: $0.rise4h) })
            return RheosAbsorptionBand(
                band: band,
                meals: rows.count,
                lateFraction: late,
                immediateShare: immediateShare(lateFraction: late, band: band, meals: rows.count)
            )
        }
    }

    static func band(for hour: Int, in bands: [RheosAbsorptionBand]) -> RheosAbsorptionBand? {
        bands.first { $0.band == RheosClockBand.of(hour: hour) }
    }

    private static func nearest(_ glucose: [RheosGlucosePoint], _ date: Date) -> Double? {
        glucose.filter { abs($0.date.timeIntervalSince(date)) <= 40 * 60 }.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }?.mgdl
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }
}

struct RheosBolusShareSuggestion: Equatable {
    var trioPercent: Double
    var refinedPercent: Double
    var immediateUnits: Double
    var line: String
    /// True only in Scharf, and only as a label for the button that copies into Trio's field.
    var copiesIntoField: Bool
}

enum RheosBolusShare {
    /// `calculatorUnits` is Trio's recommendation after its own percentage. Rheos does not write that percentage.
    static func suggest(
        hour: Int,
        trioPercent: Double,
        bands: [RheosAbsorptionBand],
        calculatorUnits: Double,
        smbOn: Bool,
        uamOn: Bool,
        maxIOB: Double,
        modeIsScharf: Bool
    ) -> RheosBolusShareSuggestion {
        let trio = min(max(trioPercent, 0.05), 1.5)
        let share = RheosAbsorption.band(for: hour, in: bands)?.immediateShare
            ?? RheosAbsorption.immediateShare(lateFraction: 0, band: RheosClockBand.of(hour: hour), meals: 0)
        let refined = min(trio, max(0.2, (trio * share * 100).rounded() / 100))
        let units = trio > 0 ? max(0, calculatorUnits) * refined / trio : 0
        var line = String(
            format: "Trio-Bolusprozentsatz %.0f %%. Rheos würde jetzt %.0f %% davon sofort vorschlagen (%.2f E), den Rest Trio-SMB/UAM. Nur nach Tippen ins Bolusfeld. Rheos gibt keinen Bolus und ändert den Prozentsatz nicht.",
            trio * 100,
            refined * 100,
            units
        )
        if !smbOn || !uamOn || maxIOB <= 0 {
            line += " SMB oder UAM ist aus oder Max IOB ist 0. Der Rest wird dann nicht automatisch ausgeglichen. Nur mit dem Team."
        }
        if !modeIsScharf {
            line += " Schatten, nur als ob."
        }
        let smaller = refined + 0.02 < trio && units > 0
        return RheosBolusShareSuggestion(
            trioPercent: trio,
            refinedPercent: refined,
            immediateUnits: (units * 100).rounded() / 100,
            line: line,
            copiesIntoField: modeIsScharf && smaller
        )
    }
}

enum RheosAbsorptionShadow {
    /// What the smaller share would have given up front, and the SMB units that followed.
    static func split(
        meal: RheosMealEvent,
        insulin: [RheosInsulinEvent],
        trioPercent: Double,
        refinedPercent: Double
    ) -> (wouldGiveNow: Double, smbUnits: Double, line: String)? {
        let bolus = insulin.filter {
            $0.kind == "bolus" && $0.date >= meal.date && $0.date.timeIntervalSince(meal.date) <= 30 * 60
        }.reduce(0) { $0 + $1.units }
        let smb = insulin.filter {
            $0.kind == "smb" && $0.date >= meal.date && $0.date.timeIntervalSince(meal.date) <= 5 * 3600
        }.reduce(0) { $0 + $1.units }
        guard bolus > 0, trioPercent > 0 else { return nil }
        let would = bolus / trioPercent * refinedPercent
        let line = String(
            format: "Schatten, als ob: sofort etwa %.2f E statt %.2f E. SMB in den Stunden danach %.2f E. Rheos hat nichts abgegeben.",
            would,
            bolus,
            smb
        )
        return (would, smb, line)
    }
}

struct RheosSportLesson: Equatable {
    var summary: String
    var suggestion: String?
}

enum RheosSportLearning {
    static func learn(
        workouts: [RheosWorkout],
        glucose: [RheosGlucosePoint],
        now: Date,
        calendar: Calendar
    ) -> RheosSportLesson {
        let usable = workouts.filter { $0.durationMinutes >= 15 }
        guard usable.count >= 3 else {
            return RheosSportLesson(
                summary: "Noch zu wenige Workouts aus Apple Health, um Sport vorauszusagen.",
                suggestion: nil
            )
        }
        let hours = usable.map { startHour($0.start, calendar: calendar) }
        let usual = median(hours)
        let duringValues = usable.compactMap { drop(glucose, from: $0.start, minutes: $0.durationMinutes) }
        let delayedValues = usable.compactMap { drop(glucose, from: $0.start.addingTimeInterval($0.durationMinutes * 60), minutes: 240) }
        let during = duringValues.isEmpty ? nil : median(duringValues)
        let delayed = delayedValues.isEmpty ? nil : median(delayedValues)
        let night = nightGap(workouts: usable, glucose: glucose, calendar: calendar)
        var summary = String(format: "Training sonst gegen %02d:%02d.", Int(usual), Int((usual * 60).truncatingRemainder(dividingBy: 60)))
        if let during {
            summary += String(format: " Währenddessen im Mittel %+.0f mg/dL.", during)
        }
        if let delayed {
            summary += String(format: " In den Stunden danach %+.0f mg/dL.", delayed)
        }
        if let night {
            summary += String(format: " In der Nacht danach %+.0f mg/dL gegen Nächte ohne Training.", night)
        }
        summary += " Bestätigung startet das gespeicherte Preset Sport. Rheos erfindet kein Ziel und gibt keinen Bolus."
        let lead = minutesUntil(hour: usual, now: now, calendar: calendar)
        let suggestion = (lead >= 15 && lead <= 90) ? summary : nil
        return RheosSportLesson(summary: summary, suggestion: suggestion)
    }

    private static func startHour(_ date: Date, calendar: Calendar) -> Double {
        Double(calendar.component(.hour, from: date)) + Double(calendar.component(.minute, from: date)) / 60
    }

    private static func minutesUntil(hour: Double, now: Date, calendar: Calendar) -> Int {
        let nowMinutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        return Int((hour * 60).rounded()) - nowMinutes
    }

    private static func drop(_ glucose: [RheosGlucosePoint], from: Date, minutes: Double) -> Double? {
        guard let start = nearest(glucose, from),
              let later = nearest(glucose, from.addingTimeInterval(minutes * 60)) else { return nil }
        return later - start
    }

    private static func nightGap(
        workouts: [RheosWorkout],
        glucose: [RheosGlucosePoint],
        calendar: Calendar
    ) -> Double? {
        var workoutNights = Set<Date>()
        for workout in workouts where calendar.component(.hour, from: workout.start) < 22 {
            let night = calendar.startOfDay(for: workout.start.addingTimeInterval(24 * 3600))
            workoutNights.insert(night)
        }
        let nights = Dictionary(grouping: glucose) { point -> Date in
            calendar.startOfDay(for: point.date)
        }
        var withWorkout: [Double] = []
        var without: [Double] = []
        for (day, points) in nights {
            let night = points.filter {
                let hour = calendar.component(.hour, from: $0.date)
                return hour < 6 && $0.mgdl > 0
            }
            guard night.count >= 2, let low = night.map(\.mgdl).min() else { continue }
            if workoutNights.contains(day) { withWorkout.append(low) } else { without.append(low) }
        }
        guard withWorkout.count >= 2, without.count >= 2 else { return nil }
        return median(withWorkout) - median(without)
    }

    private static func nearest(_ glucose: [RheosGlucosePoint], _ date: Date) -> Double? {
        glucose.filter { abs($0.date.timeIntervalSince(date)) <= 45 * 60 }.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }?.mgdl
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }
}

enum RheosUAMKind: String, Equatable {
    case newMeal = "uam-meal"
    case late = "uam-late"
    case other = "uam-other"
    case speech = "uam-speech"
}

struct RheosUAMPrompt: Equatable {
    var rise: Double
    var started: Date
    var mealID: String?
    var mealDate: Date?
    var text: String
}

enum RheosUAM {
    static func detect(
        glucose: [RheosGlucosePoint],
        meals: [RheosMealEvent],
        now: Date,
        lastAsked: Date?,
        calendar: Calendar = .current
    ) -> RheosUAMPrompt? {
        if let lastAsked, now.timeIntervalSince(lastAsked) < 3 * 3600 { return nil }
        let recent = glucose.filter { $0.date <= now && now.timeIntervalSince($0.date) <= 90 * 60 && $0.mgdl > 0 }
            .sorted { $0.date < $1.date }
        guard recent.count >= 3,
              let first = recent.first,
              let last = recent.last,
              last.date.timeIntervalSince(first.date) >= 30 * 60 else { return nil }
        let rise = last.mgdl - first.mgdl
        guard rise >= 30 else { return nil }
        if meals.contains(where: { now.timeIntervalSince($0.date) <= 150 * 60 && $0.date <= now }) { return nil }
        let earlier = meals.filter { $0.date < now && now.timeIntervalSince($0.date) <= 8 * 3600 }
            .max { $0.date < $1.date }
        let when = earlier.map { time($0.date, calendar: calendar) } ?? "ohne passende Mahlzeit"
        return RheosUAMPrompt(
            rise: rise,
            started: first.date,
            mealID: earlier?.id,
            mealDate: earlier?.date,
            text: String(
                format: "Anstieg um %.0f mg/dL ohne eingetragene Mahlzeit. Neue Mahlzeit, späte Verdauung der Mahlzeit von %@, oder Stress/Krank/Sensor? Frei sprechen geht auch. Kein Bolus.",
                rise,
                when
            )
        )
    }

    static func interpret(_ text: String) -> RheosUAMKind {
        let asked = text.lowercased()
        if asked.contains("neue mahlzeit") || asked.contains("neu essen") { return .newMeal }
        if asked.contains("spät") || asked.contains("spaet") || asked.contains("verdau") { return .late }
        if asked.contains("stress") || asked.contains("krank") || asked.contains("sensor") { return .other }
        return .speech
    }

    /// Late digestion is attached to the earlier meal. It does not append a meal.
    static func lateMark(
        prompt: RheosUAMPrompt,
        now: Date,
        calendar: Calendar
    ) -> (mark: RheosLateDigestion, note: String)? {
        guard let mealID = prompt.mealID, let mealDate = prompt.mealDate else {
            return nil
        }
        let mark = RheosLateDigestion(
            id: "late-\(Int(now.timeIntervalSince1970))",
            mealID: mealID,
            mealDate: mealDate,
            noted: now,
            until: until(noted: now, calendar: calendar)
        )
        let note = "Späte Verdauung der Mahlzeit von \(time(mealDate, calendar: calendar)). Kein neuer Eintrag und kein Extra-Bolus. SMB und UAM korrigieren weiter. Nachts bleibt Rheos vorsichtig."
        return (mark, note)
    }

    static func until(noted: Date, calendar: Calendar) -> Date {
        let hour = calendar.component(.hour, from: noted)
        if hour >= 18 || hour < 6 {
            let base = calendar.startOfDay(for: noted)
            let day = hour < 6 ? base : (calendar.date(byAdding: .day, value: 1, to: base) ?? noted)
            return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: day) ?? noted.addingTimeInterval(8 * 3600)
        }
        return noted.addingTimeInterval(4 * 3600)
    }

    private static func time(_ date: Date, calendar: Calendar) -> String {
        String(format: "%02d:%02d", calendar.component(.hour, from: date), calendar.component(.minute, from: date))
    }
}

enum RheosNightCaution {
    static func isNightHour(_ hour: Int) -> Bool { hour >= 22 || hour < 6 }

    static func covers(_ marks: [RheosLateDigestion], now: Date) -> Bool {
        marks.contains { now >= $0.noted && now <= $0.until }
    }

    /// Does not increase insulin during a confirmed late-digestion night. SMB and UAM are untouched.
    static func dampen(
        _ factors: RheosHourlyFactors,
        now: Date,
        marks: [RheosLateDigestion],
        modeIsScharf: Bool,
        calendar: Calendar
    ) -> (factors: RheosHourlyFactors, apply: Bool, line: String) {
        let hour = calendar.component(.hour, from: now)
        guard covers(marks, now: now), isNightHour(hour) else { return (factors, false, "") }
        var copy = factors
        if copy.basal.count == 24 { copy.basal[hour] = min(copy.basal[hour], 1) }
        if copy.isf.count == 24 { copy.isf[hour] = max(copy.isf[hour], 1) }
        if copy.carbRatio.count == 24 { copy.carbRatio[hour] = max(copy.carbRatio[hour], 1) }
        let line = " Späte Verdauung: nachts hebt Rheos Basal nicht an und senkt ISF nicht. SMB und UAM laufen normal. Kein neuer Mahlzeiteneintrag."
        return (copy, modeIsScharf, line)
    }
}

struct RheosNightCheck: Equatable {
    var nights: Int
    var lowNights: Int
    var highNights: Int
    var summary: String
    var shouldShowBeforeBasal: Bool
}

enum RheosNightReview {
    static func check(glucose: [RheosGlucosePoint], now: Date, calendar: Calendar) -> RheosNightCheck {
        let grouped = Dictionary(grouping: glucose.filter { $0.mgdl > 0 }) { point -> Date in
            let hour = calendar.component(.hour, from: point.date)
            let day = calendar.startOfDay(for: point.date)
            if hour < 6 { return day }
            return calendar.date(byAdding: .day, value: 1, to: day) ?? day
        }
        let recent = grouped.filter { $0.key <= calendar.startOfDay(for: now) }.prefix(14)
        var lows = 0
        var highs = 0
        var counted = 0
        for (_, points) in recent {
            let night = points.filter { calendar.component(.hour, from: $0.date) < 6 }
            guard night.count >= 2 else { continue }
            counted += 1
            if night.map(\.mgdl).min() ?? 999 < 70 { lows += 1 }
            if night.map(\.mgdl).max() ?? 0 > 180 { highs += 1 }
        }
        let summary = "Nachtmuster aus \(counted) Nächten: \(lows) mit Werten unter 70 mg/dL, \(highs) mit Werten über 180 mg/dL. Kurz ansehen, bevor das Basalprofil sich ändert. Rheos schreibt es nicht von selbst."
        let morning = (5 ..< 12).contains(calendar.component(.hour, from: now))
        let show = morning && counted >= 5 && (lows >= 2 || highs >= 2)
        return RheosNightCheck(nights: counted, lowNights: lows, highNights: highs, summary: summary, shouldShowBeforeBasal: show)
    }

    static func blocksBasalChange(show: Bool, acknowledgedDay: String?, today: String) -> Bool {
        show && acknowledgedDay != today
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

struct RheosTrioReading: Equatable {
    var bolusPercent: Double
    var maxSMBMinutes: Double
    var maxIOB: Double
    var smbOn: Bool
    var uamOn: Bool
    var autosensMin: Double
    var autosensMax: Double
    var targets: String
    var dynamicISFOn: Bool
    var closedLoop: Bool
}

enum RheosSettingsStory {
    static func explain(_ reading: RheosTrioReading) -> String {
        let smb = reading.smbOn ? "an" : "aus"
        let uam = reading.uamOn ? "an" : "aus"
        let loop = reading.closedLoop ? "Closed Loop" : "Open Loop"
        var text = String(
            format: "Trio, nur gelesen: Bolusprozentsatz %.0f %%, Max SMB %.0f Minuten, Max IOB %.1f E, SMB %@, UAM %@, Autosens %.2f–%.2f, Ziele %@, Dynamic ISF %@. %@.",
            reading.bolusPercent * 100,
            reading.maxSMBMinutes,
            reading.maxIOB,
            smb,
            uam,
            reading.autosensMin,
            reading.autosensMax,
            reading.targets,
            reading.dynamicISFOn ? "an" : "aus",
            loop
        )
        text += " Der Bolusprozentsatz skaliert den Rechner. Rheos darf ihn nach Tageszeit nur vorschlagen. Max SMB, SMB/UAM und Max IOB entscheiden, ob der Rest nachkommen kann."
        text += " Autosens min/max schneiden das Rheos-Band. Die Ziele bleiben Trios Ziele. Ein Sport-Vorschlag startet nur das gespeicherte Preset."
        if reading.dynamicISFOn {
            text += " Dynamic ISF ist an, deshalb bleibt der Rheos-ISF-Faktor 1."
        }
        if !reading.closedLoop {
            text += " Open Loop: Scharf erreicht die Pumpe nicht."
        }
        text += " Rheos ändert diese Einstellungen nicht."
        return text
    }
}

enum RheosPromptLines {
    static func lines(
        openUAM: RheosOpenUAM?,
        sport: RheosSportLesson,
        night: RheosNightCheck
    ) -> [RheosWatchSuggestionLine] {
        var lines: [RheosWatchSuggestionLine] = []
        if let openUAM {
            let when = openUAM.mealDate.map { date in
                let calendar = Calendar.current
                return String(format: "%02d:%02d", calendar.component(.hour, from: date), calendar.component(.minute, from: date))
            } ?? "vorher"
            lines.append(RheosWatchSuggestionLine(id: "uam-meal", kind: RheosUAMKind.newMeal.rawValue, title: "Neue Mahlzeit", note: "Anstieg ohne Eintrag. In Trio eintragen. Rheos legt keinen Eintrag an."))
            lines.append(RheosWatchSuggestionLine(id: "uam-late", kind: RheosUAMKind.late.rawValue, title: "Späte Verdauung", note: "Der Mahlzeit von \(when) zuordnen. Kein Extra-Bolus. Anstieg \(Int(openUAM.rise)) mg/dL."))
            lines.append(RheosWatchSuggestionLine(id: "uam-other", kind: RheosUAMKind.other.rawValue, title: "Stress/Krank/Sensor", note: "Nur eine Notiz. SMB und UAM laufen weiter."))
        }
        if let suggestion = sport.suggestion {
            lines.append(RheosWatchSuggestionLine(id: "sport-ahead", kind: "sport", title: "Sport", note: suggestion))
        }
        if night.shouldShowBeforeBasal {
            lines.append(RheosWatchSuggestionLine(id: "night-check", kind: "night", title: "Nacht", note: night.summary))
        }
        return lines
    }
}
