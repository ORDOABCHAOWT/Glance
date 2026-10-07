import AppKit
import CodexTouchBarCore
import QuartzCore

enum GlassAccent {
    case blue, purple, orange, green, red, teal, indigo, gray

    var color: NSColor {
        switch self {
        case .blue: return NSColor(srgbRed: 0.15, green: 0.55, blue: 1.00, alpha: 1)
        case .purple: return NSColor(srgbRed: 0.63, green: 0.37, blue: 1.00, alpha: 1)
        case .orange: return NSColor(srgbRed: 1.00, green: 0.57, blue: 0.18, alpha: 1)
        case .green: return NSColor(srgbRed: 0.20, green: 0.82, blue: 0.49, alpha: 1)
        case .red: return NSColor(srgbRed: 1.00, green: 0.30, blue: 0.36, alpha: 1)
        case .teal: return NSColor(srgbRed: 0.14, green: 0.78, blue: 0.76, alpha: 1)
        case .indigo: return NSColor(srgbRed: 0.36, green: 0.45, blue: 1.00, alpha: 1)
        case .gray: return NSColor(srgbRed: 0.50, green: 0.54, blue: 0.62, alpha: 1)
        }
    }

    static func forPhase(_ phase: TaskPhase) -> GlassAccent {
        switch phase {
        case .thinking: return .blue
        case .usingTool: return .purple
        case .waitingApproval, .waitingInput: return .orange
        case .completed: return .green
        case .failed: return .red
        case .idle: return .gray
        }
    }
}

enum VisualVariant: Int {
    case native = 1
    case frosted = 2
    case balanced = 3
    case contrast = 4
    case minimal = 5

    static var current: VisualVariant = .balanced

    var tintAlpha: CGFloat {
        switch self {
        case .native: return 0.16
        case .frosted: return 0.27
        case .balanced: return 0.22
        case .contrast: return 0.36
        case .minimal: return 0.12
        }
    }

    var borderAlpha: CGFloat {
        switch self {
        case .native: return 0.42
        case .frosted: return 0.58
        case .balanced: return 0.50
        case .contrast: return 0.78
        case .minimal: return 0.32
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .native: return 6
        case .frosted: return 10
        case .balanced: return 8
        case .contrast: return 5
        case .minimal: return 7
        }
    }

    var textSize: CGFloat {
        self == .contrast ? 12 : 11.5
    }
}

/// A real AppKit button, rather than a gesture recognizer on a passive view.
/// This is important on the physical Touch Bar, where AppKit owns hit testing.
final class GlassBlockView: NSButton {
    var onTap: (() -> Void)? {
        didSet {
            target = self
            action = #selector(handleTap)
            toolTip = onTap == nil ? nil : "打开此任务"
            setAccessibilityRole(onTap == nil ? .group : .button)
        }
    }

    private let tintLayer = CALayer()
    private let borderLayer = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        isBordered = false
        bezelStyle = .recessed
        focusRingType = .none
        refusesFirstResponder = true
        imagePosition = .noImage
        cell?.usesSingleLineMode = true
        cell?.wraps = false
        cell?.lineBreakMode = .byTruncatingTail
        cell?.truncatesLastVisibleLine = true
        cell?.alignment = .center
        // Trigger on touch-down so the physical Touch Bar's first tap is not
        // lost while AppKit waits for a mouse-up event.
        sendAction(on: [.leftMouseDown])
        layer?.cornerRadius = VisualVariant.current.cornerRadius
        layer?.masksToBounds = true
        layer?.addSublayer(tintLayer)

        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.strokeColor = NSColor.white.withAlphaComponent(VisualVariant.current.borderAlpha).cgColor
        borderLayer.lineWidth = 0.9
        layer?.addSublayer(borderLayer)

        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([heightAnchor.constraint(equalToConstant: 30)])
        set(text: "Codex · 连接中", accent: .blue)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func handleTap() { onTap?() }

