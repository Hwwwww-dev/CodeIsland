import SwiftUI
import CodeIslandCore

/// OpBot — OpenCode mascot, pixel-art dark terminal block with `{ }` face.
/// Minimalist geometric style matching OpenCode's monochrome branding.
struct OpenCodeView: View {
    let status: AgentStatus
    var mood: MascotMood = .neutral
    var size: CGFloat = 27
    var animated: Bool = true
    @State private var alive = false
    @Environment(\.mascotSpeed) private var speed

    // OpenCode monochrome palette
    private static let bodyC    = Color(red: 0.22, green: 0.22, blue: 0.24) // #383838 dark gray
    private static let frameC   = Color(red: 0.55, green: 0.55, blue: 0.57) // #8C8C91 light gray frame
    private static let faceC    = Color(red: 0.85, green: 0.85, blue: 0.87) // #D9D9DE light face
    private static let legC     = Color(red: 0.35, green: 0.35, blue: 0.37)
    private static let alertC   = Color(red: 1.0, green: 0.55, blue: 0.0)   // amber
    private static let kbBase   = Color(red: 0.12, green: 0.12, blue: 0.14)
    private static let kbKey    = Color(red: 0.30, green: 0.30, blue: 0.32)
    private static let kbHi     = Color.white

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

    // ── Draw block body — geometric square with inner frame ──
    private func drawBlock(_ c: GraphicsContext, v: V, dy: CGFloat,
                           squashX: CGFloat = 1, squashY: CGFloat = 1) {
        let cx: CGFloat = 7.5

        func sx(_ x: CGFloat, w: CGFloat) -> (CGFloat, CGFloat) {
            let nx = cx + (x - cx) * squashX
            return (nx, w * squashX)
        }

        // Outer body (dark square block)
        let bodyRows: [(y: CGFloat, x: CGFloat, w: CGFloat)] = [
            (5,  3, 9),   // top
            (6,  2, 11),
            (7,  2, 11),
            (8,  2, 11),
            (9,  2, 11),
            (10, 2, 11),
            (11, 2, 11),
            (12, 2, 11),
            (13, 3, 9),   // bottom
        ]
        for row in bodyRows {
            let (adjX, adjW) = sx(row.x, w: row.w)
            let adjH: CGFloat = 1 * squashY
            c.fill(Path(v.r(adjX, row.y * squashY + (1 - squashY) * 10, adjW, adjH, dy: dy)),
                   with: .color(Self.bodyC))
        }

        // Inner frame (light gray border, 1px inset)
        let frameRows: [(y: CGFloat, x: CGFloat, w: CGFloat)] = [
            (6,  3, 9),   // top edge
            (12, 3, 9),   // bottom edge
        ]
        for row in frameRows {
            let (adjX, adjW) = sx(row.x, w: row.w)
            c.fill(Path(v.r(adjX, row.y * squashY + (1 - squashY) * 10, adjW, 0.7 * squashY, dy: dy)),
                   with: .color(Self.frameC.opacity(0.6)))
        }
        // Left and right edges
        for y: CGFloat in stride(from: 7, to: 12, by: 1) {
            let (lx, _) = sx(3, w: 0.7)
            c.fill(Path(v.r(lx, y * squashY + (1 - squashY) * 10, 0.7 * squashX, 1 * squashY, dy: dy)),
                   with: .color(Self.frameC.opacity(0.4)))
            let (rx, _) = sx(11.3, w: 0.7)
            c.fill(Path(v.r(rx, y * squashY + (1 - squashY) * 10, 0.7 * squashX, 1 * squashY, dy: dy)),
                   with: .color(Self.frameC.opacity(0.4)))
        }
    }

