import SwiftUI
import CodeIslandCore

/// Gemini — Google Gemini CLI mascot, four-pointed sparkle star.
/// Blue→Purple→Rose gradient (#4796E4 → #847ACE → #C3677F).
struct GeminiView: View {
    let status: AgentStatus
    var mood: MascotMood = .neutral
    var size: CGFloat = 27
    var animated: Bool = true
    @State private var alive = false
    @Environment(\.mascotSpeed) private var speed

    // Gemini brand gradient
    private static let blueC  = Color(red: 0.278, green: 0.588, blue: 0.894) // #4796E4
    private static let purpC  = Color(red: 0.518, green: 0.478, blue: 0.808) // #847ACE
    private static let roseC  = Color(red: 0.765, green: 0.404, blue: 0.498) // #C3677F
    private static let faceC  = Color.white
    private static let alertC = Color(red: 1.0, green: 0.24, blue: 0.0)
    private static let kbBase = Color(red: 0.22, green: 0.25, blue: 0.38)
    private static let kbKey  = Color(red: 0.40, green: 0.44, blue: 0.58)
    private static let kbHi   = Color.white

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

    // ── Draw sparkle star body — 4-pointed star with gradient fill ──
    private func drawStar(_ c: GraphicsContext, v: V, dy: CGFloat,
                          scale: CGFloat = 1.0, rotate: CGFloat = 0) {
        let cx: CGFloat = 7.5, cy: CGFloat = 10.0
        let outerR: CGFloat = 4.5 * scale
        let innerR: CGFloat = 1.8 * scale
        let rot = rotate * .pi / 180

        var path = Path()
        for i in 0..<8 {
            let angle = CGFloat(i) * .pi / 4 - .pi / 2 + rot
            let r = i % 2 == 0 ? outerR : innerR
            let px = cx + cos(angle) * r
            let py = cy + sin(angle) * r
            let pt = CGPoint(x: v.ox + px * v.s, y: v.oy + (py - v.y0 + dy) * v.s)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        path.closeSubpath()

        // Gradient fill (top-left blue → bottom-right rose)
        let topPt = CGPoint(x: v.ox + (cx - outerR) * v.s, y: v.oy + (cy - outerR - v.y0 + dy) * v.s)
        let botPt = CGPoint(x: v.ox + (cx + outerR) * v.s, y: v.oy + (cy + outerR - v.y0 + dy) * v.s)
        c.fill(path, with: .linearGradient(
            Gradient(colors: [Self.blueC, Self.purpC, Self.roseC]),
            startPoint: topPt, endPoint: botPt))
    }

    // ── Draw face: two dot eyes ──
    private func drawFace(_ c: GraphicsContext, v: V, dy: CGFloat,
                          eyeScale: CGFloat = 1.0, blinkPhase: CGFloat = 1.0) {
        let eyeH: CGFloat = 1.5 * eyeScale * blinkPhase
        let eyeY: CGFloat = 9.5 + (1.5 - eyeH) / 2
        c.fill(Path(v.r(5.5, eyeY, 1.2, max(0.3, eyeH), dy: dy)), with: .color(Self.faceC))
        c.fill(Path(v.r(8.3, eyeY, 1.2, max(0.3, eyeH), dy: dy)), with: .color(Self.faceC))
    }

    // ── Shadow ──
    private func drawShadow(_ c: GraphicsContext, v: V, width: CGFloat = 7, opacity: Double = 0.3) {
        c.fill(Path(v.r(7.5 - width / 2, 15, width, 1)),
               with: .color(.black.opacity(opacity)))
    }

    // ── Small legs (partially follow body) ──
    private func drawLegs(_ c: GraphicsContext, v: V, dy: CGFloat = 0) {
        let legDy = dy * 0.3  // legs follow body at 30% amplitude
        c.fill(Path(v.r(5.5, 14, 1, 2, dy: legDy)), with: .color(Self.purpC.opacity(0.7)))
        c.fill(Path(v.r(8.5, 14, 1, 2, dy: legDy)), with: .color(Self.purpC.opacity(0.7)))
    }

    /// Dispatches to the correct idle scene based on mood.
    @ViewBuilder
    private var idleMoodScene: some View {
        switch mood {
        case .hungry:  hungryScene
        case .critical:   tiredScene
        case .tired:   tiredScene
        case .sad:     sadScene
        case .sick:    sickScene
        case .joyful:  joyfulScene
        case .neutral: sleepScene
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
                let xOff = size * CGFloat(0.15 + ci * 0.08 + sin(phase * .pi * 2) * 0.03)
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
        let float = sin(phase * .pi * 2) * 0.8
        let slowSpin = sin(phase * .pi * 2) * 5  // gentle rotation
        let blinkCycle = t.truncatingRemainder(dividingBy: 4.0)
        let blink: CGFloat = (blinkCycle > 3.5 && blinkCycle < 3.7) ? 0.15 : 0.5  // sleepy but visible

        return Canvas { c, sz in
            let v = V(sz, svgW: 15, svgH: 12, svgY0: 4)
            drawShadow(c, v: v, width: 6 + abs(float) * 0.3, opacity: 0.2)
            drawLegs(c, v: v, dy: float)
            drawStar(c, v: v, dy: float, scale: 0.9, rotate: slowSpin)
            drawFace(c, v: v, dy: float, blinkPhase: blink)
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
        let spin = sin(t * 2 * .pi / 1.2) * 15  // gentle wobble, not full rotation
        let blinkCycle = t.truncatingRemainder(dividingBy: 2.5)
        let blink: CGFloat = (blinkCycle > 2.2 && blinkCycle < 2.35) ? 0.1 : 1.0
        let keyPhase = Int(t / 0.1) % 6

        return Canvas { c, sz in
            let v = V(sz, svgW: 16, svgH: 14, svgY0: 3)
            let dy = bounce

            // Shadow
            let shadowW: CGFloat = 7 - abs(dy) * 0.3
            c.fill(Path(v.r(4 + (7 - shadowW) / 2, 16, shadowW, 1)),
                   with: .color(.black.opacity(max(0.1, 0.35 - abs(dy) * 0.03))))

            drawLegs(c, v: v, dy: dy)

            // Keyboard
            c.fill(Path(v.r(0, 13, 15, 3)), with: .color(Self.kbBase))
            for row in 0..<2 {
                let ky = 13.5 + CGFloat(row) * 1.2
                for col in 0..<6 {
                    let kx = 0.5 + CGFloat(col) * 2.4
                    c.fill(Path(v.r(kx, ky, 1.8, 0.7)), with: .color(Self.kbKey))
                }
            }
            let flashRow = keyPhase / 3
            let flashCol = keyPhase % 6
            c.fill(Path(v.r(0.5 + CGFloat(flashCol) * 2.4, 13.5 + CGFloat(flashRow) * 1.2, 1.8, 0.7)),
                   with: .color(Self.kbHi.opacity(0.9)))

            drawStar(c, v: v, dy: dy, scale: 1.0, rotate: spin)
            drawFace(c, v: v, dy: dy, blinkPhase: blink)
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MOOD SCENES — idle variants for Gemini (sparkle star mascot)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // HUNGRY — irregular wobble + bigger float + food emojis + rumble glow
    private var hungryScene: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                let float = sin(t * .pi * 2 / 4.0) * 1.5
                let wobble = sin(t * 7) * 0.9 + sin(t * 13.5) * 0.4
                let spinWobble = sin(t * 5) * 8.0
                Canvas { c, sz in
                    let v = V(sz, svgW: 15, svgH: 12, svgY0: 4)
                    drawShadow(c, v: v, width: 7 + abs(float) * 0.4, opacity: 0.22)
                    drawLegs(c, v: v, dy: float + wobble)
                    drawStar(c, v: v, dy: float + wobble, scale: 0.9, rotate: spinWobble)
                    // Open hungry mouth — wide ellipse below eyes
                    c.fill(Path(ellipseIn: v.r(5.5, 11.8, 4.0, 1.6, dy: float + wobble)),
                           with: .color(Self.faceC.opacity(0.9)))
                    // Rumble belly dots (3 glow circles below body)
                    let rumble: CGFloat = sin(t * 18) > 0 ? 0.5 : 0.0
                    for i: CGFloat in [0, 1, 2] {
                        let dotR = v.r(5.0 + i * 1.8, 13.2 + rumble * 0.2, 1.0, 1.0, dy: float + wobble)
                        c.fill(Path(ellipseIn: dotR),
                               with: .color(Color(red: 1.0, green: 0.6, blue: 0.1).opacity(0.55)))
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

    // TIRED — slow nodding + half-open eyes + two large Zs
    private var tiredScene: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.06)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                let nodPhase = t.truncatingRemainder(dividingBy: 3.2) / 3.2
                let nod: CGFloat = nodPhase < 0.6
                    ? CGFloat(sin(nodPhase / 0.6 * .pi)) * 2.0 : 0
                let slowSpin = sin(t * .pi * 2 / 8.0) * 3
                Canvas { c, sz in
                    let v = V(sz, svgW: 15, svgH: 12, svgY0: 4)
                    drawShadow(c, v: v, opacity: 0.14)
                    drawLegs(c, v: v, dy: nod)
                    drawStar(c, v: v, dy: nod, scale: 0.85, rotate: slowSpin)
                    // Half-open droopy eyes: thin horizontal bars
                    c.fill(Path(v.r(5.0, 9.8, 1.4, 0.45, dy: nod)),
                           with: .color(Self.faceC.opacity(0.65)))
                    c.fill(Path(v.r(8.0, 9.8, 1.4, 0.45, dy: nod)),
                           with: .color(Self.faceC.opacity(0.65)))
                }
            }
            TimelineView(.periodic(from: .now, by: 0.07)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                ZStack {
                    ForEach(0..<2, id: \.self) { i in
                        let ci = Double(i)
                        let cycle = 3.8 + ci * 0.6
                        let delay = ci * 1.6
                        let p = max(0, ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle)
                        let fontSize = max(7, size * CGFloat(0.24 + p * 0.10 + ci * 0.03))
                        let op = p < 0.78 ? 0.72 : (1.0 - p) * 3.43 * 0.72
                        Text("z")
                            .font(.system(size: fontSize, weight: .black, design: .monospaced))
                            .foregroundStyle(Color(red: 0.55, green: 0.65, blue: 1.0).opacity(op))
                            .offset(x: size * CGFloat(0.10 + ci * 0.12),
                                    y: -size * CGFloat(0.10 + p * 0.40))
                    }
                }
            }
        }
    }

    // SAD — dim body opacity + blue tint + two tears + droopy eyes
    private var sadScene: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.06)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                let float = sin(t * .pi * 2 / 4.5) * 0.5
                Canvas { c, sz in
                    let v = V(sz, svgW: 15, svgH: 12, svgY0: 4)
                    drawShadow(c, v: v, opacity: 0.18)
                    drawLegs(c, v: v, dy: float)
                    // Dim star at 70% opacity
                    var gctx = c
                    gctx.opacity = 0.70
                    drawStar(gctx, v: v, dy: float, scale: 0.9, rotate: 0)
                    // Blue cold overlay on star body area
                    let starR = v.r(3.5, 6.0, 8.0, 8.0, dy: float)
                    c.fill(Path(ellipseIn: starR),
                           with: .color(Color(red: 0.3, green: 0.5, blue: 0.9).opacity(0.13)))
                    // Droopy downward eyes (inverted arc via two angled rects)
                    c.fill(Path(v.r(5.0, 10.3, 1.4, 0.5, dy: float)),
                           with: .color(Self.faceC.opacity(0.75)))
                    c.fill(Path(v.r(8.0, 10.3, 1.4, 0.5, dy: float)),
                           with: .color(Self.faceC.opacity(0.75)))
                    // Frown mouth below eyes
                    c.fill(Path(v.r(5.5, 11.5, 0.8, 0.5, dy: float)),
                           with: .color(Self.faceC.opacity(0.55)))
                    c.fill(Path(v.r(6.3, 11.8, 2.0, 0.5, dy: float)),
                           with: .color(Self.faceC.opacity(0.55)))
                    c.fill(Path(v.r(8.3, 11.5, 0.8, 0.5, dy: float)),
                           with: .color(Self.faceC.opacity(0.55)))
                }
            }
            TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                ZStack {
                    ForEach(0..<2, id: \.self) { i in
                        let ci = Double(i)
                        let cycle = 1.8 + ci * 0.5
                        let delay = ci * 0.85
                        let pp = max(0, ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle)
                        let op = pp < 0.65 ? 0.80 : (1.0 - pp) * 2.29 * 0.80
                        Circle()
                            .fill(Color(red: 0.25, green: 0.55, blue: 1.0).opacity(op))
                            .frame(width: size * 0.075, height: size * 0.12)
                            .offset(x: size * CGFloat(-0.08 + ci * 0.18),
                                    y: size * CGFloat(0.04 + pp * 0.42))
                    }
                }
            }
        }
    }

    // SICK — dual-freq shake + green tint overlay + X eyes + sweat drops
    private var sickScene: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                let shake = sin(t * 7) * 0.9 + sin(t * 13.5) * 0.5
                let float = sin(t * .pi * 2 / 5.0) * 0.4
                Canvas { c, sz in
                    let v = V(sz, svgW: 15, svgH: 12, svgY0: 4)
                    drawShadow(c, v: v, opacity: 0.15)
                    drawLegs(c, v: v, dy: float)
                    c.translateBy(x: shake * v.s, y: 0)
                    // Sickly green-tinted star
                    let sickColors = [
                        Color(red: 0.20, green: 0.60, blue: 0.38),
                        Color(red: 0.30, green: 0.50, blue: 0.55),
                        Color(red: 0.20, green: 0.48, blue: 0.42),
                    ]
                    c.fill(Path(ellipseIn: v.r(3.5, 6.0, 8.0, 8.0, dy: float)),
                           with: .linearGradient(
                               Gradient(colors: sickColors),
                               startPoint: CGPoint(x: v.ox + 3.5 * v.s, y: v.oy + 6.0 * v.s),
                               endPoint:   CGPoint(x: v.ox + 11.5 * v.s, y: v.oy + 14.0 * v.s)))
                    drawStar(c, v: v, dy: float, scale: 0.88, rotate: 0)
                    // Green sick overlay
                    c.fill(Path(ellipseIn: v.r(3.5, 6.0, 8.0, 8.0, dy: float)),
                           with: .color(Color(red: 0.2, green: 0.78, blue: 0.3).opacity(0.15)))
                    // X eyes (4-pixel cross per eye)
                    let eyePositions: [(CGFloat, CGFloat)] = [(5.0, 9.2), (7.8, 9.2)]
                    for (ex, ey) in eyePositions {
                        c.fill(Path(v.r(ex, ey, 0.7, 0.7, dy: float)), with: .color(Self.faceC.opacity(0.9)))
                        c.fill(Path(v.r(ex + 0.7, ey + 0.7, 0.7, 0.7, dy: float)), with: .color(Self.faceC.opacity(0.9)))
                        c.fill(Path(v.r(ex + 0.7, ey, 0.7, 0.7, dy: float)), with: .color(Self.faceC.opacity(0.9)))
                        c.fill(Path(v.r(ex, ey + 0.7, 0.7, 0.7, dy: float)), with: .color(Self.faceC.opacity(0.9)))
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
                        let pp = max(0, ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle)
                        let op = pp < 0.6 ? 0.75 : (1.0 - pp) * 1.875 * 0.75
                        Circle()
                            .fill(Color(red: 0.4, green: 0.9, blue: 0.6).opacity(op))
                            .frame(width: size * 0.065, height: size * 0.09)
                            .offset(x: size * CGFloat(-0.15 + ci * 0.16),
                                    y: size * CGFloat(0.08 + pp * 0.35))
                    }
                }
            }
        }
    }

    // JOYFUL — bouncy jump + 12-particle double ring sparkles
    private var joyfulScene: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                let jumpPhase = t.truncatingRemainder(dividingBy: 1.2) / 1.2
                let jumpY: CGFloat = jumpPhase < 0.35
                    ? CGFloat(-sin(jumpPhase / 0.35 * .pi) * 2.8) : 0
                let squashY: CGFloat = jumpPhase > 0.38 && jumpPhase < 0.52
                    ? CGFloat(1.0 - (jumpPhase - 0.38) / 0.14 * 0.12) : 1.0
                let spin = t * 30  // continuous gentle spin when joyful
                let blinkCycle = t.truncatingRemainder(dividingBy: 0.7)
                let blink: CGFloat = blinkCycle < 0.42 ? 1.0 : 0.6
                Canvas { c, sz in
                    let v = V(sz, svgW: 15, svgH: 12, svgY0: 4)
                    let shadowW: CGFloat = 7 + abs(jumpY) * 0.4
                    let shadowOp: Double = max(0.10, 0.22 - Double(abs(jumpY)) * 0.025)
                    drawShadow(c, v: v, width: shadowW, opacity: shadowOp)
                    drawLegs(c, v: v, dy: jumpY)
                    drawStar(c, v: v, dy: jumpY, scale: 1.0 * squashY, rotate: spin)
                    drawFace(c, v: v, dy: jumpY, blinkPhase: blink)
                }
            }
            TimelineView(.periodic(from: .now, by: 0.04)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                ZStack {
                    ForEach(0..<6, id: \.self) { i in
                        let ci = Double(i)
                        let cycle = 1.3 + ci * 0.15
                        let delay = ci * 0.22
                        let p = max(0, ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle)
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
                        let p = max(0, ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle)
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

        let shakeX: CGFloat = (pct > 0.15 && pct < 0.55) ? sin(pct * 80) * 0.6 : 0
        let pulseScale: CGFloat = (pct > 0.03 && pct < 0.55)
            ? 1.0 + sin(pct * 20) * 0.15 : 1.0

        let bangOp = lerp([
            (0, 0), (0.03, 1), (0.10, 1), (0.55, 1), (0.62, 0), (1.0, 0),
        ], at: pct)
        let bangScale = lerp([
            (0, 0.3), (0.03, 1.3), (0.10, 1.0), (0.55, 1.0), (0.62, 0.6), (1.0, 0.6),
        ], at: pct)

        return Canvas { c, sz in
            let v = V(sz, svgW: 16, svgH: 14, svgY0: 3)

            // Shadow
            let shadowW: CGFloat = 7 * (1.0 - abs(min(0, jumpY)) * 0.04)
            c.fill(Path(v.r(4 + (7 - shadowW) / 2, 16, shadowW, 1)),
                   with: .color(.black.opacity(max(0.08, 0.4 - abs(min(0, jumpY)) * 0.04))))

            drawLegs(c, v: v, dy: jumpY)

            c.translateBy(x: shakeX * v.s, y: 0)
            drawStar(c, v: v, dy: jumpY, scale: pulseScale, rotate: 0)
            drawFace(c, v: v, dy: jumpY, eyeScale: pct > 0.03 && pct < 0.15 ? 1.3 : 1.0)
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
}
