import SwiftUI
import CodeIslandCore

/// Dex — Codex mascot, pixel-art cloud with terminal prompt face.
/// Inspired by Codex's cloud icon with `>_` symbol. OpenAI black & white style.
struct DexView: View {
    let status: AgentStatus
    var mood: MascotMood = .neutral
    var size: CGFloat = 27
    var animated: Bool = true
    @State private var alive = false
    @Environment(\.mascotSpeed) private var speed

    // OpenAI black & white palette — white body, black prompt
    private static let cloudC    = Color(red: 0.92, green: 0.92, blue: 0.93) // off-white
    private static let cloudDark = Color(red: 0.70, green: 0.70, blue: 0.72) // legs
    private static let promptC   = Color.black
    private static let alertC    = Color(red: 1.0, green: 0.55, blue: 0.0)   // amber warning
    private static let kbBase    = Color(red: 0.18, green: 0.18, blue: 0.20)
    private static let kbKey     = Color(red: 0.40, green: 0.40, blue: 0.42)
    private static let kbHi      = Color.white

    var body: some View {
        ZStack {
            switch status {
            case .idle:
                if animated {
                    idleMoodScene
                } else {
                    staticSleepScene
                }
            case .processing, .running: workScene
            case .waitingApproval, .waitingQuestion: alertScene
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .onAppear { alive = true }
        .onChange(of: status) {
            alive = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { alive = true }
        }
    }

    /// Dispatches to the correct idle scene based on mood.
    @ViewBuilder
    private var idleMoodScene: some View {
        switch mood {
        case .hungry:  hungryScene
        case .tired:   tiredScene
        case .sad:     sadScene
        case .sick:    sickScene
        case .joyful:  joyfulScene
        case .neutral: sleepScene
        }
    }

    // ── Coordinate helper ──
    private struct V {
        let ox: CGFloat, oy: CGFloat, s: CGFloat
        let y0: CGFloat

        init(_ sz: CGSize, svgW: CGFloat = 15, svgH: CGFloat = 10, svgY0: CGFloat = 6) {
            s = min(sz.width / svgW, sz.height / svgH)
            ox = (sz.width - svgW * s) / 2
            oy = (sz.height - svgH * s) / 2
            y0 = svgY0
        }
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, dy: CGFloat = 0) -> CGRect {
            CGRect(x: ox + x * s, y: oy + (y - y0 + dy) * s, width: w * s, height: h * s)
        }
    }

    // Interpolate between keyframes
    private func lerp(_ keyframes: [(CGFloat, CGFloat)], at pct: CGFloat) -> CGFloat {
        guard let first = keyframes.first else { return 0 }
        if pct <= first.0 { return first.1 }
        for i in 1..<keyframes.count {
            if pct <= keyframes[i].0 {
                let t = (pct - keyframes[i-1].0) / (keyframes[i].0 - keyframes[i-1].0)
                return keyframes[i-1].1 + (keyframes[i].1 - keyframes[i-1].1) * t
            }
        }
        return keyframes.last?.1 ?? 0
    }

    // ── Cloud body: a pixel-art blob shape ──
    // Rounded cloud made of overlapping rects (8-bit style)
    private func drawCloud(_ c: GraphicsContext, v: V, dy: CGFloat,
                           squashX: CGFloat = 1, squashY: CGFloat = 1) {
        let cc = Self.cloudC

        // Center offset for squash
        let cx: CGFloat = 7.5
        func sx(_ x: CGFloat, w: CGFloat) -> (CGFloat, CGFloat) {
            let nx = cx + (x - cx) * squashX
            return (nx, w * squashX)
        }

        // Cloud body — flat black, pixel blob shape
        let rows: [(y: CGFloat, x: CGFloat, w: CGFloat)] = [
            (14, 4, 7),       // bottom
            (13, 3, 9),
            (12, 2, 11),
            (11, 1, 13),      // widest
            (10, 1, 13),
            (9,  1, 13),
            (8,  2, 11),
            (7,  2, 11),
            // Top bumps (cloud silhouette)
            (6,  3, 3),       // left bump
            (6,  6, 3),       // center bump
            (6,  9, 3),       // right bump
            (5,  4, 2),       // left bump top
            (5,  6.5, 2),     // center bump top
            (5,  9, 2),       // right bump top
        ]

        for row in rows {
            let (adjX, adjW) = sx(row.x, w: row.w)
            let adjH: CGFloat = 1 * squashY
            c.fill(Path(v.r(adjX, row.y * squashY + (1 - squashY) * 10, adjW, adjH, dy: dy)),
                   with: .color(cc))
        }
    }

    // ── Draw `>_` terminal prompt as face ──
    private func drawPrompt(_ c: GraphicsContext, v: V, dy: CGFloat,
                            color: Color = Self.promptC, cursorOn: Bool = true) {
        // `>` chevron — pixel art
        c.fill(Path(v.r(3, 10, 1, 1, dy: dy)), with: .color(color))
        c.fill(Path(v.r(4, 11, 1, 1, dy: dy)), with: .color(color))
        c.fill(Path(v.r(3, 12, 1, 1, dy: dy)), with: .color(color))

        // `_` cursor
        if cursorOn {
            c.fill(Path(v.r(6, 12, 3, 1, dy: dy)), with: .color(color))
        }
    }

    // ── Shadow ──
    private func drawShadow(_ c: GraphicsContext, v: V, width: CGFloat = 9, opacity: Double = 0.3) {
        c.fill(Path(v.r(7.5 - width / 2, 15, width, 1)),
               with: .color(.black.opacity(opacity)))
    }

    // ── Small legs (pixel stubs under cloud) ──
    private func drawLegs(_ c: GraphicsContext, v: V) {
        c.fill(Path(v.r(5, 14.5, 1, 1.5)), with: .color(Self.cloudDark))
        c.fill(Path(v.r(9, 14.5, 1, 1.5)), with: .color(Self.cloudDark))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // SLEEP — floating gently, cursor blinking slow
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    private var sleepScene: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.06)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                sleepCanvas(t: t)
            }
            TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                floatingZs(t: t)
            }
        }
    }

    private var staticSleepScene: some View {
        sleepCanvas(t: 0)
    }

    private func floatingZs(t: Double) -> some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let ci = Double(i)
                let cycle = 2.8 + ci * 0.3
                let delay = ci * 0.9
                let phase = max(0, ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle)
                let fontSize = max(6, size * CGFloat(0.18 + phase * 0.10))
                let baseOpacity = 0.7 - ci * 0.1
                let opacity = phase < 0.8 ? baseOpacity : (1.0 - phase) * 3.5 * baseOpacity
                let xOff = size * CGFloat(0.08 + ci * 0.06 + sin(phase * .pi * 2) * 0.03)
                let yOff = -size * CGFloat(0.15 + phase * 0.38)
                Text("z")
                    .font(.system(size: fontSize, weight: .black, design: .monospaced))
                    .foregroundStyle(.white.opacity(opacity))
                    .offset(x: xOff, y: yOff)
            }
        }
    }

    private func sleepCanvas(t: Double) -> some View {
        let phase = t.truncatingRemainder(dividingBy: 4.0) / 4.0
        let float = sin(phase * .pi * 2) * 0.8  // gentle float
        let cursorPhase = t.truncatingRemainder(dividingBy: 1.2)
        let cursorOn = cursorPhase < 0.6  // slow blink

        return Canvas { c, sz in
            let v = V(sz, svgW: 15, svgH: 12, svgY0: 4)

            drawShadow(c, v: v, width: 7 + abs(float) * 0.3, opacity: 0.2)
            drawLegs(c, v: v)
            drawCloud(c, v: v, dy: float)
            // Sleep: only show dim cursor (no `>` chevron = mouth closed)
            if cursorOn {
                c.fill(Path(v.r(6, 12, 3, 1, dy: float)),
                       with: .color(Self.promptC.opacity(0.3)))
            }
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // WORK — bouncing, cursor active, typing on keyboard
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    private var workScene: some View {
        TimelineView(.periodic(from: .now, by: 0.03)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate * speed
            workCanvas(t: t)
        }
    }

    private func workCanvas(t: Double) -> some View {
        let bounce = sin(t * 2 * .pi / 0.4) * 1.0

        // Cursor rapid blink
        let cursorPhase = t.truncatingRemainder(dividingBy: 0.3)
        let cursorOn = cursorPhase < 0.15

        // Key flash
        let keyPhase = Int(t / 0.1) % 6

        return Canvas { c, sz in
            let v = V(sz, svgW: 16, svgH: 14, svgY0: 3)
            let dy = bounce

            // Shadow
            let shadowW: CGFloat = 8 - abs(dy) * 0.3
            c.fill(Path(v.r(4 + (8 - shadowW) / 2, 16, shadowW, 1)),
                   with: .color(.black.opacity(max(0.1, 0.35 - abs(dy) * 0.03))))

            drawLegs(c, v: v)

            // Keyboard
            c.fill(Path(v.r(0, 13, 15, 3)), with: .color(Self.kbBase))
            for row in 0..<2 {
                let ky = 13.5 + CGFloat(row) * 1.2
                for col in 0..<6 {
                    let kx = 0.5 + CGFloat(col) * 2.4
                    c.fill(Path(v.r(kx, ky, 1.8, 0.7)), with: .color(Self.kbKey))
                }
            }
            // Key flash
            let flashRow = keyPhase / 3
            let flashCol = keyPhase % 6
            let fkx = 0.5 + CGFloat(flashCol) * 2.4
            let fky = 13.5 + CGFloat(flashRow) * 1.2
            c.fill(Path(v.r(fkx, fky, 1.8, 0.7)), with: .color(Self.kbHi.opacity(0.9)))

            drawCloud(c, v: v, dy: dy)
            drawPrompt(c, v: v, dy: dy, cursorOn: cursorOn)
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // ALERT — shaking, prompt flashing amber
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    private var alertScene: some View {
        ZStack {
            Circle()
                .fill(Self.alertC.opacity(alive ? 0.12 : 0))
                .frame(width: size * 0.8)
                .blur(radius: size * 0.05)
                .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: alive)

            TimelineView(.periodic(from: .now, by: 0.03)) { ctx in
                alertCanvas(t: ctx.date.timeIntervalSinceReferenceDate * speed)
            }
        }
    }

    private func alertCanvas(t: Double) -> some View {
        let cycle = t.truncatingRemainder(dividingBy: 3.5)
        let pct = cycle / 3.5

        let jumpY = lerp([
            (0, 0), (0.03, 0), (0.10, -1), (0.15, 1.5),
            (0.175, -8), (0.20, -8), (0.25, 1.5),
            (0.275, -6), (0.30, -6), (0.35, 1.0),
            (0.375, -4), (0.40, -4), (0.45, 0.8),
            (0.475, -2), (0.50, -2), (0.55, 0.3),
            (0.62, 0), (1.0, 0),
        ], at: pct)

        let squashX: CGFloat = jumpY > 0.5 ? 1.0 + jumpY * 0.03 : 1.0
        let squashY: CGFloat = jumpY > 0.5 ? 1.0 - jumpY * 0.02 : 1.0

        // Shake
        let shakeX: CGFloat = (pct > 0.15 && pct < 0.55) ? sin(pct * 80) * 0.6 : 0

        // Prompt flashing between white and amber
        let flash = (pct > 0.03 && pct < 0.55) ? sin(pct * 25) * 0.5 + 0.5 : 0.0
        let promptColor = flash > 0.5 ? Self.alertC : Self.promptC

        // ! mark
        let bangOp = lerp([
            (0, 0), (0.03, 1), (0.10, 1), (0.55, 1), (0.62, 0), (1.0, 0),
        ], at: pct)
        let bangScale = lerp([
            (0, 0.3), (0.03, 1.3), (0.10, 1.0), (0.55, 1.0), (0.62, 0.6), (1.0, 0.6),
        ], at: pct)

        return Canvas { c, sz in
            let v = V(sz, svgW: 16, svgH: 14, svgY0: 3)

            // Shadow
            let shadowW: CGFloat = 8 * (1.0 - abs(min(0, jumpY)) * 0.04)
            let shadowOp = max(0.08, 0.4 - abs(min(0, jumpY)) * 0.04)
            c.fill(Path(v.r(4 + (8 - shadowW) / 2, 16, shadowW, 1)),
                   with: .color(.black.opacity(shadowOp)))

            drawLegs(c, v: v)

            // Cloud body with shake offset — draw manually with offset
            // Since drawCloud doesn't take shakeX, we apply transform
            c.translateBy(x: shakeX * v.s, y: 0)
            drawCloud(c, v: v, dy: jumpY, squashX: squashX, squashY: squashY)
            drawPrompt(c, v: v, dy: jumpY, color: promptColor, cursorOn: true)
            c.translateBy(x: -shakeX * v.s, y: 0)

            // ! mark
            if bangOp > 0.01 {
                let bw: CGFloat = 2 * bangScale
                let bx: CGFloat = 13
                let by: CGFloat = 4 + jumpY * 0.15
                c.fill(Path(v.r(bx, by, bw, 3.5 * bangScale, dy: 0)),
                       with: .color(Self.alertC.opacity(bangOp)))
                c.fill(Path(v.r(bx, by + 4.0 * bangScale, bw, 1.5 * bangScale, dy: 0)),
                       with: .color(Self.alertC.opacity(bangOp)))
            }
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MOOD SCENES — idle variants for Dex (cloud mascot)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // HUNGRY — wobbly cloud + open mouth + food emojis floating past
    private var hungryScene: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.06)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                let float = sin(t * .pi * 2 / 4.0) * 1.5   // bigger float
                let wobble = sin(t * 10) * 0.7              // faster, bigger wobble
                Canvas { c, sz in
                    let v = V(sz, svgW: 15, svgH: 12, svgY0: 4)
                    drawShadow(c, v: v, width: 7 + abs(float) * 0.4, opacity: 0.22)
                    drawLegs(c, v: v)
                    drawCloud(c, v: v, dy: float + wobble, squashX: 1 + wobble * 0.04, squashY: 1)
                    // Open mouth: wide `>` with big open underscore gap (hungry gape)
                    c.fill(Path(v.r(3, 10, 1, 1, dy: float + wobble)), with: .color(Self.promptC))
                    c.fill(Path(v.r(4, 11, 1, 1, dy: float + wobble)), with: .color(Self.promptC))
                    c.fill(Path(v.r(3, 12, 1, 1, dy: float + wobble)), with: .color(Self.promptC))
                    // Wide open mouth gap
                    c.fill(Path(v.r(5.5, 10.5, 4, 1.8, dy: float + wobble)),
                           with: .color(Self.promptC.opacity(0.85)))
                    // Stomach rumble dots (belly area)
                    let rumble = sin(t * 18) * 0.5
                    for i: CGFloat in [0, 1, 2] {
                        c.fill(Path(v.r(4 + i * 2, 12.5 + rumble * 0.3, 0.8, 0.8, dy: float + wobble)),
                               with: .color(Color(red: 1.0, green: 0.6, blue: 0.1).opacity(0.5)))
                    }
                }
            }
            // Multiple food emoji particles floating past
            TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                let foods = ["🍕", "🍔", "🍩", "🌮", "🍎"]
                ZStack {
                    ForEach(0..<5, id: \.self) { i in
                        let ci = Double(i)
                        let cycle = 2.0 + ci * 0.35
                        let delay = ci * 0.6
                        let p = ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle
                        let pp = max(0, p)
                        let xOff = size * CGFloat(-0.28 + ci * 0.15 + sin(pp * .pi) * 0.12)
                        let yOff = -size * CGFloat(0.08 + pp * 0.38)
                        let op = pp < 0.72 ? 0.9 : (1.0 - pp) * 3.21 * 0.9
                        Text(foods[i % foods.count])
                            .font(.system(size: max(5, size * 0.19)))
                            .opacity(op)
                            .offset(x: xOff, y: yOff)
                    }
                }
            }
        }
    }

    // TIRED — drooping cloud + nodding (bob down/up) + half-closed eyes + big Z
    private var tiredScene: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.06)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                // Nodding: slow dip then snap back
                let nodPhase = t.truncatingRemainder(dividingBy: 3.2) / 3.2
                let nod: CGFloat = nodPhase < 0.6
                    ? CGFloat(sin(nodPhase / 0.6 * .pi)) * 2.0   // dip down 2 units
                    : 0
                Canvas { c, sz in
                    let v = V(sz, svgW: 15, svgH: 12, svgY0: 4)
                    drawShadow(c, v: v, opacity: 0.14)
                    drawLegs(c, v: v)
                    // More squashed cloud = heavy drooping
                    drawCloud(c, v: v, dy: nod, squashX: 1.06, squashY: 0.90)
                    // Half-closed eyes: two thin horizontal bars
                    c.fill(Path(v.r(3.5, 10.5, 2.5, 0.5, dy: nod)),
                           with: .color(Self.promptC.opacity(0.7)))
                    c.fill(Path(v.r(8.5, 10.5, 2.5, 0.5, dy: nod)),
                           with: .color(Self.promptC.opacity(0.7)))
                    // Dim underscore cursor = barely awake
                    c.fill(Path(v.r(6, 12, 3, 1, dy: nod)),
                           with: .color(Self.promptC.opacity(0.12)))
                }
            }
            // Two staggered slow Zs (bigger, more visible)
            TimelineView(.periodic(from: .now, by: 0.07)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                ZStack {
                    ForEach(0..<2, id: \.self) { i in
                        let ci = Double(i)
                        let cycle = 3.8 + ci * 0.6
                        let delay = ci * 1.6
                        let phase = ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle
                        let p = max(0, phase)
                        let fontSize = max(7, size * CGFloat(0.22 + p * 0.10 + ci * 0.03))
                        let op = p < 0.78 ? 0.72 : (1.0 - p) * 3.43 * 0.72
                        let yOff = -size * CGFloat(0.10 + p * 0.40)
                        let xOff = size * CGFloat(0.06 + ci * 0.12)
                        Text("z")
                            .font(.system(size: fontSize, weight: .black, design: .monospaced))
                            .foregroundStyle(Color(red: 0.55, green: 0.65, blue: 1.0).opacity(op))
                            .offset(x: xOff, y: yOff)
                    }
                }
            }
        }
    }

    // SAD — cold-tinted cloud, drooping mouth, two tear streams, slight lean
    private var sadScene: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.06)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                let float = sin(t * .pi * 2 / 4.5) * 0.5
                Canvas { c, sz in
                    let v = V(sz, svgW: 15, svgH: 12, svgY0: 4)
                    drawShadow(c, v: v, opacity: 0.18)
                    drawLegs(c, v: v)
                    // Cold blue-grey tinted cloud
                    var gctx = c
                    gctx.opacity = 0.68
                    drawCloud(gctx, v: v, dy: float)
                    // Frown: inverted `>` — bottom pointing down
                    c.fill(Path(v.r(3, 12, 1, 1, dy: float)), with: .color(Self.promptC.opacity(0.6)))
                    c.fill(Path(v.r(4, 11, 1, 1, dy: float)), with: .color(Self.promptC.opacity(0.6)))
                    c.fill(Path(v.r(5, 12, 1, 1, dy: float)), with: .color(Self.promptC.opacity(0.6)))
                    // Cold blue tint overlay pixels on cloud body
                    for row: CGFloat in [10, 11, 12] {
                        c.fill(Path(v.r(2, row, 11, 1, dy: float)),
                               with: .color(Color(red: 0.3, green: 0.5, blue: 0.9).opacity(0.12)))
                    }
                }
            }
            // Two staggered tear streams (left & right)
            TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                ZStack {
                    ForEach(0..<2, id: \.self) { i in
                        let ci = Double(i)
                        let cycle = 1.8 + ci * 0.5
                        let delay = ci * 0.85
                        let phase = ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle
                        let pp = max(0, phase)
                        let yOff = size * CGFloat(0.04 + pp * 0.42)  // longer fall
                        let xOff = size * CGFloat(-0.08 + ci * 0.18)
                        let op = pp < 0.65 ? 0.80 : (1.0 - pp) * 2.29 * 0.80
                        Circle()
                            .fill(Color(red: 0.25, green: 0.55, blue: 1.0).opacity(op))
                            .frame(width: size * 0.075, height: size * 0.12)
                            .offset(x: xOff, y: yOff)
                    }
                }
            }
        }
    }

    // SICK — green-tinted cloud + irregular shake + X eyes + sweat drops
    private var sickScene: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                // Irregular sick wobble: two-frequency shake
                let shake = sin(t * 7) * 0.9 + sin(t * 13.5) * 0.5
                let float = sin(t * .pi * 2 / 5.0) * 0.4
                Canvas { c, sz in
                    let v = V(sz, svgW: 15, svgH: 12, svgY0: 4)
                    drawShadow(c, v: v, opacity: 0.15)
                    drawLegs(c, v: v)
                    // Green-tinted sick cloud (opacity + green overlay)
                    let sickCloud = Color(red: 0.82, green: 0.92, blue: 0.75).opacity(0.88)
                    let rows: [(y: CGFloat, x: CGFloat, w: CGFloat)] = [
                        (14, 4, 7), (13, 3, 9), (12, 2, 11),
                        (11, 1, 13), (10, 1, 13), (9, 1, 13),
                        (8, 2, 11), (7, 2, 11),
                        (6, 3, 3), (6, 6, 3), (6, 9, 3),
                        (5, 4, 2), (5, 6.5, 2), (5, 9, 2),
                    ]
                    c.translateBy(x: shake * v.s, y: 0)
                    for row in rows {
                        c.fill(Path(v.r(row.x, row.y, row.w, 1, dy: float)),
                               with: .color(sickCloud))
                    }
                    // X eyes (sick): two diagonal cross marks
                    let eyePositions: [(CGFloat, CGFloat)] = [(3.0, 10.0), (8.5, 10.0)]
                    for (ex, ey) in eyePositions {
                        // Top-left to bottom-right
                        c.fill(Path(v.r(ex,       ey,       0.8, 0.8, dy: float)), with: .color(Self.promptC.opacity(0.9)))
                        c.fill(Path(v.r(ex + 0.8, ey + 0.8, 0.8, 0.8, dy: float)), with: .color(Self.promptC.opacity(0.9)))
                        // Top-right to bottom-left
                        c.fill(Path(v.r(ex + 0.8, ey,       0.8, 0.8, dy: float)), with: .color(Self.promptC.opacity(0.9)))
                        c.fill(Path(v.r(ex,       ey + 0.8, 0.8, 0.8, dy: float)), with: .color(Self.promptC.opacity(0.9)))
                    }
                    // Wavy sick mouth
                    for dx: CGFloat in [0, 1, 2] {
                        let wavY: CGFloat = dx.truncatingRemainder(dividingBy: 2) == 0 ? 12.5 : 12.0
                        c.fill(Path(v.r(5 + dx, wavY, 0.9, 0.9, dy: float)),
                               with: .color(Color(red: 0.2, green: 0.75, blue: 0.3).opacity(0.8)))
                    }
                    // Fever dots above cloud (4 dots)
                    for i: CGFloat in [0, 1, 2, 3] {
                        let dotRect = v.r(3.5 + i * 2.2, 4.5, 1.0, 1.0, dy: float)
                        c.fill(Path(ellipseIn: dotRect),
                               with: .color(Color(red: 0.95, green: 0.25, blue: 0.35).opacity(0.80)))
                    }
                    c.translateBy(x: -shake * v.s, y: 0)
                }
            }
            // Sweat drops (3 drops, staggered)
            TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                ZStack {
                    ForEach(0..<3, id: \.self) { i in
                        let ci = Double(i)
                        let cycle = 1.6 + ci * 0.4
                        let delay = ci * 0.55
                        let p = ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle
                        let pp = max(0, p)
                        let xOff = size * CGFloat(-0.15 + ci * 0.16)
                        let yOff = size * CGFloat(0.08 + pp * 0.35)
                        let op = pp < 0.6 ? 0.75 : (1.0 - pp) * 1.875 * 0.75
                        Circle()
                            .fill(Color(red: 0.4, green: 0.9, blue: 0.6).opacity(op))
                            .frame(width: size * 0.065, height: size * 0.09)
                            .offset(x: xOff, y: yOff)
                    }
                }
            }
        }
    }

    // JOYFUL — bouncing cloud + `>_` face + dense sparkle ring (12 particles)
    private var joyfulScene: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                joyfulCanvas(t: t)
            }
            TimelineView(.periodic(from: .now, by: 0.04)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                ZStack {
                    // Inner ring: 6 gold stars
                    ForEach(0..<6, id: \.self) { i in
                        let ci = Double(i)
                        let cycle = 1.3 + ci * 0.15
                        let delay = ci * 0.22
                        let phase = ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle
                        let p = max(0, phase)
                        let angle = ci * 60.0 * .pi / 180.0
                        let r = size * CGFloat(0.28 + p * 0.16)
                        let xOff = r * CGFloat(cos(angle))
                        let yOff = r * CGFloat(sin(angle)) - size * 0.08
                        let op = p < 0.60 ? 1.0 : (1.0 - p) * 2.5 * 1.0
                        Text("✦")
                            .font(.system(size: max(5, size * 0.155)))
                            .foregroundStyle(Color(red: 1.0, green: 0.85, blue: 0.0).opacity(op))
                            .offset(x: xOff, y: yOff)
                    }
                    // Outer ring: 6 smaller white sparkles
                    ForEach(0..<6, id: \.self) { i in
                        let ci = Double(i)
                        let cycle = 1.8 + ci * 0.18
                        let delay = ci * 0.30 + 0.11
                        let phase = ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle
                        let p = max(0, phase)
                        let angle = (ci * 60.0 + 30.0) * .pi / 180.0
                        let r = size * CGFloat(0.38 + p * 0.14)
                        let xOff = r * CGFloat(cos(angle))
                        let yOff = r * CGFloat(sin(angle)) - size * 0.06
                        let op = p < 0.55 ? 0.85 : (1.0 - p) * 1.89 * 0.85
                        Text("✦")
                            .font(.system(size: max(4, size * 0.10)))
                            .foregroundStyle(Color(red: 1.0, green: 1.0, blue: 0.6).opacity(op))
                            .offset(x: xOff, y: yOff)
                    }
                }
            }
        }
    }

    /// Joyful cloud: bouncy jump animation + bright full-opacity `>_` face.
    private func joyfulCanvas(t: Double) -> some View {
        // Bouncy jump: quick rise then settle with squash
        let jumpPhase = t.truncatingRemainder(dividingBy: 1.2) / 1.2
        let jumpY: CGFloat = jumpPhase < 0.35
            ? CGFloat(-sin(jumpPhase / 0.35 * .pi) * 2.8)   // rise up 2.8 units
            : 0
        let squashY: CGFloat = jumpPhase > 0.38 && jumpPhase < 0.52
            ? CGFloat(1.0 - (jumpPhase - 0.38) / 0.14 * 0.12)  // squash on land
            : 1.0
        let cursorPhase = t.truncatingRemainder(dividingBy: 0.7)
        let cursorOn = cursorPhase < 0.42

        return Canvas { c, sz in
            let v = V(sz, svgW: 15, svgH: 12, svgY0: 4)
            let shadowW: CGFloat = 7 + abs(jumpY) * 0.4
            let shadowOp: Double = max(0.10, 0.22 - Double(abs(jumpY)) * 0.025)
            drawShadow(c, v: v, width: shadowW, opacity: shadowOp)
            drawLegs(c, v: v)
            drawCloud(c, v: v, dy: jumpY, squashX: 1.0, squashY: squashY)
            // Bright gold-tinted prompt for joyful
            drawPrompt(c, v: v, dy: jumpY,
                       color: Color(red: 0.0, green: 0.0, blue: 0.0), cursorOn: cursorOn)
        }
    }
}