    // ── Draw face — `{ }` brackets ──
    private func drawFace(_ c: GraphicsContext, v: V, dy: CGFloat,
                          color: Color = Self.faceC, eyeScale: CGFloat = 1.0) {
        let eyeH: CGFloat = 2.0 * eyeScale
        let eyeY: CGFloat = 8.5 + (2.0 - eyeH) / 2

        // Left bracket `{`
        c.fill(Path(v.r(4.5, eyeY, 0.8, max(0.3, eyeH), dy: dy)), with: .color(color))
        c.fill(Path(v.r(4.0, eyeY + eyeH * 0.3, 0.7, max(0.3, eyeH * 0.4), dy: dy)), with: .color(color))

        // Right bracket `}`
        c.fill(Path(v.r(9.7, eyeY, 0.8, max(0.3, eyeH), dy: dy)), with: .color(color))
        c.fill(Path(v.r(10.2, eyeY + eyeH * 0.3, 0.7, max(0.3, eyeH * 0.4), dy: dy)), with: .color(color))

        // Center dot (cursor)
        if eyeScale > 0.5 {
            c.fill(Path(v.r(7.1, 9.2, 0.8, 0.8, dy: dy)), with: .color(color.opacity(0.8)))
        }
    }

    private func drawShadow(_ c: GraphicsContext, v: V, width: CGFloat = 9, opacity: Double = 0.3) {
        c.fill(Path(v.r(7.5 - width / 2, 14.5, width, 1)),
               with: .color(.black.opacity(opacity)))
    }

    private func drawLegs(_ c: GraphicsContext, v: V) {
        c.fill(Path(v.r(4, 13.5, 1, 1.5)), with: .color(Self.legC))
        c.fill(Path(v.r(10, 13.5, 1, 1.5)), with: .color(Self.legC))
    }

