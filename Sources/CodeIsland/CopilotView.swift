import SwiftUI
import CodeIslandCore

/// CopilotBot — GitHub Copilot CLI mascot, adapted from copilot-avatar.svg.
/// Two hollow ear loops (╭─╮╭─╮) on top, rose-framed face with gold dot eyes,
/// and a pink mouth bar — a cute, minimal character.
struct CopilotView: View {
    let status: AgentStatus
    var mood: MascotMood = .neutral
    var size: CGFloat = 27
    var animated: Bool = true
    @State private var alive = false
    @Environment(\.mascotSpeed) private var speed

    // Palette from copilot-avatar.svg
    private static let earC    = Color(red: 0.20, green: 0.20, blue: 0.20)  // #333 ear loops
    private static let bodyC   = Color(red: 0.80, green: 0.20, blue: 0.40)  // #cc3366 rose/magenta
    private static let faceC   = Color(red: 0.13, green: 0.13, blue: 0.16)  // dark face screen
    private static let eyeC    = Color(red: 1.00, green: 0.84, blue: 0.00)  // #ffd700 gold
    private static let alertC  = Color(red: 1.00, green: 0.30, blue: 0.15)  // #FE4C25 alert orange
    private static let kbBase  = Color(red: 0.12, green: 0.08, blue: 0.10)
    private static let kbKey   = Color(red: 0.35, green: 0.15, blue: 0.22)
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

    // ── Coordinate helper ──
    private struct V {
        let ox: CGFloat, oy: CGFloat, s: CGFloat
        let y0: CGFloat

