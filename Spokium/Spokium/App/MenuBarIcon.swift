import SwiftUI

struct MenuBarIcon: View {
    let recording: Bool

    var body: some View {
        Image(systemName: "waveform")
            .font(.system(size: 16, weight: recording ? .semibold : .regular))
            .foregroundStyle(recording ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
    }
}
