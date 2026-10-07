import AppKit
import ApplicationServices
import CodexTouchBarCore

@MainActor
final class ClaudeSidebarMonitor {
    private struct Ref { let element: AXUIElement; let window: AXUIElement; let title: String; let app: NSRunningApplication }
    private var refs: [String: Ref] = [:]
    private(set) var permissionMessage: String?
    private(set) var diagnosticCounts = (windows: 0, sidebarNodes: 0, titledRows: 0)
    var isTrusted: Bool { AXIsProcessTrusted() }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        permissionMessage = isTrusted ? nil : "请在系统设置中允许 Glance 控制 Claude Desktop"
    }

    func scan() -> [TaskSnapshot] {
        diagnosticCounts = (0, 0, 0)
        guard isTrusted else { permissionMessage = "需要辅助功能权限才能读取 Claude 侧栏任务"; refs.removeAll(); return [] }
        permissionMessage = nil
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").first else { refs.removeAll(); return [] }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windows) == .success,
              let list = windows as? [AXUIElement] else { refs.removeAll(); return [] }
        diagnosticCounts.windows = list.count
        refs.removeAll()
        var result: [TaskSnapshot] = []
        for window in list.prefix(4) { result.append(contentsOf: sidebarRows(window, app: app)) }
        return Array(result.prefix(12))
    }

    @discardableResult
    func press(identifier: String) -> Bool {
        guard let ref = refs[identifier], isTrusted, (activeRow(ref.element)?.title ?? directTitle(ref.element)) == ref.title else { refs.removeValue(forKey: identifier); return false }
        ref.app.activate(options: [.activateIgnoringOtherApps])
        _ = AXUIElementPerformAction(ref.window, kAXRaiseAction as CFString)
        return AXUIElementPerformAction(ref.element, kAXPressAction as CFString) == .success
    }

    private func sidebarRows(_ window: AXUIElement, app: NSRunningApplication) -> [TaskSnapshot] {
        var found: [TaskSnapshot] = []
        var budget = 1000
        walk(window, depth: 0, inSidebar: false, budget: &budget) { element, inSidebar in
            if inSidebar { diagnosticCounts.sidebarNodes += 1 }
            guard inSidebar, let title = activeRow(element)?.title ?? directTitle(element), title.count <= 160, !title.contains("\n") else { return false }
            diagnosticCounts.titledRows += 1
            guard let phase = activeRow(element)?.phase ?? statusPhase(element, title: title), !excluded(title) else { return false }
            let id = "ax-\(CFHash(window))--\(CFHash(element))"
            refs[id] = Ref(element: element, window: window, title: title, app: app)
            let now = Date()
            found.append(TaskSnapshot(provider: .claude, sessionID: id, title: title, workspaceName: "Claude Desktop", category: .navigation, route: TaskRoute(provider: .claude, identifier: id, category: .navigation, requiresAccessibility: true), phase: phase, toolName: nil, startedAt: now, updatedAt: now))
            return true
        }
        return found
    }

    private func walk(_ element: AXUIElement, depth: Int, inSidebar: Bool, budget: inout Int, visit: (AXUIElement, Bool) -> Bool) {
        // Electron's web area can put sidebar rows more than 16 AX levels
        // below the native window; keep a node budget as the traversal bound.
        guard depth < 32, budget > 0 else { return }; budget -= 1
        var role: CFTypeRef?; var title: CFTypeRef?; var description: CFTypeRef?; var value: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        _ = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
        _ = AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &description)
        _ = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        let labels = [title as? String, description as? String, value as? String].compactMap { $0?.lowercased() }
        if !inSidebar && labels.contains(where: { ["primary pane", "chat messages"].contains($0) }) { return }
        let sidebar = inSidebar || labels.contains("sidebar")
        if visit(element, sidebar) { return }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let elements = children as? [AXUIElement] else { return }
        for child in elements.prefix(80) {
            var childRole: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &childRole)
            walk(child, depth: depth + 1, inSidebar: sidebar, budget: &budget, visit: visit)
        }
    }

    private func directTitle(_ element: AXUIElement) -> String? {
        var role: CFTypeRef?; _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        guard (role as? String) == "AXButton" else { return nil }
        var children: CFTypeRef?; guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success, let list = children as? [AXUIElement] else { return nil }
        for child in list.prefix(12) { var r: CFTypeRef?; var v: CFTypeRef?; _ = AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &r); _ = AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &v); if (r as? String) == "AXStaticText", let text = v as? String, !text.isEmpty { return text } }
        return nil
    }
    private func activeRow(_ element: AXUIElement) -> (title: String, phase: TaskPhase)? {
        var role: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        guard (role as? String) == "AXButton" else { return nil }
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let row = ClaudeTaskStatus.activeRow(value as? String) { return row }
        }
        return nil
    }
    private func statusPhase(_ element: AXUIElement, title taskTitle: String, depth: Int = 0) -> TaskPhase? {
        if depth == 0 {
            // Claude exposes running state on the row's accessible button label
            // even when its icon/group has no separate AX title or description.
            for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                   let phase = ClaudeTaskStatus.phase(forRowLabel: value as? String, title: taskTitle) { return phase }
            }
        }
        guard depth < 2 else { return nil }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return nil }
        for child in list.prefix(8) {
            var role: CFTypeRef?; var description: CFTypeRef?; var title: CFTypeRef?; var value: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &role)
            _ = AXUIElementCopyAttributeValue(child, kAXDescriptionAttribute as CFString, &description)
            _ = AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &title)
            _ = AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &value)
            let roleName = role as? String
            guard roleName == "AXImage" || roleName == "AXGroup" else { continue }
            for label in [description as? String, title as? String, value as? String].compactMap({ $0 }) {
                if let phase = ClaudeTaskStatus.phase(for: label) { return phase }
            }
            if let phase = statusPhase(child, title: taskTitle, depth: depth + 1) { return phase }
        }
        return nil
    }
    private func excluded(_ title: String) -> Bool { let value = title.lowercased(); return value.contains("more options") || value == "new" || value == "chat and cowork" || value == "code" || value == "sidebar" }
}