    // ── Idle mood dispatcher ──
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

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MOOD SCENES — OpenCodeView (dark block `{ }`)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // HUNGRY — wobbly block + open `{ }` brackets wide + food emojis + rumble
    private var hungryScene: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.06)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                let float = sin(t * .pi * 2 / 4.0) * 1.5
                let wobble = sin(t * 10) * 0.7
                Canvas { c, sz in
                    let v = V(sz, svgW: 15, svgH: 12, svgY0: 4)
                    drawShadow(c, v: v, width: 8 + abs(float) * 0.4, opacity: 0.22)
                    drawLegs(c, v: v)
                    drawBlock(c, v: v, dy: float + wobble, squashX: 1 + wobble * 0.03)
                    // Open mouth gap
                    c.fill(Path(v.r(5.5, 10.5, 4, 1.5, dy: float + wobble)),
                           with: .color(Color.black.opacity(0.80)))
                    // Wide `{ }` face (hungry expression)
                    drawFace(c, v: v, dy: float + wobble, color: Self.faceC, eyeScale: 1.3)
                    // Rumble dots on belly
                    let rumble = sin(t * 18) * 0.5
                    for i: CGFloat in [0, 1, 2] {
                        c.fill(Path(v.r(4.5 + i * 2, 12.0 + rumble * 0.3, 0.8, 0.8, dy: float + wobble)),
                               with: .color(Color(red: 1.0, green: 0.6, blue: 0.1).opacity(0.5)))
                    }
                }
            }
            TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                let foods = ["🍕", "🍔", "🍩", "🌮", "🍎"]
                ZStack {
                    ForEach(0..<5, id: \.self) { i in
                        let ci = Double(i)
                        let cycle = 2.0 + ci * 0.35
                        let delay = ci * 0.6
                        let p = max(0, ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle)
                        let xOff = size * CGFloat(-0.28 + ci * 0.15 + sin(p * .pi) * 0.12)
                        let yOff = -size * CGFloat(0.08 + p * 0.38)
                        let op = p < 0.72 ? 0.9 : (1.0 - p) * 3.21 * 0.9
                        Text(foods[i % foods.count])
                            .font(.system(size: max(5, size * 0.19)))
                            .opacity(op)
                            .offset(x: xOff, y: yOff)
                    }
                }
            }
        }
    }

    // TIRED — slow nod + half-closed `{ }` face + large Zs
    private var tiredScene: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.06)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                let nodPhase = t.truncatingRemainder(dividingBy: 3.2) / 3.2
                let nod: CGFloat = nodPhase < 0.6
                    ? CGFloat(sin(nodPhase / 0.6 * .pi)) * 2.0
                    : 0
                Canvas { c, sz in
                    let v = V(sz, svgW: 15, svgH: 12, svgY0: 4)
                    drawShadow(c, v: v, opacity: 0.14)
                    drawLegs(c, v: v)
                    drawBlock(c, v: v, dy: nod, squashX: 1.06, squashY: 0.90)
                    // Half-closed face (scale 0.2)
                    drawFace(c, v: v, dy: nod, color: Self.faceC.opacity(0.4), eyeScale: 0.20)
                }
            }
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

    // SAD — cold overlay + dim body opacity + tears + sad brow
    private var sadScene: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.06)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                let float = sin(t * .pi * 2 / 4.5) * 0.5
                Canvas { c, sz in
                    let v = V(sz, svgW: 15, svgH: 12, svgY0: 4)
                    drawShadow(c, v: v, opacity: 0.18)
                    drawLegs(c, v: v)
                    var gctx = c
                    gctx.opacity = 0.70
                    drawBlock(gctx, v: v, dy: float)
                    drawFace(gctx, v: v, dy: float, color: Self.faceC.opacity(0.5), eyeScale: 0.6)
                    // Cold blue overlay
                    c.fill(Path(v.r(2, 5, 11, 9, dy: float)),
                           with: .color(Color(red: 0.3, green: 0.5, blue: 0.9).opacity(0.10)))
                    // Inverted V brow (sad) above `{` and `}` positions
                    c.fill(Path(v.r(4.0, 7.8, 1.5, 0.7, dy: float)),
                           with: .color(Self.frameC.opacity(0.6)))
                    c.fill(Path(v.r(5.5, 7.2, 1.5, 0.7, dy: float)),
                           with: .color(Self.frameC.opacity(0.6)))
                    c.fill(Path(v.r(8.5, 7.2, 1.5, 0.7, dy: float)),
                           with: .color(Self.frameC.opacity(0.6)))
                    c.fill(Path(v.r(10.0, 7.8, 1.5, 0.7, dy: float)),
                           with: .color(Self.frameC.opacity(0.6)))
                }
            }
            TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                ZStack {
                    ForEach(0..<2, id: \.self) { i in
                        let ci = Double(i)
                        let cycle = 1.8 + ci * 0.5
                        let delay = ci * 0.85
                        let phase = ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle
                        let pp = max(0, phase)
                        let yOff = size * CGFloat(0.04 + pp * 0.42)
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

    // SICK — green overlay + irregular shake + X `{ }` eyes + sweat drops
    private var sickScene: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                let shake = sin(t * 7) * 0.9 + sin(t * 13.5) * 0.5
                let float = sin(t * .pi * 2 / 5.0) * 0.4
                Canvas { c, sz in
                    let v = V(sz, svgW: 15, svgH: 12, svgY0: 4)
                    drawShadow(c, v: v, opacity: 0.15)
                    drawLegs(c, v: v)
                    c.translateBy(x: shake * v.s, y: 0)
                    // Green tinted block
                    let bodyRows: [(y: CGFloat, x: CGFloat, w: CGFloat)] = [
                        (5, 3, 9), (6, 2, 11), (7, 2, 11), (8, 2, 11),
                        (9, 2, 11), (10, 2, 11), (11, 2, 11), (12, 2, 11), (13, 3, 9),
                    ]
                    for row in bodyRows {
                        c.fill(Path(v.r(row.x, row.y, row.w, 1, dy: float)),
                               with: .color(Color(red: 0.3, green: 0.55, blue: 0.35).opacity(0.90)))
                    }
                    // X-shaped `{ }` eye substitutes
                    let eyePositions: [(CGFloat, CGFloat)] = [(4.0, 8.0), (9.2, 8.0)]
                    for (ex, ey) in eyePositions {
                        c.fill(Path(v.r(ex,       ey,       0.7, 0.7, dy: float)), with: .color(Self.faceC))
                        c.fill(Path(v.r(ex + 0.7, ey + 0.7, 0.7, 0.7, dy: float)), with: .color(Self.faceC))
                        c.fill(Path(v.r(ex + 0.7, ey,       0.7, 0.7, dy: float)), with: .color(Self.faceC))
                        c.fill(Path(v.r(ex,       ey + 0.7, 0.7, 0.7, dy: float)), with: .color(Self.faceC))
                    }
                    c.translateBy(x: -shake * v.s, y: 0)
                }
            }
            TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                ZStack {
                    ForEach(0..<3, id: \.self) { i in
                        let ci = Double(i)
                        let cycle = 1.6 + ci * 0.4
                        let delay = ci * 0.55
                        let p = max(0, ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle)
                        let xOff = size * CGFloat(-0.15 + ci * 0.16)
                        let yOff = size * CGFloat(0.08 + p * 0.35)
                        let op = p < 0.6 ? 0.75 : (1.0 - p) * 1.875 * 0.75
                        Circle()
                            .fill(Color(red: 0.4, green: 0.9, blue: 0.6).opacity(op))
                            .frame(width: size * 0.065, height: size * 0.09)
                            .offset(x: xOff, y: yOff)
                    }
                }
            }
        }
    }

    // JOYFUL — bouncing block + bright face + dual sparkle ring
    private var joyfulScene: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                let jumpPhase = t.truncatingRemainder(dividingBy: 1.2) / 1.2
                let jumpY: CGFloat = jumpPhase < 0.35
                    ? CGFloat(-sin(jumpPhase / 0.35 * .pi) * 2.8)
                    : 0
                let squashY: CGFloat = jumpPhase > 0.38 && jumpPhase < 0.52
                    ? CGFloat(1.0 - (jumpPhase - 0.38) / 0.14 * 0.12)
                    : 1.0
                Canvas { c, sz in
                    let v = V(sz, svgW: 15, svgH: 12, svgY0: 4)
                    let shadowW: CGFloat = 8 + abs(jumpY) * 0.4
                    let shadowOp: Double = max(0.10, 0.22 - Double(abs(jumpY)) * 0.025)
                    drawShadow(c, v: v, width: shadowW, opacity: shadowOp)
                    drawLegs(c, v: v)
                    drawBlock(c, v: v, dy: jumpY, squashX: 1.0, squashY: squashY)
                    drawFace(c, v: v, dy: jumpY, color: Self.faceC, eyeScale: 1.3)
                }
            }
            TimelineView(.periodic(from: .now, by: 0.04)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                ZStack {
                    ForEach(0..<6, id: \.self) { i in
                        let ci = Double(i)
                        let cycle = 1.3 + ci * 0.15
                        let delay = ci * 0.22
                        let phase = ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle
                        let p = max(0, phase)
                        let angle = ci * 60.0 * .pi / 180.0
                        let r = size * CGFloat(0.28 + p * 0.16)
                        let op = p < 0.60 ? 1.0 : (1.0 - p) * 2.5
                        Text("✦")
                            .font(.system(size: max(5, size * 0.155)))
                            .foregroundStyle(Color(red: 1.0, green: 0.85, blue: 0.0).opacity(op))
                            .offset(x: r * CGFloat(cos(angle)), y: r * CGFloat(sin(angle)) - size * 0.08)
                    }
                    ForEach(0..<6, id: \.self) { i in
                        let ci = Double(i)
                        let cycle = 1.8 + ci * 0.18
                        let delay = ci * 0.30 + 0.11
                        let phase = ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle
                        let p = max(0, phase)
                        let angle = (ci * 60.0 + 30.0) * .pi / 180.0
                        let r = size * CGFloat(0.38 + p * 0.14)
                        let op = p < 0.55 ? 0.85 : (1.0 - p) * 1.89 * 0.85
                        Text("✦")
                            .font(.system(size: max(4, size * 0.10)))
                            .foregroundStyle(Color(red: 1.0, green: 1.0, blue: 0.6).opacity(op))
                            .offset(x: r * CGFloat(cos(angle)), y: r * CGFloat(sin(angle)) - size * 0.06)
                    }
                }
            }
        }
    }

    // ━━━━━━ SLEEP ━━━━━━
    private var sleepScene: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.06)) { ctx in
                sleepCanvas(t: ctx.date.timeIntervalSinceReferenceDate * speed)
            }
            TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                floatingZs(t: ctx.date.timeIntervalSinceReferenceDate * speed)
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
                let baseOp = 0.7 - ci * 0.1
                let opacity = phase < 0.8 ? baseOp : (1.0 - phase) * 3.5 * baseOp
                Text("z")
                    .font(.system(size: fontSize, weight: .black, design: .monospaced))
                    .foregroundStyle(.white.opacity(opacity))
                    .offset(x: size * CGFloat(0.15 + ci * 0.08),
                            y: -size * CGFloat(0.15 + phase * 0.38))
            }
        }
    }

    private func sleepCanvas(t: Double) -> some View {
        let phase = t.truncatingRemainder(dividingBy: 4.0) / 4.0
        let float = sin(phase * .pi * 2) * 0.8

        return Canvas { c, sz in
            let v = V(sz, svgW: 15, svgH: 12, svgY0: 4)
            drawShadow(c, v: v, width: 7 + abs(float) * 0.3, opacity: 0.2)
            drawLegs(c, v: v)
            drawBlock(c, v: v, dy: float)
            drawFace(c, v: v, dy: float, color: Self.faceC.opacity(0.4), eyeScale: 0.3)
        }
    }

    // ━━━━━━ WORK ━━━━━━
    private var workScene: some View {
        TimelineView(.periodic(from: .now, by: 0.03)) { ctx in
            workCanvas(t: ctx.date.timeIntervalSinceReferenceDate * speed)
        }
    }

    private func workCanvas(t: Double) -> some View {
        let bounce = sin(t * 2 * .pi / 0.4) * 1.0
        let blinkCycle = t.truncatingRemainder(dividingBy: 3.0)
        let blink: CGFloat = (blinkCycle > 2.6 && blinkCycle < 2.75) ? 0.1 : 1.0
        let keyPhase = Int(t / 0.1) % 6

        return Canvas { c, sz in
            let v = V(sz, svgW: 16, svgH: 14, svgY0: 3)

            let shadowW: CGFloat = 8 - abs(bounce) * 0.3
            c.fill(Path(v.r(4 + (8 - shadowW) / 2, 16, shadowW, 1)),
                   with: .color(.black.opacity(max(0.1, 0.35 - abs(bounce) * 0.03))))

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
            let fCol = keyPhase % 6
            let fRow = keyPhase / 3
            c.fill(Path(v.r(0.5 + CGFloat(fCol) * 2.4, 13.5 + CGFloat(fRow) * 1.2, 1.8, 0.7)),
                   with: .color(Self.kbHi.opacity(0.9)))

            drawBlock(c, v: v, dy: bounce)
            drawFace(c, v: v, dy: bounce, eyeScale: blink)
        }
    }

    // ━━━━━━ ALERT ━━━━━━
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
        let shakeX: CGFloat = (pct > 0.15 && pct < 0.55) ? sin(pct * 80) * 0.6 : 0

        let bangOp = lerp([
            (0, 0), (0.03, 1), (0.10, 1), (0.55, 1), (0.62, 0), (1.0, 0),
        ], at: pct)
        let bangScale = lerp([
            (0, 0.3), (0.03, 1.3), (0.10, 1.0), (0.55, 1.0), (0.62, 0.6), (1.0, 0.6),
        ], at: pct)

        return Canvas { c, sz in
            let v = V(sz, svgW: 16, svgH: 14, svgY0: 3)

            let shadowW: CGFloat = 8 * (1.0 - abs(min(0, jumpY)) * 0.04)
            c.fill(Path(v.r(4 + (8 - shadowW) / 2, 16, shadowW, 1)),
                   with: .color(.black.opacity(max(0.08, 0.4 - abs(min(0, jumpY)) * 0.04))))

            drawLegs(c, v: v)

            c.translateBy(x: shakeX * v.s, y: 0)
            drawBlock(c, v: v, dy: jumpY, squashX: squashX, squashY: squashY)
            drawFace(c, v: v, dy: jumpY, eyeScale: pct > 0.03 && pct < 0.15 ? 1.3 : 1.0)
            c.translateBy(x: -shakeX * v.s, y: 0)

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
}
