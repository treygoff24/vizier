// Draws Vizier's app icon, the board's seal (DESIGN.md, "Departures"), at every size macOS asks
// for, then packs them with iconutil.
//
//   swift scripts/make-icon.swift [--logomark <path.png>]
//
// Writes build/Vizier.iconset, Resources/Vizier.icns, and Resources/AppIcon-1024.png; with
// --logomark, also the mark alone on a transparent 1024 canvas for banners and docs.
//
// The mark: an enamel signet carrying a V, split across its middle like a white plate, with hinge
// notches where the split meets its rim and an engraved border ring, posted on a tile that is
// itself one large flap. A vizier carried the seal of office; Vizier takes your words and posts
// them where they go. Monochrome by rule: amber means the mic is live and appears nowhere else.
//
// The icon sits on Apple's macOS grid: a 1024 canvas holding an 824-point continuous-corner
// square 100 points in from each edge, with the drop shadow macOS 27 gives its own icons. Every
// size is drawn from the vectors at its own pixel size, not scaled down from 1024, and the split,
// the seal and the letter snap to whole pixels so 16 and 32 stay crisp. Output is byte-identical
// from run to run.
import AppKit
import CoreText
import ImageIO
import UniformTypeIdentifiers

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = repo.appendingPathComponent("build/Vizier.iconset")
let icns = repo.appendingPathComponent("Resources/Vizier.icns")
let preview = repo.appendingPathComponent("Resources/AppIcon-1024.png")
var logomark: URL?
if let i = CommandLine.arguments.firstIndex(of: "--logomark") {
    guard i + 1 < CommandLine.arguments.count else { fatalError("--logomark needs a path") }
    logomark = URL(fileURLWithPath: CommandLine.arguments[i + 1])
}

// MARK: Tokens (DESIGN.md)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

let boardBlack = rgb(0x141414)
let raised = rgb(0x1c1c1c)     // the tile's top face, one step above Board Black
let rim = rgb(0x2e2e2e)        // Rule Two: the body's inner edge, so a black icon keeps its edge on a dark dock
let split = rgb(0x0d0d0d)
// The seal is a Held White plate: White Top over White Bottom. Its split uses Primary Cut, a step
// deeper than White Cut, so it still reads across the enamel at dock sizes.
let whiteTop = rgb(0xeeebe4)
let whiteBottom = rgb(0xe4e1d9)
let whiteSplit = rgb(0xc9c6be)

// MARK: Archivo

let fontURL = repo.appendingPathComponent("Resources/Fonts/Archivo[wdth,wght].ttf")
var fontError: Unmanaged<CFError>?
guard CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &fontError) else {
    fatalError("could not register \(fontURL.path): \(String(describing: fontError?.takeRetainedValue()))")
}

func archivo(_ size: CGFloat, weight: CGFloat, width: CGFloat) -> CTFont {
    let attributes: [NSFontDescriptor.AttributeName: Any] = [
        .family: "Archivo",
        .variation: [NSNumber(value: 0x7767_6874): NSNumber(value: Double(weight)),  // 'wght'
                     NSNumber(value: 0x7764_7468): NSNumber(value: Double(width))],  // 'wdth'
    ]
    guard let font = NSFont(descriptor: NSFontDescriptor(fontAttributes: attributes), size: size),
          font.familyName == "Archivo" else { fatalError("Archivo did not load") }
    return font as CTFont
}

/// The outline of one character, y-up, in font units at `font`'s size.
func letter(_ character: String, _ font: CTFont) -> CGPath {
    var chars = Array(character.utf16), glyphs = [CGGlyph](repeating: 0, count: chars.count)
    guard CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count),
          let path = CTFontCreatePathForGlyph(font, glyphs[0], nil) else { fatalError("no glyph for \(character)") }
    return path
}

// MARK: Shapes

/// A continuous-curvature rounded square: each corner is a superellipse quadrant (exponent 2.55)
/// running `span` along both edges. At span 259 on the 824 body this matches the mask macOS 27
/// draws its own icons with to within 2 px at 1024 (fitted against Terminal's icon as
/// NSWorkspace renders it), where a circular 185.4 arc misses by up to 18. y-down.
func squircle(_ rect: CGRect, span: CGFloat) -> CGPath {
    let exponent: CGFloat = 2.55, steps = 96
    let path = CGMutablePath()
    func corner(_ x: CGFloat, _ y: CGFloat, _ sx: CGFloat, _ sy: CGFloat, reversed: Bool) {
        for i in 0...steps {
            let t = CGFloat(reversed ? steps - i : i) / CGFloat(steps) * .pi / 2
            let point = CGPoint(x: x + sx * (span - span * pow(cos(t), 2 / exponent)),
                                y: y + sy * (span - span * pow(sin(t), 2 / exponent)))
            if path.isEmpty { path.move(to: point) } else { path.addLine(to: point) }
        }
    }
    corner(rect.minX, rect.minY, 1, 1, reversed: false)
    corner(rect.maxX, rect.minY, -1, 1, reversed: true)
    corner(rect.maxX, rect.maxY, -1, -1, reversed: false)
    corner(rect.minX, rect.maxY, 1, -1, reversed: true)
    path.closeSubpath()
    return path
}

