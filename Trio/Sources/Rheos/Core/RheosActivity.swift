import Foundation

/// Live step windows, lie-in, and heart-rate guard.
///
/// Structure and defaults follow Tim Street's Boost (AGPL-3.0),
/// https://github.com/tim2000s/Boost — `StepFeed.kt`, `SleepStateDetector.kt`,
/// `HrActivityCalculator.kt`, and the IntKey defaults for the step windows.
/// Rheos only logs what that logic would say. It does not change a profile,
/// a target, or a bolus.
enum RheosStepActivity {
    struct Thresholds: Equatable {
        var active5 = 420
        var active15 = 800
        var active30 = 1200
        var active60 = 1800
        var inactive60 = 500
        var wakeSteps60 = 250
        var wakeSteps15 = 100
        var lieInMinutes = 120.0
        /// Movement plus this much IOB is only a hint.
        var highIOB = 2.0
    }

    struct Windows: Equatable {
        var steps5: Int
        var steps15: Int
        var steps30: Int
        var steps60: Int
        /// False when the step source did not deliver a recent sample. Zero is then not "still".
        var feedFresh: Bool
    }

    enum Status: String, Codable, Equatable {
        case unknown
        case active
        case inactive
        case normal
        case pulseGuard
    }

    /// Karvonen zone 1...5. Zone 2 starts at 30% of heart-rate reserve, matching Boost.
    static func zone(bpm: Double, resting: Double, maxHeartRate: Double = 180) -> Int? {
        guard bpm > 0, resting > 0, maxHeartRate > resting else { return nil }
        let reserve = max(maxHeartRate - resting, 1)
        let percent = (bpm - resting) / reserve * 100
        switch percent {
        case ..<30: return 1
        case ..<40: return 2
        case ..<60: return 3
        case ..<80: return 4
        default: return 5
        }
    }

    static func status(
        windows: Windows,
        heartRate: Double?,
        restingHeartRate: Double?,
        thresholds: Thresholds = Thresholds()
    ) -> (status: Status, line: String) {
        guard windows.feedFresh else {
            return (.unknown, "Schritte kommen gerade nicht an. Eine 0 wird nicht als Inaktivität gelesen. Nur Schatten, nichts geändert.")
        }
        let active = (thresholds.active5 > 0 && windows.steps5 > thresholds.active5)
            || (thresholds.active15 > 0 && windows.steps15 > thresholds.active15)
            || (thresholds.active30 > 0 && windows.steps30 > thresholds.active30)
            || (thresholds.active60 > 0 && windows.steps60 > thresholds.active60)
        if active {
            return (.active, "Schritte aktiv: \(windows.steps5)/5, \(windows.steps15)/15, \(windows.steps30)/30, \(windows.steps60)/60. Nur Schatten, nichts geändert.")
        }
        if windows.steps60 < thresholds.inactive60 {
            let heartZone: Int?
            if let heartRate, let restingHeartRate {
                heartZone = RheosStepActivity.zone(bpm: heartRate, resting: restingHeartRate)
            } else {
                heartZone = nil
            }
            if let heartZone, heartZone >= 2 {
                return (.pulseGuard, "Wenig Schritte, Puls etwa Zone \(heartZone) (Karvonen, Ruhepuls). Das ist keine Inaktivität. Nur Schatten, nichts geändert.")
            }
            return (.inactive, "Wenig Schritte über 60 Minuten (\(windows.steps60) unter \(thresholds.inactive60)). Nur Schatten, nichts geändert.")
        }
        return (.normal, "Schritte im normalen Bereich. Nur Schatten, nichts geändert.")
    }

