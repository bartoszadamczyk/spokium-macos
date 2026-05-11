import AppKit
import SwiftUI

enum OverlayMode {
    case recording
    case transcribing
}

@MainActor
final class RecordingOverlay {
    private var window: NSWindow?
    private var hostingView: NSHostingView<OverlayContentView>?

    func show(mode: OverlayMode) {
        if let hostingView {
            hostingView.rootView = OverlayContentView(mode: mode)
            DispatchQueue.main.async { [weak self] in
                self?.reposition()
            }
            return
        }

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

        let hosting = NSHostingView(rootView: OverlayContentView(mode: mode))
        panel.contentView = hosting
        hostingView = hosting

        hosting.frame.size = hosting.intrinsicContentSize
        panel.setContentSize(hosting.intrinsicContentSize)

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - hosting.intrinsicContentSize.width / 2
            let y = screenFrame.minY + screenFrame.height / 3 - hosting.intrinsicContentSize.height / 2
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        window = panel
    }

    func hide() {
        window?.close()
        window = nil
        hostingView = nil
    }

    private func reposition() {
        guard let window, let hostingView else { return }
        let size = hostingView.intrinsicContentSize
        window.setContentSize(size)
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - size.width / 2
            let y = screenFrame.minY + screenFrame.height / 3 - size.height / 2
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }
}

private struct OverlayContentView: View {
    let mode: OverlayMode

    var body: some View {
        HStack(spacing: 10) {
            switch mode {
            case .recording:
                Image(systemName: "mic.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.red)
                Text("Recording")
                    .font(.system(size: 18, weight: .medium))
            case .transcribing:
                ProgressView()
                    .controlSize(.small)
                Text("Transcribing…")
                    .font(.system(size: 18, weight: .medium))
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .fixedSize()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
