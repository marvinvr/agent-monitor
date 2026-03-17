import AppKit

extension AppDelegate {
    func ensureAccessibilityReady(
        for app: NSRunningApplication,
        allowFallbackActivation: Bool
    ) -> Bool {
        guard AXIsProcessTrusted() else {
            let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            if allowFallbackActivation {
                app.activate()
            }
            return false
        }

        return true
    }

    func axWindows(of app: AXUIElement) -> [AXUIElement] {
        var windowsRef: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return [] }
        return windows
    }

    func axChildren(of element: AXUIElement, attribute: String = kAXChildrenAttribute as String) -> [AXUIElement] {
        var childrenRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return [] }
        return children
    }

    func axElement(of element: AXUIElement, attribute: String) -> AXUIElement? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref else { return nil }
        return unsafeBitCast(ref, to: AXUIElement.self)
    }

    func axTitle(of element: AXUIElement) -> String {
        var ref: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &ref)
        return ref as? String ?? ""
    }

    func axDocument(of element: AXUIElement) -> String? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXDocumentAttribute as CFString, &ref) == .success,
              let raw = ref as? String else { return nil }
        if raw.hasPrefix("file://"), let url = URL(string: raw) {
            return url.path
        }
        return raw
    }

    func axWindowNumber(of element: AXUIElement) -> Int? {
        var ref: AnyObject?
        let key = "AXWindowNumber" as CFString
        guard AXUIElementCopyAttributeValue(element, key, &ref) == .success else { return nil }
        if let num = ref as? NSNumber { return num.intValue }
        return nil
    }

    func windowsSortedByCreation(_ windows: [AXUIElement]) -> [AXUIElement] {
        struct WindowMeta {
            let element: AXUIElement
            let number: Int?
            let x: CGFloat
            let y: CGFloat
            let title: String
        }

        var positioned: [WindowMeta] = []
        for window in windows {
            var posRef: AnyObject?
            var pos = CGPoint.zero
            if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success {
                AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
            }
            positioned.append(WindowMeta(
                element: window,
                number: axWindowNumber(of: window),
                x: pos.x,
                y: pos.y,
                title: axTitle(of: window)
            ))
        }

        if positioned.allSatisfy({ $0.number == nil }) {
            return positioned.map(\.element)
        }

        positioned.sort { lhs, rhs in
            switch (lhs.number, rhs.number) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                if lhs.y != rhs.y { return lhs.y < rhs.y }
                if lhs.x != rhs.x { return lhs.x < rhs.x }
                return lhs.title < rhs.title
            }
        }
        return positioned.map(\.element)
    }

    func axStaticTexts(in root: AXUIElement) -> [String] {
        var queue = [root]
        var index = 0
        var texts: [String] = []

        while index < queue.count {
            let element = queue[index]
            index += 1

            var roleRef: AnyObject?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
            let role = roleRef as? String ?? ""

            if role == kAXStaticTextRole as String {
                let text = axTitle(of: element).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    texts.append(text)
                }
            }

            queue.append(contentsOf: axChildren(of: element))
            queue.append(contentsOf: axChildren(of: element, attribute: kAXContentsAttribute as String))
        }

        return texts
    }

    func remoteTitleNeedles(for session: MonitorSession) -> [String] {
        guard let remoteHost = session.remoteHost, !remoteHost.isEmpty else { return [] }
        let rawHost = remoteHost.split(separator: "@").last.map(String.init) ?? remoteHost
        let hostWithoutPort: String
        if rawHost.hasPrefix("["),
           let closingBracket = rawHost.firstIndex(of: "]") {
            hostWithoutPort = String(rawHost[rawHost.index(after: rawHost.startIndex)..<closingBracket])
        } else {
            hostWithoutPort = rawHost.split(separator: ":", maxSplits: 1).first.map(String.init) ?? rawHost
        }
        let shortHost = hostWithoutPort.split(separator: ".", maxSplits: 1).first.map(String.init) ?? hostWithoutPort
        return Array(Set([hostWithoutPort, shortHost]).filter { !$0.isEmpty })
    }
}