/// The top flap's shadow falling on the face below a split: DESIGN.md lets gradients paint only
/// the split.
func splitShade(_ ctx: CGContext, below y: CGFloat, x: CGFloat, width: CGFloat, depth: CGFloat, alpha: CGFloat) {
    let shade = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                           colors: [rgb(0x000000, alpha), rgb(0x000000, 0)] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.clip(to: CGRect(x: x, y: y, width: width, height: depth))
    ctx.drawLinearGradient(shade, start: CGPoint(x: 0, y: y), end: CGPoint(x: 0, y: y + depth), options: [])
    ctx.restoreGState()
}

// MARK: The seal

/// Draws the seal centred at (`cx`, `cy`) with radius `r`, in a y-down context `px` pixels square
/// whose canvas maps 1024 points to `s` × 1024 pixels. `splitY` and `splitH` are the whole-pixel
/// split it shares with the tile.
func drawSeal(_ ctx: CGContext, px: Int, s: CGFloat, cx: CGFloat, cy: CGFloat, r: CGFloat, splitY: CGFloat, splitH: CGFloat) {
    func snap(_ v: CGFloat) -> CGFloat { v.rounded() }
    let small = px <= 32, tiny = px <= 16
    let disc = CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)

    // The enamel faces, top a shade lighter than bottom, as on every flap.
    ctx.saveGState()
    ctx.addEllipse(in: disc); ctx.clip()
    ctx.setFillColor(whiteTop); ctx.fill(CGRect(x: disc.minX, y: disc.minY, width: disc.width, height: splitY - disc.minY))
    ctx.setFillColor(whiteBottom); ctx.fill(CGRect(x: disc.minX, y: splitY, width: disc.width, height: disc.maxY - splitY))
    ctx.restoreGState()

    // The engraved border ring, from 64 px up; below that it would only grey the rim.
    if px >= 64 {
        let ringR = r - 34 * s
        ctx.setStrokeColor(boardBlack); ctx.setLineWidth(max(1, 9 * s))
        ctx.strokeEllipse(in: CGRect(x: cx - ringR, y: cy - ringR, width: 2 * ringR, height: 2 * ringR))
    }

    // V in Archivo 860 at width 92, cut by the split like a letter on a flap. At 16 and 32 px it
    // grows, gets heavier and snaps to whole pixels so its strokes keep two clean columns.
    let font = archivo(1000, weight: tiny ? 900 : small ? 880 : 860, width: tiny ? 100 : 92)
    let glyph = letter("V", font)
    let bounds = glyph.boundingBoxOfPath
    let cap = max(3, snap((tiny ? 7 / 16 * 1024 : small ? 384 : 330) * s))
    let k = cap / bounds.height
    // A V carries its weight at the top, so it sits 6 points low to look centred.
    var top = cy - cap / 2 + (small ? 0 : 6 * s), left = cx - bounds.width * k / 2
    if small { top = snap(top); left = snap(left) }
    var place = CGAffineTransform(translationX: left, y: top + cap)
        .scaledBy(x: k, y: -k).translatedBy(x: -bounds.minX, y: -bounds.minY)
    let v = glyph.copy(using: &place)!
    ctx.addPath(v); ctx.setFillColor(boardBlack); ctx.fillPath()

    // The split across the seal, drawn over the letter. At 16 and 32 px a whole-pixel split would
    // take a seventh of the letter and cut the V into two eyes over a mouth, so there it runs
    // behind it.
    ctx.saveGState()
    ctx.addEllipse(in: disc); ctx.clip()
    if small {
        ctx.addRect(CGRect(x: disc.minX, y: splitY, width: disc.width, height: splitH)); ctx.addPath(v)
        ctx.clip(using: .evenOdd)
    }
    ctx.setFillColor(whiteSplit); ctx.fill(CGRect(x: disc.minX, y: splitY, width: disc.width, height: splitH))
    ctx.restoreGState()
    if px >= 64 {
        ctx.saveGState()
        ctx.addEllipse(in: disc); ctx.clip()
        splitShade(ctx, below: splitY + splitH, x: disc.minX, width: disc.width, depth: 40 * s, alpha: 0.10)
        ctx.restoreGState()
    }

    // Hinge notches where the split meets the rim, from 128 px up.
    if px >= 128 {
        ctx.setFillColor(boardBlack)
        let nr = 15 * s, ny = splitY + splitH / 2
        for x in [disc.minX, disc.maxX] { ctx.fillEllipse(in: CGRect(x: x - nr, y: ny - nr, width: 2 * nr, height: 2 * nr)) }
    }
}

