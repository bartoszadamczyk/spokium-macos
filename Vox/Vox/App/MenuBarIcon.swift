import SwiftUI

struct MenuBarIcon: View {
    let recording: Bool

    var body: some View {
        if recording {
            Image(systemName: "waveform")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(.red))
        } else {
            Image(systemName: "waveform")
                .font(.system(size: 16, weight: .regular))
        }
    }
}
