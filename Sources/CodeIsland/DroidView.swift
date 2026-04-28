import SwiftUI
import CodeIslandCore

/// DroidBot — Factory/Droid mascot, pixel-art industrial robot.
/// Rust orange #D56A26 on warm brown-black #161413. Mechanical/factory aesthetic.
struct DroidView: View {
    let status: AgentStatus
    var mood: MascotMood = .neutral
    var size: CGFloat = 27
    var animated: Bool = true
    @State private var alive = false
    @Environment(\.mascotSpeed) private var speed

    // Factory brand palette — warm industrial
    private static let bodyC   = Color(red: 0.835, green: 0.416, blue: 0.149) // #D56A26 rust orange
    private static let bodyDk  = Color(red: 0.65, green: 0.32, blue: 0.12)    // darker orange
    private static let metalC  = Color(red: 0.40, green: 0.37, blue: 0.34)    // metal gray
    private static let eyeC    = Color(red: 0.89, green: 0.60, blue: 0.16)    // #E3992A gold
    private static let alertC  = Color(red: 1.0, green: 0.24, blue: 0.0)
    private static let kbBase  = Color(red: 0.15, green: 0.13, blue: 0.12)
    private static let kbKey   = Color(red: 0.32, green: 0.28, blue: 0.25)
    private static let kbHi    = Color(red: 0.835, green: 0.416, blue: 0.149)

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

    // ── Draw robot body — boxy industrial droid ──
    private func drawRobot(_ c: GraphicsContext, v: V, dy: CGFloat,
                           squashX: CGFloat = 1, squashY: CGFloat = 1) {
        let cx: CGFloat = 7.5

        // Main body (box)
        let bw: CGFloat = 9 * squashX, bh: CGFloat = 6 * squashY
        let bx = cx - bw / 2
        let by: CGFloat = 9 + (6 - bh)
        c.fill(Path(v.r(bx, by, bw, bh, dy: dy)), with: .color(Self.bodyC))

        // Head (smaller box on top)
        let hw: CGFloat = 7 * squashX, hh: CGFloat = 3 * squashY
        let hx = cx - hw / 2
        let hy = by - hh + 0.5
        c.fill(Path(v.r(hx, hy, hw, hh, dy: dy)), with: .color(Self.bodyC))

        // Antenna
        let ax = cx - 0.5
        c.fill(Path(v.r(ax, hy - 2, 1, 2, dy: dy)), with: .color(Self.metalC))
        c.fill(Path(v.r(ax - 0.5, hy - 2.5, 2, 1, dy: dy)), with: .color(Self.eyeC))

        // Chest plate (darker inner rectangle)
        let pw: CGFloat = 5 * squashX, ph: CGFloat = 3 * squashY
        c.fill(Path(v.r(cx - pw / 2, by + 1, pw, ph, dy: dy)), with: .color(Self.bodyDk))

        // Rivets / bolts on chest (pixel dots)
        c.fill(Path(v.r(cx - pw / 2 + 0.5, by + 1.5, 0.8, 0.8, dy: dy)),
               with: .color(Self.metalC))
        c.fill(Path(v.r(cx + pw / 2 - 1.3, by + 1.5, 0.8, 0.8, dy: dy)),
               with: .color(Self.metalC))

        // Arms (rectangles on sides)
        c.fill(Path(v.r(bx - 1.5, by + 1, 1.5, 4 * squashY, dy: dy)),
               with: .color(Self.metalC))
        c.fill(Path(v.r(bx + bw, by + 1, 1.5, 4 * squashY, dy: dy)),
               with: .color(Self.metalC))
    }

    // ── Draw robot eyes — glowing rectangles ──
    private func drawEyes(_ c: GraphicsContext, v: V, dy: CGFloat,
                          color: Color = Self.eyeC, scale: CGFloat = 1.0) {
        let eyeW: CGFloat = 1.5, eyeH: CGFloat = 1.2 * scale
        let eyeY: CGFloat = 8.0 + (1.2 - eyeH) / 2
        c.fill(Path(v.r(4.8, eyeY, eyeW, max(0.2, eyeH), dy: dy)), with: .color(color))
        c.fill(Path(v.r(8.7, eyeY, eyeW, max(0.2, eyeH), dy: dy)), with: .color(color))
    }

