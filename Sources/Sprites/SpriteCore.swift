import AppKit

// MARK: - Color Palette

struct Clr {
    let r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat
    static let O = Clr(r: 0.85, g: 0.45, b: 0.22, a: 1)
    static let W = Clr(r: 0.85, g: 0.45, b: 0.22, a: 1)
    static let S = Clr(r: 0.70, g: 0.33, b: 0.13, a: 1)
    static let E = Clr(r: 0.12, g: 0.13, b: 0.16, a: 1)
    static let T = Clr(r: 0.47, g: 0.89, b: 0.66, a: 1)
    static let t = Clr(r: 0.24, g: 0.56, b: 0.42, a: 1)
    static let X = Clr(r: 0.99, g: 0.88, b: 0.42, a: 1)
    static let N = Clr(r: 0.06, g: 0.09, b: 0.13, a: 1)
    static let C = Clr(r: 0.91, g: 0.95, b: 1.00, a: 1)
    static let G = Clr(r: 0.74, g: 0.79, b: 0.86, a: 1)
    static let g = Clr(r: 0.43, g: 0.48, b: 0.56, a: 1)
    static let M = Clr(r: 0.58, g: 0.63, b: 0.72, a: 1)
    static let A = Clr(r: 0.50, g: 0.84, b: 0.76, a: 1)
    static let a = Clr(r: 0.18, g: 0.36, b: 0.45, a: 1)
    static let U = Clr(r: 0.36, g: 0.67, b: 1.00, a: 1)
    static let R = Clr(r: 0.76, g: 0.96, b: 0.84, a: 1)
    static let Q = Clr(r: 1.00, g: 1.00, b: 1.00, a: 1)
    static let B = Clr(r: 0.03, g: 0.03, b: 0.04, a: 1)
}

// MARK: - Sprite Parsing

typealias P = Clr?

private let spritePalette: [Character: P] = [
    ".": nil, "O": .O, "W": .W, "S": .S, "E": .E, "T": .T, "t": .t, "X": .X,
    "N": .N, "C": .C, "G": .G, "g": .g, "M": .M, "A": .A, "a": .a, "U": .U, "R": .R, "Q": .Q, "B": .B,
]

func sprite(_ rows: [String]) -> [[P]] {
    rows.map { row in
        row.map { token in
            guard let color = spritePalette[token] else {
                preconditionFailure("Unknown sprite color token: \(token)")
            }
            return color
        }
    }
}

// MARK: - Sprite Specs

struct ToolSpriteSpec {
    let idle: [[[P]]]
    let work: [[[P]]]
    let done: [[[P]]]

    func rendered(pixelSize: Int) -> ToolSpriteCache {
        ToolSpriteCache(
            idle: idle.map { renderSprite($0, pixelSize: pixelSize) },
            work: work.map { renderSprite($0, pixelSize: pixelSize) },
            done: done.map { renderSprite($0, pixelSize: pixelSize) }
        )
    }
}

enum SpriteRegistry {
    static let specs: [SessionTool: ToolSpriteSpec] = [
        .claude: claudeSpriteSpec,
        .codex: codexSpriteSpec,
        .terminal: terminalSpriteSpec,
    ]
}

// MARK: - Sprite Renderer

func renderSprite(_ sprite: [[P]], pixelSize: Int) -> NSImage {
    let rows = sprite.count
    let cols = sprite.map { $0.count }.max() ?? 0
    let w = cols * pixelSize
    let h = rows * pixelSize

    let bitmapRep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: w, pixelsHigh: h,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: w * 4, bitsPerPixel: 32
    )!

    let ctx = NSGraphicsContext(bitmapImageRep: bitmapRep)!
    NSGraphicsContext.current = ctx
    let cgCtx = ctx.cgContext
    cgCtx.clear(CGRect(x: 0, y: 0, width: w, height: h))

    for (row, pixels) in sprite.enumerated() {
        for (col, clr) in pixels.enumerated() {
            guard let clr else { continue }
            cgCtx.setFillColor(CGColor(red: clr.r, green: clr.g, blue: clr.b, alpha: clr.a))
            cgCtx.fill(CGRect(x: col * pixelSize, y: (rows - 1 - row) * pixelSize, width: pixelSize, height: pixelSize))
        }
    }

    NSGraphicsContext.current = nil
    let image = NSImage(size: NSSize(width: w, height: h))
    image.addRepresentation(bitmapRep)
    return image
}

// MARK: - Sprite Cache

struct ToolSpriteCache {
    let idle: [NSImage]
    let work: [NSImage]
    let done: [NSImage]
}

struct SpriteCache {
    let byTool: [SessionTool: ToolSpriteCache]

    func frames(for tool: SessionTool, state: SessionState) -> [NSImage] {
        guard let set = byTool[tool] else { return [] }
        switch state {
        case .idle: return set.idle
        case .working: return set.work
        case .done: return set.done
        }
    }

    static func create() -> SpriteCache {
        let rendered = SpriteRegistry.specs.mapValues { $0.rendered(pixelSize: 3) }
        return SpriteCache(byTool: rendered)
    }
}