    func set(text: String, accent: GlassAccent) {
        let dot = NSAttributedString(
            string: "● ",
            attributes: [
                .foregroundColor: accent.color.withAlphaComponent(0.98),
                .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            ]
        )
        let label = NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: VisualVariant.current.textSize, weight: .semibold),
            ]
        )
        let title = NSMutableAttributedString()
        title.append(dot)
        title.append(label)
        attributedTitle = title
        tintLayer.backgroundColor = accent.color.withAlphaComponent(VisualVariant.current.tintAlpha).cgColor
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Give the custom glass button the same clear press feedback as native buttons.
        tintLayer.opacity = isHighlighted ? 0.58 : 1
    }

    override func layout() {
        super.layout()
        tintLayer.frame = bounds
        borderLayer.frame = bounds
        borderLayer.path = CGPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: VisualVariant.current.cornerRadius - 0.5,
            cornerHeight: VisualVariant.current.cornerRadius - 0.5,
            transform: nil
        )
    }
}

/// Uses AppKit's native Touch Bar templates and button bezel.
final class MediaButtonView: NSButton {
    init(symbolName: String, label: String, target: AnyObject, action: Selector) {
        let image = Self.nativeImage(symbolName, label: label)
        super.init(frame: .zero)
        self.image = image
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        bezelStyle = .rounded
        isBordered = true
        focusRingType = .none
        refusesFirstResponder = true
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        toolTip = label
        setAccessibilityLabel(label)
        sendAction(on: [.leftMouseDown])
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 48),
            heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    required init?(coder: NSCoder) { nil }

    private static func nativeImage(_ symbol: String, label: String) -> NSImage {
        let names: [String: NSImage.Name] = [
            "backward.fill": NSImage.touchBarSkipToStartTemplateName,
            "forward.fill": NSImage.touchBarSkipToEndTemplateName,
            "play.fill": NSImage.touchBarPlayTemplateName,
            "pause.fill": NSImage.touchBarPauseTemplateName,
            "playpause.fill": NSImage.touchBarPlayPauseTemplateName,
        ]
        return names[symbol].flatMap { NSImage(named: $0) }
            ?? NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            ?? NSImage()
    }

    func setSymbol(_ symbolName: String, label: String) {
        image = Self.nativeImage(symbolName, label: label)
        toolTip = label
        setAccessibilityLabel(label)
    }
}

