import AppKit

func safeMonospacedFont(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
    if let font = NSFont.monospacedSystemFont(ofSize: size, weight: weight) as NSFont? {
        return font
    }
    return NSFont.systemFont(ofSize: size, weight: weight)
}

// MARK: - Session View

class ClaudeSessionView: NSView {
    let session: ClaudeSession
    var animFrame: Int = 0
    var sprites: SpriteCache!
    private var trackingArea: NSTrackingArea?
    private var hovered = false
    var onClick: ((ClaudeSession) -> Void)?

    init(session: ClaudeSession, frame: NSRect, sprites: SpriteCache) {
        self.session = session
        self.sprites = sprites
        super.init(frame: frame)
        toolTip = session.tooltipText
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        trackingArea.map { removeTrackingArea($0) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onClick?(session) }
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let tileBounds = bounds.insetBy(dx: 4, dy: 3)

        if hovered {
            NSColor(white: 1.0, alpha: 0.12).setFill()
            NSBezierPath(roundedRect: tileBounds, xRadius: 5, yRadius: 5).fill()
        }

        let subtitleText = session.subtitleText
        let labelAreaHeight: CGFloat = subtitleText != nil ? 32 : 20
        let spriteTopInset: CGFloat = 4
        let frames = sprites.frames(for: session.tool, state: session.state)
        let img: NSImage
        if session.tool == .terminal {
            img = frames[0]
        } else {
            switch session.state {
            case .working:
                img = frames[animFrame % frames.count]
            case .done:
                img = frames[(animFrame / 4) % frames.count]
            case .idle:
                img = frames[(animFrame / 6) % frames.count]
            }
        }

        let x = tileBounds.minX + (tileBounds.width - img.size.width) / 2
        let spriteAreaHeight = tileBounds.height - labelAreaHeight - spriteTopInset
        let y = tileBounds.minY + labelAreaHeight + max((spriteAreaHeight - img.size.height) / 2, 0)
        NSGraphicsContext.current?.imageInterpolation = .none
        img.draw(in: NSRect(x: x, y: y, width: img.size.width, height: img.size.height),
                 from: .zero, operation: .sourceOver, fraction: 1.0)

        // Name label with tool badge
        let name = session.displayLabelText
        let color: NSColor
        if session.tool == .terminal {
            switch session.state {
            case .working:
                color = NSColor(red: 0.48, green: 0.76, blue: 1.0, alpha: 1.0)
            case .done, .idle:
                color = NSColor(white: 0.62, alpha: 0.9)
            }
        } else {
            switch session.state {
            case .working: color = NSColor(red: 0.4, green: 0.9, blue: 0.5, alpha: 1.0)
            case .done: color = NSColor(red: 0.3, green: 0.85, blue: 1.0, alpha: 1.0)
            case .idle: color = NSColor(white: 0.6, alpha: 0.9)
            }
        }
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: safeMonospacedFont(ofSize: 12, weight: .bold),
            .foregroundColor: color
        ]
        let label = NSMutableAttributedString(string: name, attributes: nameAttrs)
        let sz = label.size()
        let nameY = tileBounds.minY + (subtitleText != nil ? 16 : 2)
        label.draw(at: NSPoint(x: tileBounds.minX + (tileBounds.width - sz.width) / 2, y: nameY))

        // Subtitle (folder)
        if let subtitle = subtitleText {
            let folderAttrs: [NSAttributedString.Key: Any] = [
                .font: safeMonospacedFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor(white: 0.55, alpha: 0.9)
            ]
            let folderStr = NSAttributedString(string: subtitle, attributes: folderAttrs)
            let fsz = folderStr.size()
            folderStr.draw(at: NSPoint(x: tileBounds.minX + (tileBounds.width - fsz.width) / 2, y: tileBounds.minY + 2))
        }

        // Activity dots for working
        if session.state == .working && session.tool != .terminal {
            let dots = (animFrame % 3) + 1
            NSColor(red: 0.4, green: 0.9, blue: 0.5, alpha: 0.9).setFill()
            let totalW = CGFloat(dots) * 4 + CGFloat(dots - 1) * 3
            let sx = tileBounds.minX + (tileBounds.width - totalW) / 2
            let dotsY = tileBounds.maxY - spriteTopInset - 10
            for i in 0..<dots {
                NSBezierPath(ovalIn: NSRect(x: sx + CGFloat(i) * 7, y: dotsY, width: 4, height: 4)).fill()
            }
        }

        // Conversation matching status marker, intentionally subtle.
        if session.conversationMatchStatus == .unmatched {
            NSColor(red: 0.95, green: 0.45, blue: 0.3, alpha: hovered ? 0.8 : 0.45).setFill()
            NSBezierPath(ovalIn: NSRect(x: tileBounds.maxX - 9, y: tileBounds.maxY - 9, width: 5, height: 5)).fill()
        } else if session.conversationMatchStatus == .guessed {
            NSColor(red: 0.95, green: 0.8, blue: 0.3, alpha: hovered ? 0.8 : 0.45).setFill()
            NSBezierPath(ovalIn: NSRect(x: tileBounds.maxX - 9, y: tileBounds.maxY - 9, width: 5, height: 5)).fill()
        }
    }
}

// MARK: - Draggable Title Bar

class TitleBarView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

class LoadingPlaceholderView: NSView {
    var animFrame: Int = 0

    override func draw(_ dirtyRect: NSRect) {
        let dots = String(repeating: ".", count: (animFrame % 3) + 1)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: safeMonospacedFont(ofSize: 22, weight: .bold),
            .foregroundColor: NSColor(white: 0.65, alpha: 0.95)
        ]
        let label = NSAttributedString(string: dots, attributes: attrs)
        let size = label.size()
        label.draw(at: NSPoint(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2 + 2
        ))
    }
}

// MARK: - Panel Content View

class CloseButtonView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        NSApp.terminate(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        let circle = bounds.insetBy(dx: 1, dy: 1)
        NSColor(red: 0.9, green: 0.3, blue: 0.3, alpha: 1.0).setFill()
        NSBezierPath(ovalIn: circle).fill()

        NSColor(white: 0.0, alpha: 0.8).setStroke()
        let inset: CGFloat = 4.5
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.move(to: NSPoint(x: inset, y: inset))
        path.line(to: NSPoint(x: bounds.width - inset, y: bounds.height - inset))
        path.move(to: NSPoint(x: bounds.width - inset, y: inset))
        path.line(to: NSPoint(x: inset, y: bounds.height - inset))
        path.stroke()
    }
}

class MonitorContentView: NSView {
    let closeButton = CloseButtonView(frame: NSRect(x: 6, y: 0, width: 16, height: 16))
    let titleBar = TitleBarView()
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        closeButton.alphaValue = 0
        addSubview(titleBar)
        addSubview(closeButton)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        trackingArea.map { removeTrackingArea($0) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            self.closeButton.animator().alphaValue = 1
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            self.closeButton.animator().alphaValue = 0
        }
    }

    override func layout() {
        super.layout()
        closeButton.frame.origin = NSPoint(x: 6, y: bounds.height - 22)
        titleBar.frame = NSRect(x: 0, y: bounds.height - 28, width: bounds.width, height: 28)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).addClip()
        NSColor(white: 0.08, alpha: 0.92).setFill()
        bounds.fill()
        NSColor(white: 0.25, alpha: 0.4).setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10).stroke()
    }
}

// MARK: - Monitor Panel

class MonitorPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            setFrameOrigin(NSPoint(x: f.maxX - 140, y: f.maxY - 120))
        }
    }
}
