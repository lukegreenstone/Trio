import SwiftUI
import UserNotifications
import WatchKit

@main struct TrioWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @WKApplicationDelegateAdaptor(HandyFreiRefreshDelegate.self) private var refreshDelegate

    init() {
        WatchNotificationHandler.shared.configure()
    }

    var body: some Scene {
        WindowGroup {
            TrioMainWatchView()
        }
        .onChange(of: scenePhase) { _, newScenePhase in
            if newScenePhase == .background {
                Task {
                    await WatchLogger.shared.flushPersistedLogs()
                }
            }
        }
    }
}

/// Wakes a running Handy-frei session if watchOS suspended the app. A workout is what
/// actually keeps the loop alive; this refresh only gets a short chance to start it again.
final class HandyFreiRefreshDelegate: NSObject, WKApplicationDelegate {
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if task is WKApplicationRefreshBackgroundTask {
                HandyFreiSession.shared.wakeFromBackground()
            }
            task.setTaskCompletedWithSnapshot(false)
        }
    }
}
