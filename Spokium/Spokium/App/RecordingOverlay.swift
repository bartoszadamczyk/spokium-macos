import AppKit
import SwiftUI

enum OverlayMode: Equatable {
    case recording
    case transcribing
    case pasted
    case copied
    case empty
    case failed(String)
}

@MainActor
final class RecordingOverlay {
    private var window: NSWindow?
    private var hostingView: NSHostingView<OverlayContentView>?
    private var feedbackHideTask: Task<Void, Never>?

    func show(mode: OverlayMode, controller: RecordingController) {
        feedbackHideTask?.cancel()
        feedbackHideTask = nil
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
        feedbackHideTask?.cancel()
        feedbackHideTask = nil
        window?.close()
        window = nil
        hostingView = nil
    }

    func showFeedback(_ feedback: CompletionFeedback, controller: RecordingController) {
        let mode: OverlayMode
        let duration: Int
        switch feedback {
        case .pasted:
            mode = .pasted
            duration = 1800
        case .copied:
            mode = .copied
            duration = 1800
        case .empty:
            mode = .empty
            duration = 1800
        case .failed(let message):
            mode = .failed(message)
            duration = 2400
        }
        show(mode: mode, controller: controller)
        feedbackHideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(duration))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
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
                case .pasted:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 20, weight: .medium))
                    Text("Pasted")
                        .font(.system(size: 18, weight: .medium))
                case .copied:
                    Image(systemName: "doc.on.clipboard.fill")
                        .foregroundStyle(.blue)
                        .font(.system(size: 20, weight: .medium))
                    Text("Copied to clipboard")
                        .font(.system(size: 18, weight: .medium))
                case .empty:
                    Image(systemName: "mic.slash.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 20, weight: .medium))
                    Text("No speech detected")
                        .font(.system(size: 18, weight: .medium))
                case .failed(let message):
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 20, weight: .medium))
                    Text(message)
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
        guard level > 0 else { return 0 }
        let db = 20 * log10(Double(level))
        let minDb = -50.0
        let maxDb = -10.0
        let clamped = max(minDb, min(maxDb, db))
        return CGFloat((clamped - minDb) / (maxDb - minDb))
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
