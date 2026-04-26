import SwiftUI
import CodeIslandCore

/// AntiGravityBot — AntiGravity mascot, rainbow gradient swoosh character.
/// Multicolor gradient inspired by the AntiGravity "A" logo.
struct AntiGravityView: View {
    let status: AgentStatus
    var mood: MascotMood = .neutral
    var size: CGFloat = 27
    var animated: Bool = true
    @State private var alive = false
    @Environment(\.mascotSpeed) private var speed

    private static let color1  = Color(red: 0.30, green: 0.50, blue: 0.95) // blue
    private static let color2  = Color(red: 0.60, green: 0.35, blue: 0.90) // purple
    private static let color3  = Color(red: 0.90, green: 0.40, blue: 0.55) // pink
    private static let color4  = Color(red: 0.95, green: 0.60, blue: 0.30) // orange
    private static let faceC   = Color.white
    private static let alertC  = Color(red: 1.0, green: 0.24, blue: 0.0)
    private static let kbBase  = Color(red: 0.18, green: 0.16, blue: 0.25)
    private static let kbKey   = Color(red: 0.32, green: 0.28, blue: 0.40)
    private static let kbHi    = Color.white

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

    // ── Draw "A" shaped body with rainbow gradient ──
    private func drawBody(_ c: GraphicsContext, v: V, dy: CGFloat, scale: CGFloat = 1.0) {
        let cx: CGFloat = 7.5, cy: CGFloat = 10.0
        let hw: CGFloat = 5.0 * scale, hh: CGFloat = 6.0 * scale
        // Triangle "A" shape
        var path = Path()
        let top = CGPoint(x: v.ox + cx * v.s, y: v.oy + (cy - hh - v.y0 + dy) * v.s)
        let botL = CGPoint(x: v.ox + (cx - hw) * v.s, y: v.oy + (cy + hh * 0.3 - v.y0 + dy) * v.s)
        let botR = CGPoint(x: v.ox + (cx + hw) * v.s, y: v.oy + (cy + hh * 0.3 - v.y0 + dy) * v.s)
        path.move(to: top)
        path.addLine(to: botR)
        path.addLine(to: botL)
        path.closeSubpath()
        c.fill(path, with: .linearGradient(
            Gradient(colors: [Self.color1, Self.color2, Self.color3, Self.color4]),
            startPoint: CGPoint(x: v.ox + (cx - hw) * v.s, y: top.y),
            endPoint: CGPoint(x: v.ox + (cx + hw) * v.s, y: botR.y)))
    }

    private func drawFace(_ c: GraphicsContext, v: V, dy: CGFloat, blinkPhase: CGFloat = 1.0) {
        let eyeH: CGFloat = 1.5 * blinkPhase
        let eyeY: CGFloat = 9.0 + (1.5 - eyeH) / 2
        c.fill(Path(v.r(5.5, eyeY, 1.2, max(0.3, eyeH), dy: dy)), with: .color(Self.faceC))
        c.fill(Path(v.r(8.3, eyeY, 1.2, max(0.3, eyeH), dy: dy)), with: .color(Self.faceC))
    }

    private func drawShadow(_ c: GraphicsContext, v: V, width: CGFloat = 7, opacity: Double = 0.3) {
        c.fill(Path(v.r(7.5 - width / 2, 15, width, 1)), with: .color(.black.opacity(opacity)))
    }

    private func drawLegs(_ c: GraphicsContext, v: V, dy: CGFloat = 0) {
        let legDy = dy * 0.3
        c.fill(Path(v.r(5.5, 14, 1, 2, dy: legDy)), with: .color(Self.color2.opacity(0.7)))
        c.fill(Path(v.r(8.5, 14, 1, 2, dy: legDy)), with: .color(Self.color3.opacity(0.7)))
    }

    // ━━━━━━ IDLE MOOD DISPATCH ━━━━━━
    @ViewBuilder
    private var idleMoodScene: some View {
        switch mood {
        case .hungry:  agHungryScene
        case .tired:   agTiredScene
        case .sad:     agSadScene
        case .sick:    agSickScene
        case .joyful:  agJoyfulScene
        case .neutral: sleepScene
        }
    }