    private func drawShadow(_ c: GraphicsContext, v: V, width: CGFloat = 9, opacity: Double = 0.3) {
        c.fill(Path(v.r(7.5 - width / 2, 16, width, 1)),
               with: .color(.black.opacity(opacity)))
    }

    private func drawLegs(_ c: GraphicsContext, v: V) {
        // Blocky robot feet
        c.fill(Path(v.r(4.5, 14.5, 2, 1.5)), with: .color(Self.metalC))
        c.fill(Path(v.r(8.5, 14.5, 2, 1.5)), with: .color(Self.metalC))
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
                Text("z")
                    .font(.system(size: fontSize, weight: .black, design: .monospaced))
                    .foregroundStyle(.white.opacity(opacity))
                    .offset(x: size * CGFloat(0.15 + ci * 0.08),
                            y: -size * CGFloat(0.15 + phase * 0.38))
            }
        }
    }

    private func sleepCanvas(t: Double) -> some View {
        let phase = t.truncatingRemainder(dividingBy: 5.0) / 5.0
        // Slow breathing — mechanical rhythm
        let breathe = sin(phase * .pi * 2) * 0.4
        // Eye dim flicker (like powering down)
        let eyeFlicker = t.truncatingRemainder(dividingBy: 3.0)
        let eyeOn = eyeFlicker < 2.5

        return Canvas { c, sz in
            let v = V(sz, svgW: 16, svgH: 16, svgY0: 2)
            drawShadow(c, v: v, width: 8, opacity: 0.2)
            drawLegs(c, v: v)
            drawRobot(c, v: v, dy: breathe)
            if eyeOn {
                drawEyes(c, v: v, dy: breathe, color: Self.eyeC.opacity(0.3), scale: 0.4)
            }
        }
    }

    // ━━━━━━ WORK ━━━━━━
    private var workScene: some View {
        TimelineView(.periodic(from: .now, by: 0.03)) { ctx in
            workCanvas(t: ctx.date.timeIntervalSinceReferenceDate * speed)
        }
    }

    private func workCanvas(t: Double) -> some View {
        let bounce = sin(t * 2 * .pi / 0.5) * 0.8  // slower, heavier bounce
        let blinkCycle = t.truncatingRemainder(dividingBy: 2.0)
        let blink: CGFloat = (blinkCycle > 1.7 && blinkCycle < 1.85) ? 0.1 : 1.0
        let keyPhase = Int(t / 0.12) % 6  // slightly slower typing

        return Canvas { c, sz in
            let v = V(sz, svgW: 16, svgH: 16, svgY0: 2)

            let shadowW: CGFloat = 9 - abs(bounce) * 0.3
            c.fill(Path(v.r(3.5 + (9 - shadowW) / 2, 17, shadowW, 1)),
                   with: .color(.black.opacity(max(0.1, 0.35 - abs(bounce) * 0.03))))

            drawLegs(c, v: v)

            // Keyboard
            c.fill(Path(v.r(0, 15, 15, 3)), with: .color(Self.kbBase))
            for row in 0..<2 {
                let ky = 15.5 + CGFloat(row) * 1.2
                for col in 0..<6 {
                    let kx = 0.5 + CGFloat(col) * 2.4
                    c.fill(Path(v.r(kx, ky, 1.8, 0.7)), with: .color(Self.kbKey))
                }
            }
            let fCol = keyPhase % 6
            let fRow = keyPhase / 3
            c.fill(Path(v.r(0.5 + CGFloat(fCol) * 2.4, 15.5 + CGFloat(fRow) * 1.2, 1.8, 0.7)),
                   with: .color(Self.kbHi.opacity(0.9)))

            drawRobot(c, v: v, dy: bounce)
            drawEyes(c, v: v, dy: bounce, scale: blink)
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

        // Eyes flash red during alert
        let eyeFlash = (pct > 0.03 && pct < 0.55 && sin(pct * 20) > 0)
        let eyeColor = eyeFlash ? Self.alertC : Self.eyeC

        let bangOp = lerp([
            (0, 0), (0.03, 1), (0.10, 1), (0.55, 1), (0.62, 0), (1.0, 0),
        ], at: pct)
        let bangScale = lerp([
            (0, 0.3), (0.03, 1.3), (0.10, 1.0), (0.55, 1.0), (0.62, 0.6), (1.0, 0.6),
        ], at: pct)

        return Canvas { c, sz in
            let v = V(sz, svgW: 16, svgH: 16, svgY0: 2)

            let shadowW: CGFloat = 9 * (1.0 - abs(min(0, jumpY)) * 0.04)
            c.fill(Path(v.r(3.5 + (9 - shadowW) / 2, 17, shadowW, 1)),
                   with: .color(.black.opacity(max(0.08, 0.4 - abs(min(0, jumpY)) * 0.04))))

            drawLegs(c, v: v)

            c.translateBy(x: shakeX * v.s, y: 0)
            drawRobot(c, v: v, dy: jumpY, squashX: squashX, squashY: squashY)
            drawEyes(c, v: v, dy: jumpY, color: eyeColor,
                     scale: pct > 0.03 && pct < 0.15 ? 1.3 : 1.0)
            c.translateBy(x: -shakeX * v.s, y: 0)

            if bangOp > 0.01 {
                let bw: CGFloat = 2 * bangScale
                let bx: CGFloat = 13
                let by: CGFloat = 3 + jumpY * 0.15
                c.fill(Path(v.r(bx, by, bw, 3.5 * bangScale, dy: 0)),
                       with: .color(Self.alertC.opacity(bangOp)))
                c.fill(Path(v.r(bx, by + 4.0 * bangScale, bw, 1.5 * bangScale, dy: 0)),
                       with: .color(Self.alertC.opacity(bangOp)))
            }
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MOOD SCENES — idle variants for Droid (rust-orange robot)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // HUNGRY — dual-freq wobble + open chest plate + belly rumble + food emojis
    private var hungryScene: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.06)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                let breathe = sin(t * .pi * 2 / 5.0) * 0.4
                let wobble = sin(t * 7) * 0.7 + sin(t * 13.5) * 0.4
                Canvas { c, sz in
                    let v = V(sz, svgW: 16, svgH: 16, svgY0: 2)
                    drawShadow(c, v: v, width: 8, opacity: 0.22)
                    drawLegs(c, v: v)
                    drawRobot(c, v: v, dy: breathe + wobble)
                    drawEyes(c, v: v, dy: breathe + wobble, color: Self.eyeC, scale: 1.3)
                    // Open mouth slot on lower head (hunger gape)
                    let cx: CGFloat = 7.5
                    c.fill(Path(v.r(cx - 2, 10.5, 4, 1.2, dy: breathe + wobble)),
                           with: .color(.black.opacity(0.80)))
                    // Belly rumble dots on chest plate
                    let rumble: CGFloat = sin(t * 20) > 0 ? 0.5 : 0.0
                    for i: CGFloat in [0, 1, 2] {
                        c.fill(Path(v.r(5.0 + i * 1.6, 12.0, 0.9, 0.9, dy: breathe + wobble)),
                               with: .color(Color(red: 1.0, green: 0.6, blue: 0.1).opacity(0.45 + rumble * 0.35)))
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

    // TIRED — slow nod + dim eye glow + 2 big Zs
    private var tiredScene: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.06)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                let nodPhase = t.truncatingRemainder(dividingBy: 3.2) / 3.2
                let nod: CGFloat = nodPhase < 0.6
                    ? CGFloat(sin(nodPhase / 0.6 * .pi)) * 2.0
                    : 0
                Canvas { c, sz in
                    let v = V(sz, svgW: 16, svgH: 16, svgY0: 2)
                    drawShadow(c, v: v, opacity: 0.14)
                    drawLegs(c, v: v)
                    drawRobot(c, v: v, dy: nod)
                    // Very dim eyes (barely on)
                    drawEyes(c, v: v, dy: nod, color: Self.eyeC.opacity(0.20), scale: 0.35)
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

    // SAD — dim body + cold blue overlay + tear drops + eye dim
    private var sadScene: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.06)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                let breathe = sin(t * .pi * 2 / 5.0) * 0.3
                Canvas { c, sz in
                    let v = V(sz, svgW: 16, svgH: 16, svgY0: 2)
                    drawShadow(c, v: v, opacity: 0.18)
                    drawLegs(c, v: v)
                    var gctx = c
                    gctx.opacity = 0.70
                    drawRobot(gctx, v: v, dy: breathe)
                    // Cold blue tint overlay on body
                    let cx: CGFloat = 7.5
                    c.fill(Path(v.r(cx - 4.5, 9, 9, 6, dy: breathe)),
                           with: .color(Color(red: 0.3, green: 0.5, blue: 0.9).opacity(0.13)))
                    // Dim sad eyes (blue-tinted)
                    drawEyes(c, v: v, dy: breathe,
                             color: Color(red: 0.4, green: 0.55, blue: 0.9), scale: 0.6)
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

    // SICK — dual-freq shake + green overlay + X eyes + sweat drops
    private var sickScene: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                let shake = sin(t * 7) * 0.9 + sin(t * 13.5) * 0.5
                let breathe = sin(t * .pi * 2 / 5.0) * 0.3
                Canvas { c, sz in
                    let v = V(sz, svgW: 16, svgH: 16, svgY0: 2)
                    drawShadow(c, v: v, opacity: 0.15)
                    drawLegs(c, v: v)
                    c.translateBy(x: shake * v.s, y: 0)
                    var gctx = c
                    gctx.opacity = 0.80
                    drawRobot(gctx, v: v, dy: breathe)
                    // Green sick overlay
                    let cx: CGFloat = 7.5
                    c.fill(Path(v.r(cx - 4.5, 6, 9, 9, dy: breathe)),
                           with: .color(Color(red: 0.2, green: 0.8, blue: 0.3).opacity(0.16)))
                    // X eyes (over normal eye positions)
                    let eyePositions: [(CGFloat, CGFloat)] = [(4.3, 7.5), (8.2, 7.5)]
                    for (ex, ey) in eyePositions {
                        c.fill(Path(v.r(ex,       ey,       0.9, 0.9, dy: breathe)), with: .color(Self.eyeC))
                        c.fill(Path(v.r(ex + 0.9, ey + 0.9, 0.9, 0.9, dy: breathe)), with: .color(Self.eyeC))
                        c.fill(Path(v.r(ex + 0.9, ey,       0.9, 0.9, dy: breathe)), with: .color(Self.eyeC))
                        c.fill(Path(v.r(ex,       ey + 0.9, 0.9, 0.9, dy: breathe)), with: .color(Self.eyeC))
                    }
                    // Fever dots above antenna
                    for i: CGFloat in [0, 1, 2, 3] {
                        let dotRect = v.r(3.5 + i * 2.2, 2.5, 1.0, 1.0, dy: breathe)
                        c.fill(Path(ellipseIn: dotRect),
                               with: .color(Color(red: 0.95, green: 0.25, blue: 0.35).opacity(0.80)))
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

    // JOYFUL — bouncy jump + full bright eyes + 12-particle sparkle ring
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
                    let v = V(sz, svgW: 16, svgH: 16, svgY0: 2)
                    let shadowW: CGFloat = 7 + abs(jumpY) * 0.4
                    let shadowOp: Double = max(0.10, 0.22 - Double(abs(jumpY)) * 0.025)
                    drawShadow(c, v: v, width: shadowW, opacity: shadowOp)
                    drawLegs(c, v: v)
                    drawRobot(c, v: v, dy: jumpY, squashY: squashY)
                    drawEyes(c, v: v, dy: jumpY, color: Self.eyeC, scale: 1.3)
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
                        let xOff = r * CGFloat(cos(angle))
                        let yOff = r * CGFloat(sin(angle)) - size * 0.08
                        let op = p < 0.60 ? 1.0 : (1.0 - p) * 2.5 * 1.0
                        Text("✦")
                            .font(.system(size: max(5, size * 0.155)))
                            .foregroundStyle(Color(red: 1.0, green: 0.85, blue: 0.0).opacity(op))
                            .offset(x: xOff, y: yOff)
                    }
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
}