    /// After the usual wake time, feet-on-the-floor would wait for real steps, at most two hours.
    /// A missing step feed does not count as still being in bed.
    static func lieIn(
        minutesAfterUsualWake: Double?,
        windows: Windows,
        thresholds: Thresholds = Thresholds()
    ) -> (waiting: Bool, line: String) {
        guard let minutes = minutesAfterUsualWake, minutes >= 0, minutes <= thresholds.lieInMinutes else {
            return (false, "")
        }
        guard windows.feedFresh else {
            return (false, "Ausschlafen: die Schrittquelle fehlt, also wird aus 0 Schritten nicht geschlossen, dass noch gelegen wird. Nur Schatten.")
        }
        if windows.steps60 >= thresholds.wakeSteps60 || windows.steps15 >= thresholds.wakeSteps15 {
            return (false, "Ausschlafen: Schritte zeigen Aufstehen (\(windows.steps15)/15, \(windows.steps60)/60). Nur Schatten, das Aufwachfenster bleibt, wie es bestätigt wurde.")
        }
        return (true, "Ausschlafen: das Aufwachfenster würde noch warten, bis Schritte echtes Aufstehen zeigen, höchstens \(Int(thresholds.lieInMinutes)) Minuten. Nur Schatten, nichts geändert.")
    }

    static func minutesAfterUsualWake(now: Date, usualHour: Double?, calendar: Calendar) -> Double? {
        guard let usualHour else { return nil }
        let nowMinutes = Double(calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now))
        let delta = nowMinutes - usualHour * 60
        guard delta >= 0 else { return nil }
        return delta
    }

    static func usualWakeHour(sleepEnds: [Date], calendar: Calendar) -> Double? {
        let hours = sleepEnds.map {
            Double(calendar.component(.hour, from: $0)) + Double(calendar.component(.minute, from: $0)) / 60
        }
        guard hours.count >= 3 else { return nil }
        return hours.sorted()[hours.count / 2]
    }

    static func movementNote(status: Status, iob: Double?, thresholds: Thresholds = Thresholds()) -> String? {
        guard status == .active, let iob, iob >= thresholds.highIOB else { return nil }
        return String(format: "Bewegung bei IOB %.1f E. Rheos senkt nichts automatisch. Nur ein Hinweis.", iob)
    }

    static func shortNights(
        sleep: [RheosSleepInterval],
        now: Date,
        calendar: Calendar,
        shortHours: Double = 6,
        minimumNights: Int = 3
    ) -> String {
        let start = now.addingTimeInterval(-14 * 86400)
        var byNight: [Date: TimeInterval] = [:]
        for interval in sleep where interval.end > start && interval.end <= now && interval.end > interval.start {
            let night = calendar.startOfDay(for: interval.start)
            byNight[night, default: 0] += interval.end.timeIntervalSince(interval.start)
        }
        let short = byNight.values.filter { $0 < shortHours * 3600 }.count
        guard short >= minimumNights else { return "" }
        return "Mehrere kurze Nächte: \(short) von \(byNight.count) in 14 Tagen unter \(Int(shortHours)) Stunden. Nur beobachtet, nichts geändert."
    }
}

struct RheosActivitySnapshot: Codable, Equatable {
    var date: Date
    var steps5: Int
    var steps15: Int
    var steps30: Int
    var steps60: Int
    var feedFresh: Bool
    var status: String
    var heartRate: Double?
    var restingHeartRate: Double?
    var line: String
}

enum RheosActivityReport {
    static func snapshot(
        windows: RheosStepActivity.Windows,
        heartRate: Double?,
        restingHeartRate: Double?,
        sleep: [RheosSleepInterval],
        iob: Double?,
        now: Date,
        calendar: Calendar
    ) -> RheosActivitySnapshot {
        let classified = RheosStepActivity.status(
            windows: windows,
            heartRate: heartRate,
            restingHeartRate: restingHeartRate
        )
        let usual = RheosStepActivity.usualWakeHour(sleepEnds: sleep.map(\.end), calendar: calendar)
        let lieIn = RheosStepActivity.lieIn(
            minutesAfterUsualWake: RheosStepActivity.minutesAfterUsualWake(now: now, usualHour: usual, calendar: calendar),
            windows: windows
        )
        let nights = RheosStepActivity.shortNights(sleep: sleep, now: now, calendar: calendar)
        let movement = RheosStepActivity.movementNote(status: classified.status, iob: iob)
        let line = [classified.line, lieIn.line, nights, movement ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
        return RheosActivitySnapshot(
            date: now,
            steps5: windows.steps5,
            steps15: windows.steps15,
            steps30: windows.steps30,
            steps60: windows.steps60,
            feedFresh: windows.feedFresh,
            status: classified.status.rawValue,
            heartRate: heartRate,
            restingHeartRate: restingHeartRate,
            line: line
        )
    }
}