    // ── HUNGRY: irregular wobble + open mouth + food emojis ──
    private var agHungryScene: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.06)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                let float = sin(t * .pi * 2 / 4.0) * 1.5
                let wobble = sin(t * 10) * 0.7
                Canvas { c, sz in
                    let v = V(sz, svgW: 15, svgH: 12, svgY0: 4)
                    drawShadow(c, v: v, width: 6 + abs(float) * 0.4, opacity: 0.22)
                    drawLegs(c, v: v, dy: float + wobble)
                    drawBody(c, v: v, dy: float + wobble, scale: 0.9)
                    // open mouth: wide gap below eyes
                    c.fill(Path(v.r(5.5, 10.5, 4.0, 1.8, dy: float + wobble)),
                           with: .color(Self.faceC.opacity(0.85)))
                    // belly rumble dots
                    let rumble = sin(t * 18) * 0.3
                    for i: CGFloat in [0, 1, 2] {
                        c.fill(Path(v.r(4.5 + i * 2, 11.8 + rumble, 0.8, 0.8, dy: float + wobble)),
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

    // ── TIRED: slow nod + half-closed eyes + 2 large Zs ──
    private var agTiredScene: some View {
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
                    drawLegs(c, v: v, dy: nod)
                    drawBody(c, v: v, dy: nod, scale: 0.88)
                    // half-closed eyes: thin bars
                    c.fill(Path(v.r(5.0, 9.0, 1.2, 0.5, dy: nod)), with: .color(Self.faceC.opacity(0.7)))
                    c.fill(Path(v.r(7.8, 9.0, 1.2, 0.5, dy: nod)), with: .color(Self.faceC.opacity(0.7)))
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
                        let fontSize = max(7, size * CGFloat(0.22 + p * 0.10 + ci * 0.03))
                        let op = p < 0.78 ? 0.72 : (1.0 - p) * 3.43 * 0.72
                        let yOff = -size * CGFloat(0.10 + p * 0.40)
                        let xOff = size * CGFloat(0.10 + ci * 0.14)
                        Text("z")
                            .font(.system(size: fontSize, weight: .black, design: .monospaced))
                            .foregroundStyle(Color(red: 0.55, green: 0.65, blue: 1.0).opacity(op))
                            .offset(x: xOff, y: yOff)
                    }
                }
            }
        }
    }

    // ── SAD: blue-cold tint + inverted V brow + 2 tears + opacity ~0.7 ──
    private var agSadScene: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.06)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                let float = sin(t * .pi * 2 / 4.5) * 0.5
                Canvas { c, sz in
                    let v = V(sz, svgW: 15, svgH: 12, svgY0: 4)
                    drawShadow(c, v: v, opacity: 0.18)
                    drawLegs(c, v: v, dy: float)
                    var gctx = c
                    gctx.opacity = 0.68
                    drawBody(gctx, v: v, dy: float, scale: 0.9)
                    drawFace(c, v: v, dy: float)
                    // cold blue tint
                    c.fill(Path(v.r(2.5, 4, 10, 8, dy: float)),
                           with: .color(Color(red: 0.3, green: 0.5, blue: 0.9).opacity(0.10)))
                    // inverted V brows
                    c.fill(Path(v.r(5.0, 7.8, 0.6, 0.6, dy: float)), with: .color(Self.faceC.opacity(0.8)))
                    c.fill(Path(v.r(5.6, 7.3, 0.6, 0.6, dy: float)), with: .color(Self.faceC.opacity(0.8)))
                    c.fill(Path(v.r(6.2, 7.8, 0.6, 0.6, dy: float)), with: .color(Self.faceC.opacity(0.8)))
                    c.fill(Path(v.r(7.8, 7.8, 0.6, 0.6, dy: float)), with: .color(Self.faceC.opacity(0.8)))
                    c.fill(Path(v.r(8.4, 7.3, 0.6, 0.6, dy: float)), with: .color(Self.faceC.opacity(0.8)))
                    c.fill(Path(v.r(9.0, 7.8, 0.6, 0.6, dy: float)), with: .color(Self.faceC.opacity(0.8)))
                }
            }
            TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                ZStack {
                    ForEach(0..<2, id: \.self) { i in
                        let ci = Double(i)
                        let cycle = 1.8 + ci * 0.5
                        let delay = ci * 0.85
                        let p = max(0, ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle)
                        let yOff = size * CGFloat(0.04 + p * 0.42)
                        let xOff = size * CGFloat(-0.08 + ci * 0.18)
                        let op = p < 0.65 ? 0.80 : (1.0 - p) * 2.29 * 0.80
                        Circle()
                            .fill(Color(red: 0.25, green: 0.55, blue: 1.0).opacity(op))
                            .frame(width: size * 0.075, height: size * 0.12)
                            .offset(x: xOff, y: yOff)
                    }
                }
            }
        }
    }

    // ── SICK: dual-freq shake + green body tint + X eyes + 3 green sweat drops ──
    private var agSickScene: some View {
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
                    // green-tinted triangle body
                    let cx: CGFloat = 7.5, cy: CGFloat = 10.0
                    let hw: CGFloat = 5.0 * 0.9, hh: CGFloat = 6.0 * 0.9
                    var path = Path()
                    let top = CGPoint(x: v.ox + cx * v.s, y: v.oy + (cy - hh - v.y0 + float) * v.s)
                    let botL = CGPoint(x: v.ox + (cx - hw) * v.s, y: v.oy + (cy + hh * 0.3 - v.y0 + float) * v.s)
                    let botR = CGPoint(x: v.ox + (cx + hw) * v.s, y: v.oy + (cy + hh * 0.3 - v.y0 + float) * v.s)
                    path.move(to: top); path.addLine(to: botR); path.addLine(to: botL)
                    path.closeSubpath()
                    c.fill(path, with: .color(Color(red: 0.35, green: 0.75, blue: 0.40).opacity(0.88)))
                    // green overlay
                    c.fill(Path(v.r(2.5, 4, 10, 8, dy: float)),
                           with: .color(Color(red: 0.2, green: 0.85, blue: 0.3).opacity(0.12)))
                    // X eyes
                    let eyePositions: [(CGFloat, CGFloat)] = [(5.0, 8.5), (7.8, 8.5)]
                    for (ex, ey) in eyePositions {
                        c.fill(Path(v.r(ex,       ey,       0.8, 0.8, dy: float)), with: .color(Self.faceC.opacity(0.9)))
                        c.fill(Path(v.r(ex + 0.8, ey + 0.8, 0.8, 0.8, dy: float)), with: .color(Self.faceC.opacity(0.9)))
                        c.fill(Path(v.r(ex + 0.8, ey,       0.8, 0.8, dy: float)), with: .color(Self.faceC.opacity(0.9)))
                        c.fill(Path(v.r(ex,       ey + 0.8, 0.8, 0.8, dy: float)), with: .color(Self.faceC.opacity(0.9)))
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

    // ── JOYFUL: 12-particle dual ring + bouncy triangle ──
    private var agJoyfulScene: some View {
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
                    let shadowW: CGFloat = 6 + abs(jumpY) * 0.4
                    let shadowOp: Double = max(0.10, 0.22 - Double(abs(jumpY)) * 0.025)
                    drawShadow(c, v: v, width: shadowW, opacity: shadowOp)
                    drawLegs(c, v: v, dy: jumpY)
                    drawBody(c, v: v, dy: jumpY, scale: 0.9 * squashY)
                    drawFace(c, v: v, dy: jumpY, blinkPhase: 1.2)
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
                        let xOff = r * CGFloat(cos(angle))
                        let yOff = r * CGFloat(sin(angle)) - size * 0.08
                        let op = p < 0.60 ? 1.0 : (1.0 - p) * 2.5
                        Text("✦")
                            .font(.system(size: max(5, size * 0.155)))
                            .foregroundStyle(Color(red: 1.0, green: 0.85, blue: 0.0).opacity(op))
                            .offset(x: xOff, y: yOff)
                    }
                    ForEach(0..<6, id: \.self) { i in
                        let ci = Double(i)
                        let cycle = 1.8 + ci * 0.18
                        let delay = ci * 0.30 + 0.11
                        let p = max(0, ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle)
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

    private func sleepCanvas(t: Double) -> some View {
        let phase = t.truncatingRemainder(dividingBy: 4.0) / 4.0
        let float = sin(phase * .pi * 2) * 0.8
        let blinkCycle = t.truncatingRemainder(dividingBy: 4.0)
        let blink: CGFloat = (blinkCycle > 3.5 && blinkCycle < 3.7) ? 0.15 : 0.5
        return Canvas { c, sz in
            let v = V(sz, svgW: 15, svgH: 12, svgY0: 4)
            drawShadow(c, v: v, width: 6 + abs(float) * 0.3, opacity: 0.2)
            drawLegs(c, v: v, dy: float)
            drawBody(c, v: v, dy: float, scale: 0.9)
            drawFace(c, v: v, dy: float, blinkPhase: blink)
        }
    }

    private var staticSleepScene: some View {
        sleepCanvas(t: 0)
    }

    private var sleepScene: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.06)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                sleepCanvas(t: t)
            }
            TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                ZStack {
                    ForEach(0..<3, id: \.self) { i in
                        let ci = Double(i)
                        let cycle = 2.8 + ci * 0.3; let delay = ci * 0.9
                        let phase = max(0, ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle)
                        let fontSize = max(6, size * CGFloat(0.18 + phase * 0.10))
                        let opacity = phase < 0.8 ? (0.7 - ci * 0.1) : (1.0 - phase) * 3.5 * (0.7 - ci * 0.1)
                        Text("z").font(.system(size: fontSize, weight: .black, design: .monospaced))
                            .foregroundStyle(.white.opacity(opacity))
                            .offset(x: size * CGFloat(0.15 + ci * 0.08), y: -size * CGFloat(0.15 + phase * 0.38))
                    }
                }
            }
        }
    }

    private var workScene: some View {
        TimelineView(.periodic(from: .now, by: 0.03)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate * speed
            let bounce = sin(t * 2 * .pi / 0.4) * 1.0
            let blinkCycle = t.truncatingRemainder(dividingBy: 2.5)
            let blink: CGFloat = (blinkCycle > 2.2 && blinkCycle < 2.35) ? 0.1 : 1.0
            let keyPhase = Int(t / 0.1) % 6
            Canvas { c, sz in
                let v = V(sz, svgW: 16, svgH: 14, svgY0: 3)
                let shadowW: CGFloat = 7 - abs(bounce) * 0.3
                c.fill(Path(v.r(4 + (7 - shadowW) / 2, 16, shadowW, 1)),
                       with: .color(.black.opacity(max(0.1, 0.35 - abs(bounce) * 0.03))))
                drawLegs(c, v: v, dy: bounce)
                c.fill(Path(v.r(0, 13, 15, 3)), with: .color(Self.kbBase))
                for row in 0..<2 {
                    let ky = 13.5 + CGFloat(row) * 1.2
                    for col in 0..<6 { c.fill(Path(v.r(0.5 + CGFloat(col) * 2.4, ky, 1.8, 0.7)), with: .color(Self.kbKey)) }
                }
                c.fill(Path(v.r(0.5 + CGFloat(keyPhase % 6) * 2.4, 13.5 + CGFloat(keyPhase / 3) * 1.2, 1.8, 0.7)),
                       with: .color(Self.kbHi.opacity(0.9)))
                drawBody(c, v: v, dy: bounce)
                drawFace(c, v: v, dy: bounce, blinkPhase: blink)
            }
        }
    }

    private var alertScene: some View {
        ZStack {
            Circle().fill(Self.alertC.opacity(alive ? 0.12 : 0)).frame(width: size * 0.8)
                .blur(radius: size * 0.05)
                .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: alive)
            TimelineView(.periodic(from: .now, by: 0.03)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                let pct = t.truncatingRemainder(dividingBy: 3.5) / 3.5
                let jumpY = lerp([(0,0),(0.03,0),(0.175,-8),(0.25,1.5),(0.275,-6),(0.35,1),(0.375,-4),(0.45,0.8),(0.475,-2),(0.55,0.3),(0.62,0),(1,0)], at: pct)
                let shakeX: CGFloat = (pct > 0.15 && pct < 0.55) ? sin(pct * 80) * 0.6 : 0
                let bangOp = lerp([(0,0),(0.03,1),(0.55,1),(0.62,0),(1,0)], at: pct)
                Canvas { c, sz in
                    let v = V(sz, svgW: 16, svgH: 14, svgY0: 3)
                    let shadowW: CGFloat = 7 * (1.0 - abs(min(0, jumpY)) * 0.04)
                    c.fill(Path(v.r(4 + (7 - shadowW) / 2, 16, shadowW, 1)),
                           with: .color(.black.opacity(max(0.08, 0.4 - abs(min(0, jumpY)) * 0.04))))
                    drawLegs(c, v: v, dy: jumpY)
                    c.translateBy(x: shakeX * v.s, y: 0)
                    drawBody(c, v: v, dy: jumpY)
                    drawFace(c, v: v, dy: jumpY)
                    c.translateBy(x: -shakeX * v.s, y: 0)
                    if bangOp > 0.01 {
                        c.fill(Path(v.r(13, 4 + jumpY * 0.15, 2, 3.5)), with: .color(Self.alertC.opacity(bangOp)))
                        c.fill(Path(v.r(13, 8 + jumpY * 0.15, 2, 1.5)), with: .color(Self.alertC.opacity(bangOp)))
                    }
                }
            }
        }
    }
}
