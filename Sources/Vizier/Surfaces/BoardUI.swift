import AppKit
import VizierEngine
import SwiftUI

/// The Departures kit for the deliberate surfaces (popover and History), from DESIGN.md. The strip
/// draws itself in Core Graphics; these are the same tokens in SwiftUI.
enum Ink {
    static func hex(_ value: UInt32, _ alpha: Double = 1) -> Color { Color(nsColor: Board.color(value, alpha: alpha)) }

    static let window = hex(0x121212)
    static let board = hex(0x141414)
    static let well = hex(0x161616)
    static let raise = hex(0x1c1c1c)
    static let raise2 = hex(0x242424)
    static let rule = hex(0x242424)
    static let rule2 = hex(0x2e2e2e)
    static let rowRule = hex(0x1d1d1d)
    static let rowHover = hex(0x171717)
    static let rowSelected = hex(0x202020)
    static let waveBar = hex(0x4d4b46)
    static let plateSplit = hex(0x0b0b0b)
    static let edgeHover = hex(0x55534e)
    static let edgeFocus = hex(0x6a6862)
    static let signalRed = hex(0xff6b7f)
    static var enamel: Color { Color(nsColor: Board.enamel) }
    static var ink2: Color { Color(nsColor: Board.ink2) }
    static var ink3: Color { Color(nsColor: Board.ink3) }
}

/// Archivo roles for SwiftUI, from DESIGN.md Typography.
enum Face {
    static func font(_ size: CGFloat, _ weight: CGFloat, _ width: CGFloat, tabular: Bool = false) -> Font {
        Font(Archivo.font(size, weight: weight, width: width, tabular: tabular) as CTFont)
    }

    static let mark = font(19, 800, 62)
    static let windowTitle = font(17, 800, 62)
    static let clock = font(31, 800, 72)
    static let reading = font(15, 400, 100)
    static let fieldValue = font(14, 600, 87, tabular: true)
    static let remarks = font(13.5, 500, 100)
    static let body = font(13, 400, 100)
    static let bodyStrong = font(13, 600, 100)
    static let row = font(12.5, 500, 87, tabular: true)
    static let rowText = font(12.5, 400, 100)
    static let code = font(12, 700, 72)
    static let control = font(11.5, 700, 72)
    static let plate = font(11, 800, 70)
    static let plateSmall = font(9.5, 800, 70)
    static let module = font(10.5, 700, 72)
    static let label = font(10, 700, 75)
    static let small = font(11.5, 400, 100)
}

/// A flap's two faces and the 1px split at its midline.
struct FlapFace: View {
    var top: Color
    var bottom: Color
    var split: Color
    var radius: CGFloat

    static func tone(_ tone: FlapTone, radius: CGFloat) -> FlapFace {
        FlapFace(top: Color(nsColor: tone.top), bottom: Color(nsColor: tone.bottom), split: Color(nsColor: tone.split), radius: radius)
    }

