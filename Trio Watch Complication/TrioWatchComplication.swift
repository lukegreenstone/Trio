import SwiftUI
import WidgetKit

struct TrioWatchComplicationEntry: TimelineEntry {
    let date: Date
    let reading: WatchFaceReading?
}

struct TrioWatchComplicationProvider: TimelineProvider {
    func placeholder(in _: Context) -> TrioWatchComplicationEntry {
        TrioWatchComplicationEntry(date: Date(), reading: Self.sample)
    }

    func getSnapshot(in _: Context, completion: @escaping (TrioWatchComplicationEntry) -> Void) {
        let reading = WatchFaceStore.sharedDefaults().flatMap { WatchFaceStore.load(defaults: $0) } ?? Self.sample
        completion(TrioWatchComplicationEntry(date: Date(), reading: reading))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<TrioWatchComplicationEntry>) -> Void) {
        let now = Date()
        let reading = WatchFaceStore.sharedDefaults().flatMap { WatchFaceStore.load(defaults: $0) }
        let entries = WatchFaceBudget.entryDates(from: now).map {
            TrioWatchComplicationEntry(date: $0, reading: reading)
        }
        let next = now.addingTimeInterval(TimeInterval(WatchFaceBudget.timelineSteps) * WatchFaceBudget.timelineStep)
        completion(Timeline(entries: entries, policy: .after(next)))
    }

    private static let sample = WatchFaceReading(
        glucose: "142",
        trend: "Flat",
        readingDate: Date(),
        rheosMode: "aus"
    )
}

struct TrioWatchComplicationEntryView: View {
    @Environment(\.widgetFamily) private var widgetFamily
    var entry: TrioWatchComplicationEntry

    var body: some View {
        switch widgetFamily {
        case .accessoryCircular:
            TrioCircularFace(entry: entry)
        case .accessoryRectangular:
            TrioRectangularFace(entry: entry)
        case .accessoryInline:
            TrioInlineFace(entry: entry)
        #if os(watchOS)
            case .accessoryCorner:
                TrioCornerFace(entry: entry)
        #endif
        default:
            TrioRectangularFace(entry: entry)
        }
    }
}

struct TrioCircularFace: View {
    var entry: TrioWatchComplicationEntry

    var body: some View {
        VStack(spacing: 0) {
            Text(entry.reading?.displayGlucose ?? "--")
                .font(.system(.title3, design: .rounded))
                .minimumScaleFactor(0.5)
            Text(detail)
                .font(.system(size: 10))
                .minimumScaleFactor(0.6)
        }
        .foregroundStyle(stale ? .secondary : .primary)
        .widgetAccentable()
        .widgetBackground(backgroundView: Color.clear)
    }

    private var detail: String {
        guard let reading = entry.reading else { return "Trio" }
        return "\(reading.trendArrow) \(reading.modeLabel)"
    }

    private var stale: Bool {
        entry.reading?.isStale(at: entry.date) ?? true
    }
}

struct TrioRectangularFace: View {
    var entry: TrioWatchComplicationEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.reading?.displayGlucose ?? "--")
                    .font(.system(.title2, design: .rounded))
                Text(entry.reading?.trendArrow ?? "·")
                Spacer(minLength: 4)
                Text(age)
                    .font(.caption2)
            }
            Text(entry.reading?.modeLabel ?? "Aus")
                .font(.caption2)
        }
        .foregroundStyle(stale ? .secondary : .primary)
        .widgetAccentable()
        .widgetBackground(backgroundView: Color.clear)
    }

    private var age: String {
        entry.reading?.ageLabel(at: entry.date) ?? "--"
    }

    private var stale: Bool {
        entry.reading?.isStale(at: entry.date) ?? true
    }
}

struct TrioInlineFace: View {
    var entry: TrioWatchComplicationEntry

    var body: some View {
        Text(line)
            .widgetAccentable()
            .widgetBackground(backgroundView: Color.clear)
    }

    private var line: String {
        guard let reading = entry.reading else { return "Trio --" }
        return "\(reading.displayGlucose) \(reading.trendArrow) \(reading.ageLabel(at: entry.date)) \(reading.modeLabel)"
    }
}

#if os(watchOS)
    struct TrioCornerFace: View {
        var entry: TrioWatchComplicationEntry

        var body: some View {
            Text(entry.reading?.displayGlucose ?? "--")
                .font(.system(.title3, design: .rounded))
                .minimumScaleFactor(0.5)
                .widgetCurvesContent()
                .widgetLabel {
                    Text(label)
                }
                .foregroundStyle(stale ? .secondary : .primary)
                .widgetAccentable()
                .widgetBackground(backgroundView: Color.clear)
        }

        private var label: String {
            guard let reading = entry.reading else { return "Trio" }
            return "\(reading.trendArrow) \(reading.ageLabel(at: entry.date)) \(reading.modeLabel)"
        }

        private var stale: Bool {
            entry.reading?.isStale(at: entry.date) ?? true
        }
    }
#endif

@main struct TrioWatchComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WatchFaceBudget.kind, provider: TrioWatchComplicationProvider()) { entry in
            TrioWatchComplicationEntryView(entry: entry)
        }
        .configurationDisplayName("Trio Glucose")
        .description("Glucose, trend, reading age, and Rheos mode on the watch face and in the Smart Stack.")
        .supportedFamilies(supportedFamilies)
    }

    private var supportedFamilies: [WidgetFamily] {
        #if os(watchOS)
            return [.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline]
        #else
            return [.accessoryCircular, .accessoryRectangular, .accessoryInline]
        #endif
    }
}

extension View {
    func widgetBackground(backgroundView: some View) -> some View {
        if #available(watchOS 10.0, iOSApplicationExtension 17.0, iOS 17.0, *) {
            return containerBackground(for: .widget) {
                backgroundView
            }
        } else {
            return background(backgroundView)
        }
    }
}
