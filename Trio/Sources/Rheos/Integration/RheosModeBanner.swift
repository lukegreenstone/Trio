import SwiftUI

/// Status on the home screen and the loop-status sheet.
/// Hidden while Rheos is Aus. Scharf can be returned to Schatten with one tap.
struct RheosModeBanner: View {
    @State private var mode = RheosModeStore.current

    var body: some View {
        Group {
            switch mode {
            case .aus:
                EmptyView()
            case .schatten:
                Text("Rheos Schatten · nur Vorschlag, keine Wirkung")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
            case .scharf:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Rheos Scharf · ISF, KH-Faktor und Basal im Band. SMB und UAM laufen normal.")
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Zurück zu Schatten") {
                        RheosModeStore.set(.schatten)
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
        .onAppear { mode = RheosModeStore.current }
        .onReceive(NotificationCenter.default.publisher(for: .rheosModeDidChange)) { _ in
            mode = RheosModeStore.current
        }
    }
}
