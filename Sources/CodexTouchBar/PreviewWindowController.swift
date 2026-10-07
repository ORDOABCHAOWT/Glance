import AppKit
import CodexTouchBarCore

@MainActor
final class PreviewWindowController: NSWindowController {
    private let dashboardView = DashboardStripView(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "")
    var onTaskRouteSelected: ((TaskRoute) -> Void)?
    var onRefreshRequested: (() -> Void)?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 164),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Glance 预览"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        dashboardView.onTaskSelected = { sessionID in
            _ = ThreadNavigator.open(sessionID: sessionID)
        }
        dashboardView.onTaskRouteSelected = { [weak self] route in
            if let handler = self?.onTaskRouteSelected { handler(route) } else { _ = ThreadNavigator.open(route: route) }
        }
        dashboardView.onRefreshRequested = { [weak self] in self?.onRefreshRequested?() }
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    func update(_ snapshot: DashboardSnapshot) {
        dashboardView.update(snapshot: snapshot)
        let taskCount = snapshot.tasks.count
        let provider = snapshot.provider == .claude ? "Claude" : "Codex"
        window?.title = "Glance · \(provider) 预览"
        var lines = ["\(provider) · 显示 \(min(6, taskCount))/\(taskCount) 个任务 · \(snapshot.quotas.isEmpty ? "用量不可用" : "剩余额度")"]
        var provenance: [String] = []
        if let source = snapshot.quotaSource { provenance.append("来源：\(source)") }
        if let sampled = snapshot.refreshedAt {
            provenance.append("数据时间：\(sampled.formatted(date: .abbreviated, time: .standard))")
        }
        if !provenance.isEmpty { lines.append(provenance.joined(separator: " · ")) }
        if let error = snapshot.refreshError ?? snapshot.quotaError { lines.append(error) }
        if let error = snapshot.taskError { lines.append(error) }
        statusLabel.stringValue = lines.joined(separator: "\n")
    }

    func show() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func renderPNG(to url: URL) throws {
        guard let view = window?.contentView else { throw PreviewError.missingContentView }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw PreviewError.renderFailed
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw PreviewError.renderFailed
        }
        try data.write(to: url, options: .atomic)
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor(srgbRed: 0.035, green: 0.042, blue: 0.060, alpha: 1).cgColor

        let touchBarBackdrop = NSView()
        touchBarBackdrop.translatesAutoresizingMaskIntoConstraints = false
        touchBarBackdrop.wantsLayer = true
        touchBarBackdrop.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.94).cgColor
        touchBarBackdrop.layer?.cornerRadius = 10
        touchBarBackdrop.layer?.borderWidth = 0.5
        touchBarBackdrop.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        dashboardView.translatesAutoresizingMaskIntoConstraints = false
        touchBarBackdrop.addSubview(dashboardView)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.72)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.maximumNumberOfLines = 5
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.cell?.wraps = true
        statusLabel.cell?.usesSingleLineMode = false

        let note = NSTextField(labelWithString: "点按任务切换窗口；Claude 额度可点按刷新。标记“旧”的数据可能已过期。")
        note.translatesAutoresizingMaskIntoConstraints = false
        note.textColor = NSColor.white.withAlphaComponent(0.44)
        note.font = .systemFont(ofSize: 10)

        content.addSubview(touchBarBackdrop)
        content.addSubview(statusLabel)
        content.addSubview(note)
        NSLayoutConstraint.activate([
            touchBarBackdrop.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            touchBarBackdrop.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            touchBarBackdrop.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            touchBarBackdrop.heightAnchor.constraint(equalToConstant: 40),
            dashboardView.leadingAnchor.constraint(equalTo: touchBarBackdrop.leadingAnchor, constant: 6),
            dashboardView.trailingAnchor.constraint(equalTo: touchBarBackdrop.trailingAnchor, constant: -6),
            dashboardView.centerYAnchor.constraint(equalTo: touchBarBackdrop.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: touchBarBackdrop.leadingAnchor, constant: 2),
            statusLabel.trailingAnchor.constraint(equalTo: touchBarBackdrop.trailingAnchor, constant: -2),
            statusLabel.topAnchor.constraint(equalTo: touchBarBackdrop.bottomAnchor, constant: 12),
            note.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
            note.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 5),
        ])
    }

    enum PreviewError: Error {
        case missingContentView
        case renderFailed
    }
}