final class DashboardStripView: NSView {
    var onTaskSelected: ((String) -> Void)?
    var onTaskRouteSelected: ((TaskRoute) -> Void)?
    var onRefreshRequested: (() -> Void)?
    private let rootStack = NSStackView()
    private let leftMediaStack = NSStackView()
    private let statusStack = NSStackView()
    private let taskStack = NSStackView()
    private let quotaStack = NSStackView()
    private var snapshot = DashboardSnapshot()
    private var tickTimer: Timer?
    private var statusLayoutKey: [String]?
    private var taskBlocks: [GlassBlockView] = []
    var visibleTaskCount: Int { taskBlocks.count }
    private var quotaBlocks: [QuotaKind: GlassBlockView] = [:]
    private var playPauseButton: MediaButtonView?
    private var playbackStateKnown = false
    private var playbackIsPlaying = false
    private var playbackReadGeneration: UInt64 = 0
    private var pendingPlaybackState: Bool?
    private var pendingPlaybackDeadline = Date.distantPast
    private var lastMediaCommandAt = Date.distantPast
    private var musicStateObserver: NSObjectProtocol?
    private var musicStateIsAuthoritative = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        musicStateObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"),
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let self,
                  let state = notification.userInfo?["Player State"] as? String,
                  ["Playing", "Paused", "Stopped"].contains(state) else { return }
            self.musicStateIsAuthoritative = true
            self.playbackReadGeneration &+= 1
            self.pendingPlaybackState = nil
            self.applyPlaybackState(known: true, playing: state == "Playing")
        }
        translatesAutoresizingMaskIntoConstraints = false
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.orientation = .horizontal
        rootStack.alignment = .centerY
        rootStack.spacing = 6
        rootStack.distribution = .fill

        leftMediaStack.orientation = .horizontal
        leftMediaStack.alignment = .centerY
        leftMediaStack.spacing = 4
        leftMediaStack.setContentHuggingPriority(.required, for: .horizontal)
        leftMediaStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        let mediaGroupWidth = leftMediaStack.widthAnchor.constraint(equalToConstant: 152)
        statusStack.orientation = .horizontal
        statusStack.alignment = .centerY
        statusStack.spacing = 5
        statusStack.distribution = .fill
        statusStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        taskStack.orientation = .horizontal
        taskStack.alignment = .centerY
        taskStack.spacing = 5
        taskStack.distribution = .fillEqually
        taskStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        taskStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        quotaStack.orientation = .horizontal
        quotaStack.alignment = .centerY
        quotaStack.spacing = 5
        quotaStack.distribution = .fill
        quotaStack.setContentHuggingPriority(.required, for: .horizontal)
        quotaStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        let preferredQuotaWidth = quotaStack.widthAnchor.constraint(equalToConstant: 211)
        preferredQuotaWidth.priority = .defaultHigh
        // Use the native 13-inch Touch Bar width as a preferred size. The
        // constraint is intentionally high-but-breakable: on a narrower bar
        // AppKit must shrink the equal-fill status blocks instead of clipping
        // the rightmost one.
        let preferredStatusWidth = statusStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 520)
        preferredStatusWidth.priority = .defaultHigh

        rootStack.addArrangedSubview(leftMediaStack)
        rootStack.addArrangedSubview(statusStack)
        statusStack.addArrangedSubview(taskStack)
        statusStack.addArrangedSubview(quotaStack)
        addSubview(rootStack)

        let preferredStripWidth = widthAnchor.constraint(equalToConstant: 1000)
        preferredStripWidth.priority = .defaultLow
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            rootStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            mediaGroupWidth,
            preferredStripWidth,
            preferredStatusWidth,
            preferredQuotaWidth,
            heightAnchor.constraint(equalToConstant: 30),
        ])
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.rebuild()
            self?.refreshPlaybackState()
        }
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        // NSTouchBar sizes custom items from their intrinsic content size.
        // 1000 points fits the usable width of the 13-inch Touch Bar while
        // leaving AppKit enough room to compress task tabs on smaller bars.
        NSSize(width: 1000, height: 30)
    }

    func update(snapshot: DashboardSnapshot) {
        self.snapshot = snapshot
        rebuild()
    }

    private func rebuild() {
        // Keep the actual NSButton instances alive between timer ticks. Replacing
        // them every second can invalidate a touch that is already in progress.
        if leftMediaStack.arrangedSubviews.isEmpty {
            leftMediaStack.addArrangedSubview(MediaButtonView(
                symbolName: "backward.fill",
                label: "上一首",
                target: self,
                action: #selector(previousTrack)
            ))
            let playButton = MediaButtonView(
                symbolName: "playpause.fill",
                label: "播放或暂停",
                target: self,
                action: #selector(togglePlayPause)
            )
            playPauseButton = playButton
            leftMediaStack.addArrangedSubview(playButton)
            refreshPlaybackState()
            leftMediaStack.addArrangedSubview(MediaButtonView(
                symbolName: "forward.fill",
                label: "下一首",
                target: self,
                action: #selector(nextTrack)
            ))
        }

        let visibleTasks = Array(snapshot.tasks.prefix(6))
        let needsClaudeAccess = snapshot.provider == .claude && snapshot.taskError?.contains("辅助功能") == true
        let layoutKey = [snapshot.provider.rawValue] + (visibleTasks.isEmpty ? [needsClaudeAccess ? "__access_required__" : "__waiting__"] : visibleTasks.map { "\($0.route.provider.rawValue)|\($0.route.identifier)|\($0.route.category.rawValue)|\($0.route.requiresAccessibility)|\($0.route.supported)" })
        if statusLayoutKey != layoutKey {
            [taskStack, quotaStack].forEach { stack in
                stack.arrangedSubviews.forEach { view in
                    stack.removeArrangedSubview(view)
                    view.removeFromSuperview()
                }
            }
            taskBlocks = []
            quotaBlocks = [:]

            if visibleTasks.isEmpty {
                let block = GlassBlockView()
                // Same idle text for both providers. A missing Accessibility grant only
                // hides Claude's sidebar chats (Code sessions come from the registry), so
                // it is explained in the tooltip and the status menu, not on the bar.
                block.set(text: "等待任务", accent: .gray)
                block.toolTip = needsClaudeAccess ? snapshot.taskError : nil
                taskStack.addArrangedSubview(block)
            } else {
                for task in visibleTasks {
                    let block = GlassBlockView()
                    block.onTap = { [weak self] in
                        if let onTaskRouteSelected = self?.onTaskRouteSelected {
                            onTaskRouteSelected(task.route)
                        } else {
                            self?.onTaskSelected?(task.sessionID)
                        }
                    }
                    taskBlocks.append(block)
                    taskStack.addArrangedSubview(block)
                }
            }
            quotaBlocks[.fiveHour] = addQuotaBlock(kind: .fiveHour, accent: .teal)
            quotaBlocks[.weekly] = addQuotaBlock(kind: .weekly, accent: .indigo)
            statusLayoutKey = layoutKey
        }

        for (task, block) in zip(visibleTasks, taskBlocks) {
            let elapsed = Self.elapsedString(since: task.startedAt)
            let compactTitle = String(task.title.prefix(80))
            // Sidebar rows have no reliable start time, so they show the title
            // only. Registry-backed Claude Code tasks time like Codex tasks.
            let text = task.route.requiresAccessibility ? compactTitle : "\(compactTitle) · \(Self.phaseGlyph(task.phase)) \(elapsed)"
            block.set(text: text, accent: .forPhase(task.phase))
            block.toolTip = "\(task.title)\n\(task.workspaceName) · \(task.phase.shortLabel) · 点按切换"
            block.setAccessibilityLabel(block.toolTip)
        }

        let quotaByKind = Dictionary(uniqueKeysWithValues: snapshot.quotas.map { ($0.kind, $0) })
        updateQuotaBlock(quotaBlocks[.fiveHour], kind: .fiveHour, window: quotaByKind[.fiveHour], accent: .teal)
        updateQuotaBlock(quotaBlocks[.weekly], kind: .weekly, window: quotaByKind[.weekly], accent: .indigo)

    }

    @discardableResult
    private func addQuotaBlock(kind: QuotaKind, accent: GlassAccent) -> GlassBlockView {
        let block = GlassBlockView()
        let width = block.widthAnchor.constraint(equalToConstant: kind == .fiveHour ? 108 : 98)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([width])
        quotaStack.addArrangedSubview(block)
        updateQuotaBlock(block, kind: kind, window: nil, accent: accent)
        return block
    }

    private func updateQuotaBlock(_ block: GlassBlockView?, kind: QuotaKind, window: QuotaWindow?, accent: GlassAccent) {
        guard let block else { return }
        let prefix = kind == .fiveHour ? "5h" : "周"
        let isClaude = snapshot.provider == .claude
        let value = window.map { isClaude ? "\(prefix)余\($0.remainingPercent)%" : "\(prefix) \($0.remainingPercent)%" } ?? "\(prefix) …"
        let age = snapshot.refreshedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        let isStale = isClaude && (snapshot.refreshError != nil || snapshot.quotaSource == "Claude 桌面历史" || age > 120)
        let suffix = isStale && window != nil ? "·旧" : ""
        block.set(text: value + suffix, accent: accent)
        block.onTap = isClaude ? { [weak self] in self?.onRefreshRequested?() } : nil
        var details = ["\(isClaude ? "Claude" : "Codex") · \(kind.label)剩余额度"]
        if let source = snapshot.quotaSource { details.append("来源：\(source)") }
        if let sampled = snapshot.refreshedAt { details.append("数据时间：\(sampled.formatted(date: .abbreviated, time: .standard))") }
        if let reset = window?.resetsAt { details.append("重置：\(reset.formatted(date: .abbreviated, time: .shortened))") }
        if let error = snapshot.refreshError ?? snapshot.quotaError { details.append(error) }
        if isStale { details.append("旧数据，可能已过期") }
        if isClaude { details.append("点按刷新用量") }
        block.toolTip = details.joined(separator: "\n")
        block.setAccessibilityLabel(([value + suffix] + details).joined(separator: " · "))
    }

    @objc private func previousTrack() {
        guard beginMediaCommand() else { return }
        _ = MediaController.send(.previousTrack)
    }
    @objc private func togglePlayPause() {
        guard beginMediaCommand() else { return }
        let expectedState = !playbackIsPlaying
        beginPendingPlaybackState(expectedState)
        // CTBSendMediaCommand already uses the system MediaRemote path and
        // its controller fallback. Sending a second toggle after an ambiguous
        // return value can immediately undo a command that did reach the
        // player, leaving both playback and the icon in the original state.
        _ = MediaController.send(.togglePlayPause)
    }
    @objc private func nextTrack() {
        guard beginMediaCommand() else { return }
        _ = MediaController.send(.nextTrack)
    }

    private func beginMediaCommand() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastMediaCommandAt) >= 0.18 else { return false }
        lastMediaCommandAt = now
        return true
    }

    private func beginPendingPlaybackState(_ playing: Bool) {
        pendingPlaybackState = playing
        pendingPlaybackDeadline = Date().addingTimeInterval(3)
        applyPlaybackState(known: true, playing: playing)

        for delay in [0.35, 0.9, 1.8, 3.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshPlaybackState()
            }
        }
    }

    private func refreshPlaybackState() {
        if musicStateIsAuthoritative {
            if NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty {
                musicStateIsAuthoritative = false
            } else {
                return
            }
        }
        playbackReadGeneration &+= 1
        let generation = playbackReadGeneration
        MediaController.readPlaybackState { [weak self] known, playing in
            guard let self, generation == self.playbackReadGeneration else { return }
            if let expected = self.pendingPlaybackState {
                if known, playing == expected {
                    self.pendingPlaybackState = nil
                } else if Date() < self.pendingPlaybackDeadline {
                    return
                } else {
                    self.pendingPlaybackState = nil
                }
            }
            self.applyPlaybackState(known: known, playing: playing)
        }
    }

    private func applyPlaybackState(known: Bool, playing: Bool) {
        guard known || !playbackStateKnown else { return }
        playbackStateKnown = known
        playbackIsPlaying = known && playing
        let symbol = known ? (playing ? "pause.fill" : "play.fill") : "playpause.fill"
        let label = known
            ? (playing ? "暂停（正在播放）" : "播放（已暂停）")
            : "播放或暂停（状态不可用）"
        playPauseButton?.setSymbol(symbol, label: label)
    }

    private static func elapsedString(since start: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return String(format: "%d:%02d", seconds / 60, seconds % 60) }
        return String(format: "%dh%02d", seconds / 3600, (seconds % 3600) / 60)
    }

    private static func phaseGlyph(_ phase: TaskPhase) -> String {
        switch phase {
        case .thinking: return "思"
        case .usingTool: return "工"
        case .waitingApproval: return "批"
        case .waitingInput: return "等"
        case .completed: return "成"
        case .failed: return "错"
        case .idle: return "闲"
        }
    }
}
