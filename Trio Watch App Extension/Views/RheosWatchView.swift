import SwiftUI

/// Rheos on the watch. Quick actions and suggestion buttons only store a note
/// on the phone. Insulin still goes through the existing bolus screens.
struct RheosWatchView: View {
    var state: WatchState
    @State private var style = "vibrateOnly"
    @State private var customMinutes = 90
    @State private var reply = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(state.rheosMode.capitalized)
                    .font(.headline)
                Text(state.currentGlucose)
                    .font(.title2)
                Text("Urgent low under 55 mg/dL still sounds and vibrates. This page does not bolus.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Button(style == "vibrateOnly" ? "Vibrate only ✓" : "Vibrate only") {
                    style = "vibrateOnly"
                }
                Button(style == "fullySilent" ? "Fully silent ✓" : "Fully silent") {
                    style = "fullySilent"
                }
                HStack {
                    ForEach([1, 2, 4, 6], id: \.self) { hours in
                        Button("\(hours)h") {
                            state.sendAlarmSilence(minutes: hours * 60, style: style)
                        }
                    }
                }
                Stepper(value: $customMinutes, in: 15 ... 720, step: 15) {
                    Text("\(customMinutes) min")
                        .font(.caption2)
                }
                Button("Snooze custom") {
                    state.sendAlarmSilence(minutes: customMinutes, style: style)
                }
                Button("End silence") {
                    state.sendAlarmSilence(minutes: 0, style: style)
                }
                if let until = state.silenceUntil, until > Date() {
                    Text("Until \(until.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                }

                Text("Notes only")
                    .font(.caption)
                    .padding(.top, 4)
                Button("Showtime") { state.sendRheosConfirm(kind: "showtime", note: "Showtime") }
                Button("Sport") { state.sendRheosConfirm(kind: "sport", note: "Sport") }
                Button("Snack") { state.sendRheosConfirm(kind: "snack", note: "small carbs, observe") }
                Button("Standardfrühstück") { state.sendRheosConfirm(kind: "meal", note: "Standardfrühstück") }
                Button("Alkohol") { state.sendRheosConfirm(kind: "alcohol", note: "Alkohol") }
                Button("Stress") { state.sendRheosConfirm(kind: "stress", note: "Stress") }

                ForEach(state.rheosSuggestions) { suggestion in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(suggestion.title).font(.caption).bold()
                        Text(suggestion.note).font(.caption2).lineLimit(4)
                        HStack {
                            Button("Confirm") {
                                state.sendRheosConfirm(
                                    kind: suggestion.kind,
                                    note: suggestion.note,
                                    suggestionID: suggestion.id
                                )
                            }
                            Button("Reject") {
                                state.sendRheosReject(
                                    kind: suggestion.kind,
                                    note: suggestion.note,
                                    suggestionID: suggestion.id
                                )
                            }
                        }
                    }
                }

                TextField("Kurz an die KI", text: $reply)
                Text("Diktat über die Tastatur.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Senden") {
                    state.sendRheosChat(reply)
                    reply = ""
                }
                .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if !state.rheosChatReply.isEmpty {
                    Text(state.rheosChatReply)
                        .font(.caption2)
                }
            }
            .padding(.horizontal, 4)
        }
    }
}
