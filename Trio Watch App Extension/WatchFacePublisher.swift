import Foundation
import WidgetKit

/// Writes the latest glucose into the Trio app group and asks the existing
/// complication to reload, inside WidgetKit's budget.
enum WatchFacePublisher {
    static func publish(glucose: String, trend: String, readingDate: Date, rheosMode: String, now: Date = Date()) {
        guard let defaults = WatchFaceStore.sharedDefaults() else { return }
        let reading = WatchFaceReading(
            glucose: glucose,
            trend: trend,
            readingDate: readingDate,
            rheosMode: rheosMode
        )
        let previous = WatchFaceStore.load(defaults: defaults)
        WatchFaceStore.save(reading, defaults: defaults)
        let changed = previous?.glucose != reading.glucose
            || previous?.trend != reading.trend
            || previous?.rheosMode != reading.rheosMode
        guard WatchFaceBudget.shouldReload(
            lastReload: WatchFaceStore.lastReload(defaults: defaults),
            contentChanged: changed,
            now: now
        ) else { return }
        WatchFaceStore.markReloaded(now, defaults: defaults)
        WidgetCenter.shared.reloadTimelines(ofKind: WatchFaceBudget.kind)
    }
}
