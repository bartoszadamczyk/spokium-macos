import SwiftUI

struct MenuBarIcon: View {
    let recording: Bool

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "waveform")
                .font(.system(size: 16, weight: recording ? .semibold : .regular))
            #if DEBUG
            // Tells the dev build apart from an installed production copy in the menu bar.
            Text("DEV")
                .font(.system(size: 8, weight: .bold))
            #endif
        }
        .foregroundStyle(recording ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
    }
}
