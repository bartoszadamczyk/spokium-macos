import AppKit
import SwiftUI

@MainActor
final class RecordingOverlay {
    private var window: NSWindow?

    func show() {
        guard window == nil else { return }

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let hosting = NSHostingView(rootView: RecordingOverlayView())
        panel.contentView = hosting
        hosting.frame.size = hosting.intrinsicContentSize
        panel.setContentSize(hosting.intrinsicContentSize)

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - hosting.intrinsicContentSize.width / 2
            let y = screenFrame.midY - hosting.intrinsicContentSize.height / 2
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        window = panel
    }

    func hide() {
        window?.close()
        window = nil
    }
}

private struct RecordingOverlayView: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.red)
            Text("Recording")
                .font(.system(size: 18, weight: .medium))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