// MARK: The icon

/// Draws the icon into a y-down context `px` pixels square, working in pixels throughout.
func drawIcon(_ ctx: CGContext, px: Int) {
    let s = CGFloat(px) / 1024   // canvas points to pixels
    func snap(_ v: CGFloat) -> CGFloat { v.rounded() }
    let small = px <= 32, tiny = px <= 16

    // Body: the macOS grid square and its shadow (matched to Terminal's icon as macOS 27 renders it,
    // within 4/255 alpha along the edges).
    let body = squircle(CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s), span: 259 * s)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6 * s), blur: 36 * s, color: rgb(0x000000, 0.25))
    ctx.addPath(body); ctx.setFillColor(boardBlack); ctx.fillPath()
    ctx.restoreGState()

    // The tile is one large flap: its top face a step lighter, a whole-pixel split across the
    // middle and, from 64 px up, the top flap's shadow below it. Then a hairline rim inside it.
    let splitH = max(1, snap(10 * s))
    let splitY = snap(512 * s - splitH / 2)
    ctx.saveGState()
    ctx.addPath(body); ctx.clip()
    ctx.setFillColor(raised); ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(px), height: splitY))
    ctx.setFillColor(split); ctx.fill(CGRect(x: 0, y: splitY, width: CGFloat(px), height: splitH))
    if px >= 64 { splitShade(ctx, below: splitY + splitH, x: 0, width: CGFloat(px), depth: 36 * s, alpha: 0.28) }
    ctx.addPath(body); ctx.setStrokeColor(rim); ctx.setLineWidth(max(2, 8 * s)); ctx.strokePath()
    ctx.restoreGState()

    // The seal, larger at 16 and 32 px so the V keeps enough pixels to read in Finder.
    let r = (tiny ? 368 : small ? 352 : 330) * s
    drawSeal(ctx, px: px, s: s, cx: 512 * s, cy: 512 * s, r: r, splitY: splitY, splitH: splitH)
}

/// The mark alone: the seal in a Board Black bezel, so its edge holds on a white page and on a
/// dark one, on a transparent 1024 canvas.
func drawLogomark(_ ctx: CGContext) {
    let k: CGFloat = 470 / 330   // the seal, 940 across, in a 30 px bezel
    let splitH = (10 * k).rounded(), splitY = (512 - splitH / 2).rounded()
    ctx.setFillColor(boardBlack); ctx.fillEllipse(in: CGRect(x: 12, y: 12, width: 1000, height: 1000))
    drawSeal(ctx, px: 1024, s: k, cx: 512, cy: 512, r: 470, splitY: splitY, splitH: splitH)
}

func render(_ px: Int, _ draw: (CGContext) -> Void) -> CGImage {
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("context \(px)") }
    ctx.translateBy(x: 0, y: CGFloat(px)); ctx.scaleBy(x: 1, y: -1)
    draw(ctx)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("cannot write \(url.path)")
    }
    // 72 dpi at 1x and 144 at 2x, as iconutil expects.
    let dpi = url.lastPathComponent.contains("@2x") ? 144 : 72
    CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(url.path)") }
}

// MARK: Main

let fm = FileManager.default
if fm.fileExists(atPath: iconset.path) { try fm.removeItem(at: iconset) }
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

var rendered: [Int: CGImage] = [:]
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = points * scale
        let image = rendered[px] ?? render(px) { drawIcon($0, px: px) }
        rendered[px] = image
        writePNG(image, to: iconset.appendingPathComponent("icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"))
    }
}
writePNG(rendered[1024]!, to: preview)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil exited \(iconutil.terminationStatus)") }
print("wrote \(icns.path), \(preview.path)")

if let logomark {
    try fm.createDirectory(at: logomark.deletingLastPathComponent(), withIntermediateDirectories: true)
    writePNG(render(1024, drawLogomark), to: logomark)
    print("wrote \(logomark.path)")
}
