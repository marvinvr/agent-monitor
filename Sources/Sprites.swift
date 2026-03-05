import AppKit

// MARK: - Color Palette

struct Clr {
    let r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat
    static let O = Clr(r: 0.09, g: 0.10, b: 0.12, a: 1)    // dark outline
    static let W = Clr(r: 0.96, g: 0.97, b: 0.99, a: 1)    // body white
    static let S = Clr(r: 0.80, g: 0.84, b: 0.89, a: 1)    // lower shadow
    static let E = Clr(r: 0.12, g: 0.13, b: 0.16, a: 1)    // face details
    static let T = Clr(r: 0.47, g: 0.89, b: 0.66, a: 1)    // activity accent
    static let t = Clr(r: 0.24, g: 0.56, b: 0.42, a: 1)    // activity shadow
    static let X = Clr(r: 0.99, g: 0.88, b: 0.42, a: 1)    // done spark
}

// MARK: - Sprite Parsing

typealias P = Clr?

private let spritePalette: [Character: P] = [
    ".": nil, "O": .O, "W": .W, "S": .S, "E": .E, "T": .T, "t": .t, "X": .X,
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

// MARK: - Idle Frames (16x16)

let idleFrame1: [[P]] = sprite([
    "................",
    "................",
    ".....OOOOOO.....",
    "....OWWWWWWO....",
    "...OWWWWWWWWO...",
    "...OWWEEEEWWO...",
    "...OWWWWWWWWO...",
    "...OWWSSSSWWO...",
    "...OWWSSSSWWO...",
    "...OWWWWWWWWO...",
    "....OWWWWWWO....",
    "....W.W.W.W.....",
    "................",
    "................",
    "................",
    "................",
])

let idleFrame2: [[P]] = sprite([
    "................",
    "................",
    "................",
    ".....OOOOOO.....",
    "....OWWWWWWO....",
    "...OWWWWWWWWO...",
    "...OWWEEEEWWO...",
    "...OWWWWWWWWO...",
    "...OWWSSSSWWO...",
    "...OWWSSSSWWO...",
    "...OWWWWWWWWO...",
    "....OWWWWWWO....",
    "....W.W.W.W.....",
    "................",
    "................",
    "................",
])

let idleFrame3: [[P]] = sprite([
    "................",
    "................",
    "......OOOOOO....",
    ".....OWWWWWWO...",
    "....OWWWWWWWWO..",
    "....OWWEEEEWWO..",
    "....OWWWWWWWWO..",
    "....OWWSSSSWWO..",
    "....OWWSSSSWWO..",
    "....OWWWWWWWWO..",
    ".....OWWWWWWO...",
    ".....W.W.W.W....",
    "................",
    "................",
    "................",
    "................",
])

// MARK: - Working Frames (18x16)

let workFrame1: [[P]] = sprite([
    "..................",
    "..................",
    ".....OOOOOO.......",
    "....OWWWWWWO......",
    "...OWWWWWWWWO..TT.",
    "...OWWEEEEWWO.TtT.",
    "...OWWWWWWWWO.TTT.",
    "...OWWSSSSWWO..t..",
    "...OWWSSSSWWO.....",
    "...OWWWWWWWWO.....",
    "....OWWWWWWO......",
    "....W.W.W.W.......",
    "..................",
    "..................",
    "..................",
    "..................",
    "..................",
])

let workFrame2: [[P]] = sprite([
    "..................",
    "..................",
    ".....OOOOOO.......",
    "....OWWWWWWO......",
    "...OWWWWWWWWO..tT.",
    "...OWWEEEEWWO.TTT.",
    "...OWWWWWWWWO.TtT.",
    "...OWWSSSSWWO..T..",
    "...OWWSSSSWWO.....",
    "...OWWWWWWWWO.....",
    "....OWWWWWWO......",
    "....W.W.W.W.......",
    "..................",
    "..................",
    "..................",
    "..................",
    "..................",
])

let workFrame3: [[P]] = sprite([
    "..................",
    "..................",
    "......OOOOOO......",
    ".....OWWWWWWO.....",
    "....OWWWWWWWWO.T..",
    "....OWWEEEEWWO.TT.",
    "....OWWWWWWWWO.tT.",
    "....OWWSSSSWWO.TT.",
    "....OWWSSSSWWO....",
    "....OWWWWWWWWO....",
    ".....OWWWWWWO.....",
    ".....W.W.W.W......",
    "..................",
    "..................",
    "..................",
    "..................",
    "..................",
])

// MARK: - Done Frames (16x16)

let doneFrame1: [[P]] = sprite([
    ".......X........",
    "......XXX.......",
    ".....OOOOOO.....",
    "....OWWWWWWO....",
    "...OWWWWWWWWO...",
    "...OWWEEEEWWO...",
    "...OWWWWWWWWO...",
    "...OWWSSSSWWO...",
    "...OWWSSSSWWO...",
    "...OWWWWWWWWO...",
    "....OWWWWWWO....",
    "....W.W.W.W.....",
    "................",
    "................",
    "................",
    "................",
])

let doneFrame2: [[P]] = sprite([
    "............X...",
    ".......X...XXX..",
    ".....OOOOOO.....",
    "....OWWWWWWO....",
    "...OWWWWWWWWO...",
    "...OWWEEEEWWO...",
    "...OWWWWWWWWO...",
    "...OWWSSSSWWO...",
    "...OWWSSSSWWO...",
    "...OWWWWWWWWO...",
    "....OWWWWWWO....",
    "....W.W.W.W.....",
    "................",
    "................",
    "................",
    "................",
])

let doneFrame3: [[P]] = sprite([
    "....X...........",
    "...XXX..........",
    ".....OOOOOO.....",
    "....OWWWWWWO....",
    "...OWWWWWWWWO...",
    "...OWWEEEEWWO...",
    "...OWWWWWWWWO...",
    "...OWWSSSSWWO...",
    "...OWWSSSSWWO...",
    "...OWWWWWWWWO...",
    "....OWWWWWWO....",
    "....W.W.W.W.....",
    "................",
    "................",
    "................",
    "................",
])

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
            guard let clr = clr else { continue }
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

struct SpriteCache {
    let idle1: NSImage
    let idle2: NSImage
    let idle3: NSImage
    let work1: NSImage
    let work2: NSImage
    let work3: NSImage
    let done1: NSImage
    let done2: NSImage
    let done3: NSImage

    static func create() -> SpriteCache {
        SpriteCache(
            idle1: renderSprite(idleFrame1, pixelSize: 3),
            idle2: renderSprite(idleFrame2, pixelSize: 3),
            idle3: renderSprite(idleFrame3, pixelSize: 3),
            work1: renderSprite(workFrame1, pixelSize: 3),
            work2: renderSprite(workFrame2, pixelSize: 3),
            work3: renderSprite(workFrame3, pixelSize: 3),
            done1: renderSprite(doneFrame1, pixelSize: 3),
            done2: renderSprite(doneFrame2, pixelSize: 3),
            done3: renderSprite(doneFrame3, pixelSize: 3)
        )
    }
}