        init(_ sz: CGSize, svgW: CGFloat = 15, svgH: CGFloat = 12, svgY0: CGFloat = 4) {
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

    // ── Ear loops — two hollow rounded-rect outlines (╭─╮╭─╮ / ╰─╯╰─╯) ──
    private func drawEars(_ c: GraphicsContext, v: V, dy: CGFloat,
                          color: Color? = nil, signal: Bool = false) {
        let ec = color ?? Self.earC
        // Left ear loop (3×3 outlined rect)
        c.fill(Path(v.r(3, 5, 3, 1, dy: dy)), with: .color(ec))   // top ╭─╮
        c.fill(Path(v.r(3, 6, 1, 1, dy: dy)), with: .color(ec))   // left │
        c.fill(Path(v.r(5, 6, 1, 1, dy: dy)), with: .color(ec))   // right │
        c.fill(Path(v.r(3, 7, 3, 1, dy: dy)), with: .color(ec))   // bottom ╰─╯
        // Right ear loop
        c.fill(Path(v.r(9, 5, 3, 1, dy: dy)), with: .color(ec))
        c.fill(Path(v.r(9, 6, 1, 1, dy: dy)), with: .color(ec))
        c.fill(Path(v.r(11, 6, 1, 1, dy: dy)), with: .color(ec))
        c.fill(Path(v.r(9, 7, 3, 1, dy: dy)), with: .color(ec))
        // Stems connecting ears to body
        c.fill(Path(v.r(4, 8, 1, 1, dy: dy)), with: .color(ec))
        c.fill(Path(v.r(10, 8, 1, 1, dy: dy)), with: .color(ec))
        // Signal flash inside loops (work mode: receiving data)
        if signal {
            c.fill(Path(v.r(4, 6, 1, 1, dy: dy)), with: .color(Self.eyeC.opacity(0.5)))
            c.fill(Path(v.r(10, 6, 1, 1, dy: dy)), with: .color(Self.eyeC.opacity(0.5)))
        }
    }

    // ── Body — rose frame with dark face screen ──
    private func drawBody(_ c: GraphicsContext, v: V, dy: CGFloat,
                          shellColor: Color? = nil) {
        let bc = shellColor ?? Self.bodyC
        // Rose shell frame
        c.fill(Path(v.r(2, 9, 11, 1, dy: dy)), with: .color(bc))    // top bar
        c.fill(Path(v.r(2, 10, 2, 3, dy: dy)), with: .color(bc))    // left cheek
        c.fill(Path(v.r(11, 10, 2, 3, dy: dy)), with: .color(bc))   // right cheek
        // Dark face screen (between cheeks)
        c.fill(Path(v.r(4, 10, 7, 3, dy: dy)), with: .color(Self.faceC))
        // Bottom bar + chin (drawn after face to stay on top)
        c.fill(Path(v.r(2, 13, 11, 1, dy: dy)), with: .color(bc))   // bottom bar ▔▔▔▔
        c.fill(Path(v.r(4, 14, 7, 1, dy: dy)), with: .color(bc))    // chin
    }

    // ── Eyes — gold dots (▘▝ quarter-block style) ──
    private func drawEyes(_ c: GraphicsContext, v: V, dy: CGFloat,
                          color: Color? = nil, height: CGFloat = 1) {
        let ec = color ?? Self.eyeC
        c.fill(Path(v.r(5, 10, 1, height, dy: dy)), with: .color(ec))
        c.fill(Path(v.r(9, 10, 1, height, dy: dy)), with: .color(ec))
    }

    // ── Legs ──
    private func drawLegs(_ c: GraphicsContext, v: V) {
        c.fill(Path(v.r(6, 14.5, 1, 1.5)), with: .color(Self.bodyC.opacity(0.6)))
        c.fill(Path(v.r(8, 14.5, 1, 1.5)), with: .color(Self.bodyC.opacity(0.6)))
    }

    // ── Shadow ──
    private func drawShadow(_ c: GraphicsContext, v: V, width: CGFloat = 9, opacity: Double = 0.3) {
        c.fill(Path(v.r(7.5 - width / 2, 15, width, 1)),
               with: .color(.black.opacity(opacity)))
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

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // SLEEP — gentle float, dim face, Z's
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
        let float = sin(phase * .pi * 2) * 0.8

        return Canvas { c, sz in
            let v = V(sz)
            drawShadow(c, v: v, width: 7 + abs(float) * 0.3, opacity: 0.2)
            drawLegs(c, v: v)
            drawEars(c, v: v, dy: float)
            drawBody(c, v: v, dy: float, shellColor: Self.bodyC.opacity(0.4))
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // WORK — bouncing, blinking, ear signals, keyboard
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    private var workScene: some View {
        TimelineView(.periodic(from: .now, by: 0.03)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate * speed
            workCanvas(t: t)
        }
    }

    private func workCanvas(t: Double) -> some View {
        let bounce = sin(t * 2 * .pi / 0.4) * 1.0
        let keyPhase = Int(t / 0.1) % 6

        // Blink
        let blinkCycle = t.truncatingRemainder(dividingBy: 3.2)
        let showEyes = !(blinkCycle > 1.5 && blinkCycle < 1.6)

        // Ear signal pulse (brief gold flash inside loops every ~2.5s)
        let sigPhase = t.truncatingRemainder(dividingBy: 2.5)
        let earSignal = sigPhase > 2.0 && sigPhase < 2.3

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
            let flashRow = keyPhase / 3
            let flashCol = keyPhase % 6
            let fkx = 0.5 + CGFloat(flashCol) * 2.4
            let fky = 13.5 + CGFloat(flashRow) * 1.2
            c.fill(Path(v.r(fkx, fky, 1.8, 0.7)), with: .color(Self.kbHi.opacity(0.9)))

            drawEars(c, v: v, dy: dy, signal: earSignal)
            drawBody(c, v: v, dy: dy)
            if showEyes { drawEyes(c, v: v, dy: dy) }
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // ALERT — jumping, ear flash, eye startle
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

        let shakeX: CGFloat = (pct > 0.15 && pct < 0.55) ? sin(pct * 80) * 0.6 : 0

        // Flash ears and cheeks between normal and alert orange
        let flash = (pct > 0.03 && pct < 0.55) ? sin(pct * 25) * 0.5 + 0.5 : 0.0
        let earColor = flash > 0.5 ? Self.alertC : Self.earC
        let shellColor = flash > 0.5 ? Self.alertC : Self.bodyC

        // Eyes widen during startle (1px → 2px tall)
        let eyeH: CGFloat = (pct > 0.03 && pct < 0.55) ? 2 : 1

        // ! mark
        let bangOp = lerp([
            (0, 0), (0.03, 1), (0.10, 1), (0.55, 1), (0.62, 0), (1.0, 0),
        ], at: pct)
        let bangScale = lerp([
            (0, 0.3), (0.03, 1.3), (0.10, 1.0), (0.55, 1.0), (0.62, 0.6), (1.0, 0.6),
        ], at: pct)

        return Canvas { c, sz in
            let v = V(sz, svgW: 16, svgH: 14, svgY0: 3)

            let shadowW: CGFloat = 8 * (1.0 - abs(min(0, jumpY)) * 0.04)
            let shadowOp = max(0.08, 0.4 - abs(min(0, jumpY)) * 0.04)
            c.fill(Path(v.r(4 + (8 - shadowW) / 2, 16, shadowW, 1)),
                   with: .color(.black.opacity(shadowOp)))

            drawLegs(c, v: v)

            c.translateBy(x: shakeX * v.s, y: 0)
            drawEars(c, v: v, dy: jumpY, color: earColor)
            drawBody(c, v: v, dy: jumpY, shellColor: shellColor)
            drawEyes(c, v: v, dy: jumpY, height: eyeH)
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
    // MOOD SCENES — idle variants for Copilot (rose+gold robot)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // HUNGRY — fast dual-freq wobble + open-mouth override + food emojis
    private var hungryScene: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.06)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                let float = sin(t * .pi * 2 / 4.0) * 1.5
                let wobble = sin(t * 7) * 0.6 + sin(t * 13.5) * 0.35
                Canvas { c, sz in
                    let v = V(sz)
                    drawShadow(c, v: v, width: 7 + abs(float) * 0.4, opacity: 0.22)
                    drawLegs(c, v: v)
                    drawEars(c, v: v, dy: float + wobble)
                    drawBody(c, v: v, dy: float + wobble)
                    // Eyes open wide (hungry alert)
                    drawEyes(c, v: v, dy: float + wobble, height: 1.5)
                    // Open mouth: overwrite lower face screen with darker gap
                    c.fill(Path(v.r(5, 12, 5, 1.2, dy: float + wobble)),
                           with: .color(Self.eyeC.opacity(0.0)))
                    c.fill(Path(v.r(5, 12, 5, 1.2, dy: float + wobble)),
                           with: .color(.black.opacity(0.75)))
                    // Belly rumble dots on chest
                    let rumble: CGFloat = sin(t * 20) > 0 ? 0.5 : 0.0
                    for i: CGFloat in [0, 1, 2] {
                        c.fill(Path(v.r(5.0 + i * 1.8, 11.5, 0.9, 0.9, dy: float + wobble)),
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

    // TIRED — slow nod + half-eye bars + 2 big Zs
    private var tiredScene: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.06)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                let nodPhase = t.truncatingRemainder(dividingBy: 3.2) / 3.2
                let nod: CGFloat = nodPhase < 0.6
                    ? CGFloat(sin(nodPhase / 0.6 * .pi)) * 2.0
                    : 0
                Canvas { c, sz in
                    let v = V(sz)
                    drawShadow(c, v: v, opacity: 0.14)
                    drawLegs(c, v: v)
                    drawEars(c, v: v, dy: nod)
                    drawBody(c, v: v, dy: nod, shellColor: Self.bodyC.opacity(0.45))
                    // Half-closed eyes: thin bars over eye positions
                    c.fill(Path(v.r(4.5, 10.2, 1.5, 0.4, dy: nod)),
                           with: .color(Self.bodyC.opacity(0.9)))
                    c.fill(Path(v.r(8.5, 10.2, 1.5, 0.4, dy: nod)),
                           with: .color(Self.bodyC.opacity(0.9)))
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

    // SAD — dim body + cold blue overlay + tear drops + frown
    private var sadScene: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.06)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                let float = sin(t * .pi * 2 / 4.5) * 0.5
                Canvas { c, sz in
                    let v = V(sz)
                    drawShadow(c, v: v, opacity: 0.18)
                    drawLegs(c, v: v)
                    var gctx = c
                    gctx.opacity = 0.70
                    drawEars(gctx, v: v, dy: float)
                    drawBody(gctx, v: v, dy: float)
                    // Cold blue tint overlay on body
                    c.fill(Path(v.r(2, 9, 11, 6, dy: float)),
                           with: .color(Color(red: 0.3, green: 0.5, blue: 0.9).opacity(0.13)))
                    // Frown: downward V (3 segments)
                    c.fill(Path(v.r(5, 12, 1, 0.8, dy: float)),
                           with: .color(Self.eyeC.opacity(0.7)))
                    c.fill(Path(v.r(6, 12.6, 3, 0.8, dy: float)),
                           with: .color(Self.eyeC.opacity(0.7)))
                    c.fill(Path(v.r(9, 12, 1, 0.8, dy: float)),
                           with: .color(Self.eyeC.opacity(0.7)))
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
                let float = sin(t * .pi * 2 / 5.0) * 0.4
                Canvas { c, sz in
                    let v = V(sz)
                    drawShadow(c, v: v, opacity: 0.15)
                    drawLegs(c, v: v)
                    c.translateBy(x: shake * v.s, y: 0)
                    var gctx = c
                    gctx.opacity = 0.80
                    drawEars(gctx, v: v, dy: float)
                    drawBody(gctx, v: v, dy: float)
                    // Green sick overlay on body
                    c.fill(Path(v.r(2, 9, 11, 6, dy: float)),
                           with: .color(Color(red: 0.2, green: 0.8, blue: 0.3).opacity(0.16)))
                    // X eyes (over dark face screen)
                    let eyePositions: [(CGFloat, CGFloat)] = [(4.5, 10.0), (8.5, 10.0)]
                    for (ex, ey) in eyePositions {
                        c.fill(Path(v.r(ex,       ey,       0.8, 0.8, dy: float)), with: .color(Self.eyeC))
                        c.fill(Path(v.r(ex + 0.8, ey + 0.8, 0.8, 0.8, dy: float)), with: .color(Self.eyeC))
                        c.fill(Path(v.r(ex + 0.8, ey,       0.8, 0.8, dy: float)), with: .color(Self.eyeC))
                        c.fill(Path(v.r(ex,       ey + 0.8, 0.8, 0.8, dy: float)), with: .color(Self.eyeC))
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

    // JOYFUL — bouncy float + full bright face + 12-particle sparkle ring
    private var joyfulScene: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                let jumpPhase = t.truncatingRemainder(dividingBy: 1.2) / 1.2
                let jumpY: CGFloat = jumpPhase < 0.35
                    ? CGFloat(-sin(jumpPhase / 0.35 * .pi) * 2.8)
                    : 0
                Canvas { c, sz in
                    let v = V(sz)
                    let shadowW: CGFloat = 7 + abs(jumpY) * 0.4
                    let shadowOp: Double = max(0.10, 0.22 - Double(abs(jumpY)) * 0.025)
                    drawShadow(c, v: v, width: shadowW, opacity: shadowOp)
                    drawLegs(c, v: v)
                    drawEars(c, v: v, dy: jumpY, color: Self.earC, signal: true)
                    drawBody(c, v: v, dy: jumpY)
                    drawEyes(c, v: v, dy: jumpY, color: Self.eyeC, height: 1.3)
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
