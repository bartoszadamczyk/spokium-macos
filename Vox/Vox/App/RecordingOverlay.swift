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

    func show(mode: OverlayMode, controller: RecordingController) {
        if let hostingView {
            hostingView.rootView = OverlayContentView(mode: mode, controller: controller)
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

        let hosting = NSHostingView(rootView: OverlayContentView(mode: mode, controller: controller))
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
    let controller: RecordingController

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                switch mode {
                case .recording:
                    LevelMic(level: controller.inputLevel)
                    Text("Recording")
                        .font(.system(size: 18, weight: .medium))
                case .transcribing:
                    ProgressView()
                        .controlSize(.small)
                    Text("Transcribing…")
                        .font(.system(size: 18, weight: .medium))
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .fixedSize()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct LevelMic: View {
    let level: Float

    private var normalized: CGFloat {
        max(0, min(1, CGFloat(level) * 8))
    }

    var body: some View {
        ZStack {
            Image(systemName: "mic.fill")
                .foregroundStyle(.secondary.opacity(0.5))
            Image(systemName: "mic.fill")
                .foregroundStyle(.red)
                .mask(alignment: .bottom) {
                    GeometryReader { geo in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            Rectangle()
                                .frame(height: geo.size.height * normalized)
                        }
                    }
                }
        }
        .font(.system(size: 20, weight: .medium))
        .animation(.linear(duration: 0.05), value: normalized)
    }
}
