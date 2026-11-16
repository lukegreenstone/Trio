import SwiftUI

/// Shows the phone's Handy-frei note. This view has no pump or sensor commands.
struct HandyFreiWatchView: View {
    @Bindable var state: WatchState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Handy-frei")
                    .font(.headline)
                Text(state.handyFreiStatus)
                    .font(.footnote)
                Text("Erlaubt wären nur Status, Glukose, Verlauf, temporäres Basal, Abbruch davon und ein Bolus in den bestehenden Grenzen. Patch und Sensor werden von hier nicht beendet.")
                    .font(.footnote)
            }
            .padding()
        }
    }
}
