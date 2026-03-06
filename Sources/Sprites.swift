import AppKit

// MARK: - Color Palette

struct Clr {
    let r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat
    static let O = Clr(r: 0.85, g: 0.45, b: 0.22, a: 1)    // matches title color and removes visible border
    static let W = Clr(r: 0.85, g: 0.45, b: 0.22, a: 1)    // body orange (same as app title)
    static let S = Clr(r: 0.70, g: 0.33, b: 0.13, a: 1)    // lower orange shadow
    static let E = Clr(r: 0.12, g: 0.13, b: 0.16, a: 1)    // face details
    static let T = Clr(r: 0.47, g: 0.89, b: 0.66, a: 1)    // activity accent
    static let t = Clr(r: 0.24, g: 0.56, b: 0.42, a: 1)    // activity shadow
    static let X = Clr(r: 0.99, g: 0.88, b: 0.42, a: 1)    // done spark
    static let N = Clr(r: 0.06, g: 0.09, b: 0.13, a: 1)    // codex outline
    static let C = Clr(r: 0.91, g: 0.95, b: 1.00, a: 1)    // codex highlight
    static let G = Clr(r: 0.74, g: 0.79, b: 0.86, a: 1)    // codex gray accent
    static let g = Clr(r: 0.43, g: 0.48, b: 0.56, a: 1)    // codex gray shadow
    static let A = Clr(r: 0.50, g: 0.84, b: 0.76, a: 1)    // codex accent
    static let a = Clr(r: 0.18, g: 0.36, b: 0.45, a: 1)    // codex accent shadow
    static let R = Clr(r: 0.76, g: 0.96, b: 0.84, a: 1)    // codex resolved core
    static let Q = Clr(r: 1.00, g: 1.00, b: 1.00, a: 1)    // alert bubble fill
    static let B = Clr(r: 0.03, g: 0.03, b: 0.04, a: 1)    // alert bubble outline / mark
}

// MARK: - Sprite Parsing

typealias P = Clr?

