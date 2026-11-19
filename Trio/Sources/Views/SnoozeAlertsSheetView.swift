import SwiftUI
import Swinject

/// Shared "Snooze All" sheet. Used from Notifications settings and the home
/// glucose long-press. Wraps `TrioAlertManager.applySnooze` directly — no
/// router / module hop.
struct SnoozeAlertsSheetView: View {
    let resolver: Resolver
    @Binding var isPresented: Bool

    @State private var snoozeUntilDate: Date = .distantPast
    @State private var style: AlarmSilenceStyle = .vibrateOnly
    @State private var customMinutes: Int = 90

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    var body: some View {
        NavigationStack {
            List {
                if snoozeUntilDate > Date() {
                    Section {
                        HStack {
                            Image(systemName: "moon.zzz.fill").foregroundStyle(.tint)
                            Text(String(
                                format: String(localized: "Snoozed until %@"),
                                snoozeUntilDate.formatted(date: .omitted, time: .shortened)
                            ))
                                .font(.headline)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            endSnoozeAction
                        }
                        .listRowBackground(Color.chart)
                    } footer: {
                        HStack {
                            Image(systemName: "hand.draw.fill").foregroundStyle(.primary)
                            Text("Swipe left to end snooze.")
                        }
                    }
                }
                Section {
                    Picker("Silence", selection: $style) {
                        Text("Vibrate only").tag(AlarmSilenceStyle.vibrateOnly)
                        Text("Fully silent").tag(AlarmSilenceStyle.fullySilent)
                    }
                    .pickerStyle(.segmented)
                    ForEach(AlarmSilencePolicy.presetHours, id: \.self) { hours in
                        Button {
                            applySnooze(TimeInterval(hours * 3600))
                        } label: {
                            HStack {
                                Text("\(hours) h").foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.gray)
                                    .font(.footnote)
                            }
                        }
                    }
                    Stepper(value: $customMinutes, in: 15 ... AlarmSilencePolicy.maximumMinutes, step: 15) {
                        Text("Custom \(customMinutes) min")
                    }
                    Button("Snooze custom duration") {
                        applySnooze(TimeInterval(customMinutes * 60))
                    }
                } footer: {
                    Text(
                        "Vibrate only keeps the alarm on screen without a tone, and the phone vibrates when it can. Fully silent hides it. An urgent low under 55 mg/dL still sounds and vibrates. That cannot be turned off. Critical pump alerts such as an occlusion still sound too."
                    )
                }
                .listRowBackground(Color.chart)

                Section(footer: Text(
                    "These shorter choices use the silence selected above. The same choices are on the notification itself."
                )) {
                    ForEach(NotificationResponseAction.allCases, id: \.self) { action in
                        Button {
                            applySnooze(action.duration)
                        } label: {
                            HStack {
                                Text(action.localizedTitle).foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.gray)
                                    .font(.footnote)
                            }
                        }
                    }
                }.listRowBackground(Color.chart)
            }
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle("Snooze Alerts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { isPresented = false }
                }
            }
            .onAppear {
                snoozeUntilDate = UserDefaults.standard
                    .object(forKey: "UserNotificationsManager.snoozeUntilDate") as? Date ?? .distantPast
                if let stored = AlarmSilenceStore.current() {
                    style = stored
                }
            }
        }
    }

    private var endSnoozeAction: some View {
        Button(role: .destructive) {
            endSnooze()
        } label: {
            Label("End Snooze", systemImage: "alarm.waves.left.and.right.fill")
        }
        .tint(.red)
    }

    private func applySnooze(_ duration: TimeInterval) {
        let trioAlertManager = resolver.resolve(TrioAlertManager.self)
        let selected = style
        Task { @MainActor in
            AlarmSilenceStore.set(selected)
            await trioAlertManager?.applySnooze(for: duration)
            snoozeUntilDate = Date().addingTimeInterval(duration)
            isPresented = false
        }
    }

    private func endSnooze() {
        let trioAlertManager = resolver.resolve(TrioAlertManager.self)
        Task { @MainActor in
            AlarmSilenceStore.set(nil)
            await trioAlertManager?.applySnooze(for: 0)
            snoozeUntilDate = Date().addingTimeInterval(0)
        }
    }
}