    var body: some View {
        VStack(spacing: 0) {
            top
            split.frame(height: 1)
            bottom
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension TakeOutcome {
    var plateText: String {
        switch self {
        case .recording: "RECORDING"
        case .finalizing: "RUNNING"
        case .pasted: "PASTED"
        case .rerouted: "RE-ROUTED"
        case .held: "HELD"
        case .failed: "FAILED"
        case .cancelled: "CANCELLED"
        }
    }

    var tone: FlapTone {
        switch self {
        case .recording, .finalizing, .pasted: .plain
        case .rerouted: .slate
        case .held: .white
        case .failed: .red
        case .cancelled: .gray
        }
    }
}

/// The flap you read an outcome from. Tone lives in the fill, never an edge.
struct StatusPlate: View {
    var text: String
    var tone: FlapTone
    var small = false

    init(_ outcome: TakeOutcome, small: Bool = false) {
        text = outcome.plateText
        tone = outcome.tone
        self.small = small
    }

    init(text: String, tone: FlapTone, small: Bool = false) {
        self.text = text
        self.tone = tone
        self.small = small
    }

    var body: some View {
        Text(text)
            .font(small ? Face.plateSmall : Face.plate)
            .tracking(small ? 0.665 : 0.88)
            .foregroundStyle(Color(nsColor: tone.ink))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, small ? 6 : 8)
            .frame(height: small ? 18 : 22)
            .background(FlapFace.tone(tone, radius: 3))
    }
}

/// A mode's two-letter platform code on a module flap.
struct PlatformCode: View {
    var code: String
    var body: some View {
        Text(code)
            .font(Face.code)
            .tracking(0.6)
            .foregroundStyle(Ink.enamel)
            .padding(.horizontal, 4)
            .frame(minWidth: 26, minHeight: 20)
            .background(FlapFace.tone(.module, radius: 2))
    }
}

/// The RIGHT ⌘ tag on the bound mode (or whichever key the user chose).
struct BoundTag: View {
    var text = "RIGHT ⌘"
    var body: some View {
        Text(text)
            .font(Face.plateSmall)
            .tracking(0.76)
            .foregroundStyle(Ink.board)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 3).fill(Ink.enamel))
    }
}

/// Column heads and field labels: one style and one vocabulary everywhere.
struct BoardLabel: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(Face.label).tracking(1.2).foregroundStyle(Ink.ink3).lineLimit(1)
    }
}

/// The header every Vizier window shares (DESIGN.md, Layout, Windows): at least 50px tall, the
/// title 96px from the window's left edge so it clears the traffic lights, and the window's
/// controls right-aligned with the board's 14px gutter. The window puts a 1px Rule under it.
struct WindowHeader<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 14) {
            Text(title.uppercased()).font(Face.windowTitle).tracking(2.38).lineLimit(1).fixedSize()
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 14)
            trailing
        }
        .padding(.leading, 96)
        .padding(.trailing, 14)
        .frame(minHeight: 50)
        // The header stands in for the title bar, so dragging its empty parts moves the window.
        .background { Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()) }
    }
}

/// Fixed character modules. Only a cell whose character changes flips: the old top half folds
/// down over 90 ms and the new face lands; Reduce Motion lands it at once.
struct ModuleCells: View {
    var text: String
    var cell: CGSize
    var font: Font
    var gap: CGFloat = 1
    var colonWidth: CGFloat? = nil
    var radius: CGFloat = 2