private let spritePalette: [Character: P] = [
    ".": nil, "O": .O, "W": .W, "S": .S, "E": .E, "T": .T, "t": .t, "X": .X,
    "N": .N, "C": .C, "G": .G, "g": .g, "A": .A, "a": .a, "R": .R, "Q": .Q, "B": .B,
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

// MARK: - Idle Frames (16x19)

let idleFrame1: [[P]] = sprite([
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    ".....OOOOOO.....",
    "....OWWWWWWO....",
    "...OWWWWWWWWO...",
    "...OWWEWWEWWO...",
    "...OWWWWWWWWO...",
    "...OWWSSSSWWO...",
    "...OWWSSSSWWO...",
    "...OWWWWWWWWO...",
    "....OWWWWWWO....",
    "....W.W.W.W.....",
])

let idleFrame2: [[P]] = sprite([
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    ".....OOOOOO.....",
    "....OWWWWWWO....",
    "...OWWWWWWWWO...",
    "...OWWEWWEWWO...",
    "...OWWWWWWWWO...",
    "...OWWSSSSWWO...",
    "...OWWSSSSWWO...",
    "...OWWWWWWWWO...",
    "....OWWWWWWO....",
    "....W.W.W.W.....",
])

let idleFrame3: [[P]] = sprite([
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "......OOOOOO....",
    ".....OWWWWWWO...",
    "....OWWWWWWWWO..",
    "....OWWEWWEWWO..",
    "....OWWWWWWWWO..",
    "....OWWSSSSWWO..",
    "....OWWSSSSWWO..",
    "....OWWWWWWWWO..",
    ".....OWWWWWWO...",
    ".....W.W.W.W....",
])

// MARK: - Working Frames (16x19)

let workFrame1: [[P]] = sprite([
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    ".....OOOOOO.....",
    "....OWWWWWWO....",
    "...OWWWWWWWWO...",
    "...OWWEWWEWWO...",
    "...OWWWWWWWWO...",
    "...OWWSSSSWWO...",
    "...OWWSSSSWWO...",
    "...OWWWWWWWWO...",
    "....OWWWWWWO....",
    "....W.W.W.W.....",
])

let workFrame2: [[P]] = sprite([
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    ".....OOOOOO.....",
    "....OWWWWWWO....",
    "...OWWWWWWWWO...",
    "...OWWEWWEWWO...",
    "...OWWWWWWWWO...",
    "...OWWSSSSWWO...",
    "...OWWSSSSWWO...",
    "...OWWWWWWWWO...",
    "....OWWWWWWO....",
    "....W.W.W.W.....",
])

let workFrame3: [[P]] = sprite([
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "......OOOOOO....",
    ".....OWWWWWWO...",
    "....OWWWWWWWWO..",
    "....OWWEWWEWWO..",
    "....OWWWWWWWWO..",
    "....OWWSSSSWWO..",
    "....OWWSSSSWWO..",
    "....OWWWWWWWWO..",
    ".....OWWWWWWO...",
    ".....W.W.W.W....",
])

// MARK: - Done Frames (18x19)

let doneFrame1: [[P]] = sprite([
    "..................",
    "..........BBBBB...",
    ".........BQQQQQB..",
    ".........BQQBQQB..",
    ".........BQQBQQB..",
    ".........BQQQQQB..",
    ".........BQQBQQB..",
    ".........BQQQQQB..",
    "..........BBQBB...",
    ".....OOOOOO.......",
    "....OWWWWWWO......",
    "...OWWWWWWWWO.....",
    "...OWWEWWEWWO.....",
    "...OWWWWWWWWO.....",
    "...OWWSSSSWWO.....",
    "...OWWSSSSWWO.....",
    "...OWWWWWWWWO.....",
    "....OWWWWWWO......",
    "....W.W.W.W.......",
])

let doneFrame2: [[P]] = sprite([
    "..................",
    "...........BBBBB..",
    "..........BQQQQQB.",
    "..........BQQBQQB.",
    "..........BQQBQQB.",
    "..........BQQQQQB.",
    "..........BQQBQQB.",
    "..........BQQQQQB.",
    "...........BBQBB..",
    ".....OOOOOO.......",
    "....OWWWWWWO......",
    "...OWWWWWWWWO.....",
    "...OWWEWWEWWO.....",
    "...OWWWWWWWWO.....",
    "...OWWSSSSWWO.....",
    "...OWWSSSSWWO.....",
    "...OWWWWWWWWO.....",
    "....OWWWWWWO......",
    "....W.W.W.W.......",
])

let doneFrame3: [[P]] = sprite([
    "..................",
    ".........BBBBB....",
    "........BQQQQQB...",
    "........BQQBQQB...",
    "........BQQBQQB...",
    "........BQQQQQB...",
    "........BQQBQQB...",
    "........BQQQQQB...",
    ".........BBQBB....",
    ".....OOOOOO.......",
    "....OWWWWWWO......",
    "...OWWWWWWWWO.....",
    "...OWWEWWEWWO.....",
    "...OWWWWWWWWO.....",
    "...OWWSSSSWWO.....",
    "...OWWSSSSWWO.....",
    "...OWWWWWWWWO.....",
    "....OWWWWWWO......",
    "....W.W.W.W.......",
])

// MARK: - Codex Idle Frames (16x19)

let codexIdleFrame1: [[P]] = sprite([
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    ".....NNNNNN.....",
    "....NNCCCCNN....",
    "...NNCCAACCNN...",
    "..NNCA.EE.ACNN..",
    "..NCC......CCN..",
    "..NCC..EEE.CCN..",
    "..NCGGGGGGGGCN..",
    "..NCAAGGGGAACN..",
    "...NAA....AAN...",
    ".....a....a.....",
    "......gggg......",
])

let codexIdleFrame2: [[P]] = sprite([
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    ".....NNNNNN.....",
    "....NNCCCCNN....",
    "...NNCCAACCNN...",
    "..NNCA.EE.ACNN..",
    "..NCC......CCN..",
    "..NCC..EEE.CCN..",
    "..NCGGGGGGGGCN..",
    "..NCAAGGGGAACN..",
    "...NAA....AAN...",
    ".....a....a.....",
    "......gggg......",
])

let codexIdleFrame3: [[P]] = sprite([
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "......NNNNNN....",
    ".....NNCCCCNN...",
    "....NNCCAACCNN..",
    "...NNCA.EE.ACNN.",
    "...NCC......CCN.",
    "...NCC..EEE.CCN.",
    "...NCGGGGGGGGCN.",
    "...NCAAGGGGAACN.",
    "....NAA....AAN..",
    "......a....a....",
    ".......gggg.....",
])

// MARK: - Codex Working Frames (16x19)

let codexWorkFrame1: [[P]] = sprite([
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    ".....NNNNNN.....",
    "....NNCCCCNN....",
    "...NNCCAACCNN...",
    "..NNCA.EE.ACNN..",
    "..NCC......CCN..",
    "..NCC..EEE.CCN..",
    "..NCGGGGGGGGCN..",
    "..NCAAGGGGAACN..",
    "...NAA....AAN...",
    ".....a....a.....",
    "......gggg......",
])

let codexWorkFrame2: [[P]] = sprite([
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    ".....NNNNNN.....",
    "....NNCCCCNN....",
    "...NNCCAACCNN...",
    "..NNCA.EE.ACNN..",
    "..NCC......CCN..",
    "..NCC..EEE.CCN..",
    "..NCGGGGGGGGCN..",
    "..NCAAGGGGAACN..",
    "...NAA....AAN...",
    ".....a....a.....",
    "......gggg......",
])

let codexWorkFrame3: [[P]] = sprite([
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "................",
    "......NNNNNN....",
    ".....NNCCCCNN...",
    "....NNCCAACCNN..",
    "...NNCA.EE.ACNN.",
    "...NCC......CCN.",
    "...NCC..EEE.CCN.",
    "...NCGGGGGGGGCN.",
    "...NCAAGGGGAACN.",
    "....NAA....AAN..",
    "......a....a....",
    ".......gggg.....",
])

// MARK: - Codex Done Frames (18x19)

let codexDoneFrame1: [[P]] = sprite([
    "..........BBBBB...",
    ".........BQQQQQB..",
    ".........BQQBQQB..",
    ".........BQQBQQB..",
    ".........BQQQQQB..",
    ".........BQQBQQB..",
    ".........BQQQQQB..",
    "..........BBQBB...",
    ".....NNNNNN.......",
    "....NNCCCCNN......",
    "...NNCCAACCNN.....",
    "..NNCA.EE.ACNN....",
    "..NCC......CCN....",
    "..NCC..EEE.CCN....",
    "..NCGGGGGGGGCN....",
    "..NCAAGGGGAACN....",
    "...NAA....AAN.....",
    ".....a....a.......",
    "......gggg........",
])

let codexDoneFrame2: [[P]] = sprite([
    "...........BBBBB..",
    "..........BQQQQQB.",
    "..........BQQBQQB.",
    "..........BQQBQQB.",
    "..........BQQQQQB.",
    "..........BQQBQQB.",
    "..........BQQQQQB.",
    "...........BBQBB..",
    ".....NNNNNN.......",
    "....NNCCCCNN......",
    "...NNCCAACCNN.....",
    "..NNCA.EE.ACNN....",
    "..NCC......CCN....",
    "..NCC..EEE.CCN....",
    "..NCGGGGGGGGCN....",
    "..NCAAGGGGAACN....",
    "...NAA....AAN.....",
    ".....a....a.......",
    "......gggg........",
])

let codexDoneFrame3: [[P]] = sprite([
    ".........BBBBB....",
    "........BQQQQQB...",
    "........BQQBQQB...",
    "........BQQBQQB...",
    "........BQQQQQB...",
    "........BQQBQQB...",
    "........BQQQQQB...",
    ".........BBQBB....",
    ".....NNNNNN.......",
    "....NNCCCCNN......",
    "...NNCCAACCNN.....",
    "..NNCA.EE.ACNN....",
    "..NCC......CCN....",
    "..NCC..EEE.CCN....",
    "..NCGGGGGGGGCN....",
    "..NCAAGGGGAACN....",
    "...NAA....AAN.....",
    ".....a....a.......",
    "......gggg........",
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

struct ToolSpriteCache {
    let idle: [NSImage]
    let work: [NSImage]
    let done: [NSImage]
}

struct SpriteCache {
    let claude: ToolSpriteCache
    let codex: ToolSpriteCache

    func frames(for tool: SessionTool, state: SessionState) -> [NSImage] {
        let set = tool == .codex ? codex : claude
        switch state {
        case .idle: return set.idle
        case .working: return set.work
        case .done: return set.done
        }
    }

    static func create() -> SpriteCache {
        SpriteCache(
            claude: ToolSpriteCache(
                idle: [
                    renderSprite(idleFrame1, pixelSize: 3),
                    renderSprite(idleFrame2, pixelSize: 3),
                    renderSprite(idleFrame3, pixelSize: 3),
                ],
                work: [
                    renderSprite(workFrame1, pixelSize: 3),
                    renderSprite(workFrame2, pixelSize: 3),
                    renderSprite(workFrame3, pixelSize: 3),
                ],
                done: [
                    renderSprite(doneFrame1, pixelSize: 3),
                    renderSprite(doneFrame2, pixelSize: 3),
                    renderSprite(doneFrame3, pixelSize: 3),
                ]
            ),
            codex: ToolSpriteCache(
                idle: [
                    renderSprite(codexIdleFrame1, pixelSize: 3),
                    renderSprite(codexIdleFrame2, pixelSize: 3),
                    renderSprite(codexIdleFrame3, pixelSize: 3),
                ],
                work: [
                    renderSprite(codexWorkFrame1, pixelSize: 3),
                    renderSprite(codexWorkFrame2, pixelSize: 3),
                    renderSprite(codexWorkFrame3, pixelSize: 3),
                ],
                done: [
                    renderSprite(codexDoneFrame1, pixelSize: 3),
                    renderSprite(codexDoneFrame2, pixelSize: 3),
                    renderSprite(codexDoneFrame3, pixelSize: 3),
                ]
            )
        )
    }
}