    var body: some View {
        HStack(spacing: gap) {
            ForEach(Array(text.enumerated()), id: \.offset) { _, character in
                ModuleCell(character: character, font: font, radius: radius)
                    .frame(width: character == ":" ? (colonWidth ?? cell.width) : cell.width, height: cell.height)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

private struct ModuleCell: View {
    var character: Character
    var font: Font
    var radius: CGFloat
    @State private var shown: Character?
    @State private var fold: Double = 0
    @State private var old: Character?

    var body: some View {
        ZStack {
            FlapFace.tone(.module, radius: radius)
            face(shown ?? character)
            if let old {
                // The old top half, folding toward the split.
                GeometryReader { geometry in
                    ZStack {
                        FlapFace.tone(.module, radius: radius)
                        face(old)
                    }
                    .frame(height: geometry.size.height)
                    .mask(alignment: .top) { Rectangle().frame(height: geometry.size.height / 2) }
                    .rotation3DEffect(.degrees(-90 * fold), axis: (1, 0, 0), anchor: .center, perspective: 0.6)
                    .brightness(-0.6 * fold)
                }
            }
        }
        .onChange(of: character) { previous, next in
            guard previous != next else { return }
            shown = next
            guard !Board.reduceMotion else { return }
            old = previous
            fold = 0
            withAnimation(.timingCurve(0.5, 0, 1, 0.6, duration: 0.09)) { fold = 1 } completion: { old = nil }
        }
    }

    private func face(_ character: Character) -> some View {
        Text(String(character)).font(font).foregroundStyle(Ink.enamel).lineLimit(1)
    }
}

/// The world's icons: 16px grid, 1.5px round strokes, current color.
enum BoardIcon {
    case search, play, stop, copy, arrow, check, open, rerun

    @ViewBuilder func view(_ size: CGFloat = 14) -> some View {
        Canvas { context, canvas in
            let scale = canvas.width / 16
            context.scaleBy(x: scale, y: scale)
            let stroke = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            let shading = GraphicsContext.Shading.foreground
            switch self {
            case .search:
                context.stroke(Path(ellipseIn: CGRect(x: 2.8, y: 2.8, width: 8.4, height: 8.4)), with: shading, style: stroke)
                context.stroke(Path { $0.move(to: CGPoint(x: 10.2, y: 10.2)); $0.addLine(to: CGPoint(x: 13.5, y: 13.5)) }, with: shading, style: stroke)
            case .play:
                context.fill(Path { $0.move(to: CGPoint(x: 5, y: 3.6)); $0.addLine(to: CGPoint(x: 5, y: 12.4)); $0.addLine(to: CGPoint(x: 12.2, y: 8)); $0.closeSubpath() }, with: shading)
            case .stop:
                context.fill(Path(roundedRect: CGRect(x: 4.2, y: 4.2, width: 7.6, height: 7.6), cornerRadius: 1), with: shading)
            case .copy:
                context.stroke(Path(roundedRect: CGRect(x: 5.5, y: 5.5, width: 8, height: 8), cornerRadius: 1.5), with: shading, style: stroke)
                context.stroke(Path { p in
                    p.move(to: CGPoint(x: 10.5, y: 5.5)); p.addLine(to: CGPoint(x: 10.5, y: 4))
                    p.addQuadCurve(to: CGPoint(x: 9, y: 2.5), control: CGPoint(x: 10.5, y: 2.5))
                    p.addLine(to: CGPoint(x: 4, y: 2.5))
                    p.addQuadCurve(to: CGPoint(x: 2.5, y: 4), control: CGPoint(x: 2.5, y: 2.5))
                    p.addLine(to: CGPoint(x: 2.5, y: 9))
                    p.addQuadCurve(to: CGPoint(x: 4, y: 10.5), control: CGPoint(x: 2.5, y: 10.5))
                    p.addLine(to: CGPoint(x: 5.5, y: 10.5))
                }, with: shading, style: stroke)
            case .arrow:
                context.stroke(Path { p in
                    p.move(to: CGPoint(x: 2.5, y: 8)); p.addLine(to: CGPoint(x: 13, y: 8))
                    p.move(to: CGPoint(x: 9.5, y: 4.5)); p.addLine(to: CGPoint(x: 13, y: 8)); p.addLine(to: CGPoint(x: 9.5, y: 11.5))
                }, with: shading, style: stroke)
            case .check:
                context.stroke(Path { p in
                    p.move(to: CGPoint(x: 3.5, y: 8.4)); p.addLine(to: CGPoint(x: 6.6, y: 11.4)); p.addLine(to: CGPoint(x: 12.5, y: 4.8))
                }, with: shading, style: stroke)
            case .rerun:
                // A near-full circle turning clockwise, its arrowhead at the top.
                context.stroke(Path { p in
                    p.addArc(center: CGPoint(x: 8, y: 8.6), radius: 5, startAngle: .degrees(-60), endAngle: .degrees(250), clockwise: false)
                }, with: shading, style: stroke)
                context.stroke(Path { p in
                    p.move(to: CGPoint(x: 10.3, y: 1.9)); p.addLine(to: CGPoint(x: 10.6, y: 4.4)); p.addLine(to: CGPoint(x: 13.1, y: 4.3))
                }, with: shading, style: stroke)
            case .open:
                context.stroke(Path { p in
                    p.move(to: CGPoint(x: 9, y: 2.8)); p.addLine(to: CGPoint(x: 13.2, y: 2.8)); p.addLine(to: CGPoint(x: 13.2, y: 7))
                    p.move(to: CGPoint(x: 13.2, y: 2.8)); p.addLine(to: CGPoint(x: 7.6, y: 8.4))
                    p.move(to: CGPoint(x: 11.4, y: 9.6)); p.addLine(to: CGPoint(x: 11.4, y: 13.2)); p.addLine(to: CGPoint(x: 2.8, y: 13.2))
                    p.addLine(to: CGPoint(x: 2.8, y: 4.6)); p.addLine(to: CGPoint(x: 6.4, y: 4.6))
                }, with: shading, style: stroke)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Flap controls: 2px corners, the split across the face, hover and press faces.
struct FlapButtonStyle: ButtonStyle {
    var primary = false
    var height: CGFloat = 26
    var horizontalPadding: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        FlapButtonBody(configuration: configuration, primary: primary, height: height, horizontalPadding: horizontalPadding)
    }
}

private struct FlapButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let primary: Bool
    let height: CGFloat
    let horizontalPadding: CGFloat
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let faces: (UInt32, UInt32, UInt32) =
            primary ? (hovering ? (0xfbf9f4, 0xf0ede6, 0xc9c6be) : (0xeeebe4, 0xe4e1d9, 0xc9c6be))
            : configuration.isPressed ? (0x1b1b1b, 0x161616, 0x0d0d0d)
            : hovering ? (0x2c2b2a, 0x242423, 0x0d0d0d) : (0x222121, 0x1a1a1a, 0x0d0d0d)
        configuration.label
            .font(Face.control)
            .tracking(0.92)
            .textCase(.uppercase)
            .foregroundStyle(primary ? Ink.board : Ink.enamel)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background(FlapFace(top: Ink.hex(faces.0), bottom: Ink.hex(faces.1), split: Ink.hex(faces.2), radius: 2))
            .overlay {
                if Board.increaseContrast && !primary {
                    RoundedRectangle(cornerRadius: 2).strokeBorder(Ink.hex(0x8a8680), lineWidth: 1)
                }
            }
            .offset(y: configuration.isPressed ? 0.5 : 0)
            .opacity(enabled ? 1 : 0.38)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// A flap button with an optional leading icon.
struct FlapButton: View {
    var title: String
    var icon: BoardIcon?
    var primary = false
    var height: CGFloat = 26
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                icon?.view(14)
                Text(title)
            }
        }
        .buttonStyle(FlapButtonStyle(primary: primary, height: height))
    }
}

/// Segmented flaps: the on segment takes the primary white faces.
struct FlapSegments<Value: Hashable>: View {
    var options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, title in
                Button(title) { selection = value }
                    .buttonStyle(FlapButtonStyle(primary: selection == value, height: 24, horizontalPadding: 9))
                    .foregroundStyle(selection == value ? Ink.board : Ink.ink2)
                    .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
    }
}

/// Where a mode's engines show in words: "Scribe Realtime then Gemini cleanup".
enum EngineNames {
    static func name(_ engine: String) -> String {
        switch engine {
        case "elevenlabs-scribe-realtime": "Scribe Realtime"
        case "elevenlabs-scribe-batch": "Scribe batch"
        case "gemini-live": "Gemini Live"
        case "gemini-batch": "Gemini batch"
        case "gemini-generate": "Gemini cleanup"
        case "local-whisper": "Whisper on this Mac"
        case "local-cleanup": "local cleanup"
        case "apple-speech": "Apple"
        case "apple-speech-batch": "Apple (file)"
        case VoiceInkImport.engine: "VoiceInk"
        default: engine
        }
    }

    static func route(_ mode: VizierConfig.Mode) -> String {
        ([name(mode.transcriber.engine)] + (mode.cleanup.map { [name($0.engine)] } ?? [])).joined(separator: " then ")
    }
}
