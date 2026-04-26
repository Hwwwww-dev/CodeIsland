import SwiftUI
import CodeIslandCore

/// Clawd — Claude mascot, adapted from clawd-on-desk SVG pixel art.
/// Renders SVG rects proportionally via Canvas + TimelineView animations.
struct ClawdView: View {
    let status: AgentStatus
    var mood: MascotMood = .neutral
    var size: CGFloat = 27
    var animated: Bool = true
    @State private var alive = false
    @Environment(\.mascotSpeed) private var speed

    // Colors from clawd-on-desk
    private static let bodyC  = Color(red: 0.871, green: 0.533, blue: 0.427) // #DE886D
    private static let eyeC   = Color.black
    private static let alertC = Color(red: 1.0, green: 0.24, blue: 0.0)     // #FF3D00
    private static let kbBase = Color(red: 0.38, green: 0.44, blue: 0.50)  // lighter base
    private static let kbKey  = Color(red: 0.60, green: 0.66, blue: 0.72)  // visible keys
    private static let kbHi   = Color.white                                 // bright flash

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

    private var staticSleepScene: some View {
        sleepCanvas(t: 0)
    }

    // ── Coordinate helper: maps SVG units to view points ──
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

    // ── Rotated arm: returns polygon path for a rect rotated around pivot ──
    private func armPath(_ v: V, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                         pivotX: CGFloat, pivotY: CGFloat, angle: CGFloat, dy: CGFloat) -> Path {
        let a = angle * .pi / 180
        let ca = cos(a), sa = sin(a)
        let corners: [(CGFloat, CGFloat)] = [
            (x - pivotX, y - pivotY),
            (x + w - pivotX, y - pivotY),
            (x + w - pivotX, y + h - pivotY),
            (x - pivotX, y + h - pivotY),
        ]
        var path = Path()
        for (i, (cx, cy)) in corners.enumerated() {
            let rx = cx * ca - cy * sa + pivotX
            let ry = cx * sa + cy * ca + pivotY
            let pt = CGPoint(x: v.ox + rx * v.s, y: v.oy + (ry - v.y0 + dy) * v.s)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        path.closeSubpath()
        return path
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // Draw sleeping character (sploot pose from clawd-sleeping.svg)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    private func drawSleeping(_ ctx: GraphicsContext, v: V, breathe: CGFloat) {
        // Shadow (wider for sploot, pulses with breath)
        let shadowScale: CGFloat = 1.0 + breathe * 0.03
        ctx.fill(Path(v.r(-1, 15, 17 * shadowScale, 1)),
                 with: .color(.black.opacity(0.35 + breathe * 0.08)))

        // Legs pointing up from behind (wider 1×2 blocks for visibility)
        for x: CGFloat in [3, 5, 9, 11] {
            ctx.fill(Path(v.r(x, 8.5, 1, 1.5)), with: .color(Self.bodyC))
        }

        // Flattened torso — big puff on inhale (25% from SVG)
        let puff = max(0, breathe) * 0.25
        let torsoH: CGFloat = 5 * (1.0 + puff)
        let torsoY: CGFloat = 15 - torsoH
        let torsoW: CGFloat = 13 * (1.0 + breathe * 0.015) // slight width pulse
        let torsoX: CGFloat = 1 - (torsoW - 13) / 2
        ctx.fill(Path(v.r(torsoX, torsoY, torsoW, torsoH)), with: .color(Self.bodyC))

        // Arms spread flat on the ground
        ctx.fill(Path(v.r(-1, 13, 2, 2)), with: .color(Self.bodyC))
        ctx.fill(Path(v.r(14, 13, 2, 2)), with: .color(Self.bodyC))

        // Shut eyes (thicker for visibility, move with puff)
        let eyeY: CGFloat = 12.2 - puff * 2.5
        ctx.fill(Path(v.r(3, eyeY, 2.5, 1.0)), with: .color(Self.eyeC))
        ctx.fill(Path(v.r(9.5, eyeY, 2.5, 1.0)), with: .color(Self.eyeC))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // SLEEP — sploot pose, breathing, floating z's
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    private var sleepScene: some View {
        ZStack {
            // Character body (behind)
            TimelineView(.periodic(from: .now, by: 0.06)) { ctx in
                sleepCanvas(t: ctx.date.timeIntervalSinceReferenceDate * speed)
            }

            // Z's — continuous float-up loop, staggered timing
            TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                floatingZs(t: t)
            }
        }
    }

    private func floatingZs(t: Double) -> some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                floatingZ(t: t, index: i)
            }
        }
    }

    private func floatingZ(t: Double, index: Int) -> some View {
        let ci = Double(index)
        let cycle = 2.8 + ci * 0.3
        let delay = ci * 0.9
        let phase = ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle
        let p = max(0, phase)
        let fontSize = max(6, size * CGFloat(0.18 + p * 0.10))
        let baseOpacity = 0.7 - ci * 0.1
        let opacity = p < 0.8 ? baseOpacity : (1.0 - p) * 3.5 * baseOpacity
        let xOff = size * CGFloat(0.08 + ci * 0.06 + sin(p * .pi * 2) * 0.03)
        let yOff = -size * CGFloat(0.15 + p * 0.38)
        return Text("z")
            .font(.system(size: fontSize, weight: .black, design: .monospaced))
            .foregroundStyle(.white.opacity(opacity))
            .offset(x: xOff, y: yOff)
    }

    private func sleepCanvas(t: Double) -> some View {
        let phase = t.truncatingRemainder(dividingBy: 4.5) / 4.5
        let breathe: CGFloat = phase < 0.4 ? sin(phase / 0.4 * .pi) : 0

        return Canvas { c, sz in
            let v = V(sz, svgW: 17, svgH: 7, svgY0: 9)
            drawSleeping(c, v: v, breathe: breathe)
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // WORK — typing: bounce + arm rotation + keyboard + squinted eyes
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    private var workScene: some View {
        TimelineView(.periodic(from: .now, by: 0.03)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate * speed
            workCanvas(t: t)
        }
    }

    private func workCanvas(t: Double) -> some View {
        // Body bounce: 0.35s (matches SVG)
        let bounce = sin(t * 2 * .pi / 0.35) * 1.2
        let breathe = sin(t * 2 * .pi / 3.2)

        // Arm typing: fast, correct direction (inward toward keyboard)
        // Left: -10° to -55° (0.15s cycle), Right: 10° to 55° (0.12s cycle)
        let armLRaw = sin(t * 2 * .pi / 0.15)  // -1..1
        let armL = armLRaw * 22.5 - 32.5        // -55 to -10
        let armRRaw = sin(t * 2 * .pi / 0.12)
        let armR = armRRaw * 22.5 + 32.5        // 10 to 55

        // Key flash synced: flash left keys when left arm is down (armLRaw > 0.5)
        let leftHit = armLRaw > 0.3
        let rightHit = armRRaw > 0.3
        // Randomize which key flashes using time
        let leftKeyCol = Int(t / 0.15) % 3     // 0..2 (left side keys)
        let rightKeyCol = 3 + Int(t / 0.12) % 3 // 3..5 (right side keys)

        // Eyes: squinted, occasional scan up
        let scanPhase = t.truncatingRemainder(dividingBy: 10.0)
        let eyeScale: CGFloat = (scanPhase > 5.7 && scanPhase < 6.9) ? 1.0 : 0.5
        let eyeDY: CGFloat = eyeScale < 0.8 ? 1.0 : -0.5
        let blinkPhase = t.truncatingRemainder(dividingBy: 3.5)
        let finalEyeScale = (blinkPhase > 1.4 && blinkPhase < 1.55) ? 0.1 : eyeScale

        return Canvas { c, sz in
            let v = V(sz, svgW: 16, svgH: 11, svgY0: 5.5)
            let dy = bounce

            // 1. Shadow
            let shadowW: CGFloat = 9 - abs(dy) * 0.3
            c.fill(Path(v.r(3 + (9 - shadowW) / 2, 15, shadowW, 1)),
                   with: .color(.black.opacity(max(0.1, 0.4 - abs(dy) * 0.03))))

            // 2. Short legs (h=2, behind keyboard)
            for x: CGFloat in [3, 5, 9, 11] {
                c.fill(Path(v.r(x, 13, 1, 2)), with: .color(Self.bodyC))
            }

            // 3. Torso
            let bScale = 1.0 + breathe * 0.015
            let torsoW = 11 * bScale
            c.fill(Path(v.r(2 - (torsoW - 11) / 2, 6, torsoW, 7, dy: dy)),
                   with: .color(Self.bodyC))

            // 4. Eyes
            let eyeH: CGFloat = 2 * finalEyeScale
            let eyeY: CGFloat = 8 + (2 - eyeH) / 2 + eyeDY
            c.fill(Path(v.r(4, eyeY, 1, eyeH, dy: dy)), with: .color(Self.eyeC))
            c.fill(Path(v.r(10, eyeY, 1, eyeH, dy: dy)), with: .color(Self.eyeC))

            // 5. Keyboard (on top of legs)
            c.fill(Path(v.r(-0.5, 11.8, 16, 3.5)), with: .color(Self.kbBase))
            // Key grid: 6 columns × 3 rows
            for row in 0..<3 {
                let ky = 12.2 + CGFloat(row) * 1.0
                for col in 0..<6 {
                    let kx = 0.3 + CGFloat(col) * 2.5
                    let w: CGFloat = (col == 2 && row == 1) ? 4.5 : 2.0
                    c.fill(Path(v.r(kx, ky, w, 0.7)), with: .color(Self.kbKey))
                }
            }
            // Key flashes synced with arm hits
            if leftHit {
                let row = leftKeyCol % 3
                let kx = 0.3 + CGFloat(leftKeyCol) * 2.5
                let ky = 12.2 + CGFloat(row) * 1.0
                c.fill(Path(v.r(kx, ky, 2.0, 0.7)), with: .color(Self.kbHi.opacity(0.9)))
            }
            if rightHit {
                let row = (rightKeyCol - 3) % 3
                let kx = 0.3 + CGFloat(rightKeyCol) * 2.5
                let ky = 12.2 + CGFloat(row) * 1.0
                c.fill(Path(v.r(kx, ky, 2.0, 0.7)), with: .color(Self.kbHi.opacity(0.9)))
            }

            // 6. Arms on top — pivot at body connection (inner edge of arm)
            c.fill(armPath(v, x: 0, y: 9, w: 2, h: 2, pivotX: 2, pivotY: 10,
                           angle: armL, dy: dy), with: .color(Self.bodyC))
            c.fill(armPath(v, x: 13, y: 9, w: 2, h: 2, pivotX: 13, pivotY: 10,
                           angle: armR, dy: dy), with: .color(Self.bodyC))
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // ALERT — 3.5s cycle: startle → decaying jumps → rest
    // Matches clawd-notification.svg keyframes
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

    // Interpolate between keyframes: [(pct, value)]
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

    private func alertCanvas(t: Double) -> some View {
        let cycle = t.truncatingRemainder(dividingBy: 3.5)
        let pct = cycle / 3.5

        // Body jump — smooth interpolation from SVG keyframes
        let jumpY = lerp([
            (0, 0), (0.03, 0), (0.10, -1), (0.15, 1.5),
            (0.175, -10), (0.20, -10), (0.25, 1.5),
            (0.275, -8), (0.30, -8), (0.35, 1.2),
            (0.375, -5), (0.40, -5), (0.45, 1.0),
            (0.475, -3), (0.50, -3), (0.55, 0.5),
            (0.62, 0), (1.0, 0),
        ], at: pct)

        // Squash/stretch on landing (exaggerated for visibility)
        let scaleX: CGFloat = jumpY > 0.5 ? 1.0 + jumpY * 0.05 : 1.0  // squash wider
        let scaleY: CGFloat = jumpY > 0.5 ? 1.0 - jumpY * 0.04 : 1.0  // squash shorter

        // Arm waving — smooth interpolation
        let armL = lerp([
            (0, 0), (0.03, 0), (0.10, 25),
            (0.15, 30), (0.20, 155), (0.25, 115),
            (0.30, 140), (0.35, 100), (0.40, 115),
            (0.45, 80), (0.50, 80), (0.55, 40),
            (0.62, 0), (1.0, 0),
        ], at: pct)
        let armR = -lerp([
            (0, 0), (0.03, 0), (0.10, 30),
            (0.15, 30), (0.20, 155), (0.25, 115),
            (0.30, 140), (0.35, 100), (0.40, 115),
            (0.45, 80), (0.50, 80), (0.55, 40),
            (0.62, 0), (1.0, 0),
        ], at: pct)

        // Eye startle: widen + shift gaze on initial startle
        let eyeScale: CGFloat = (pct > 0.03 && pct < 0.15) ? 1.3 : 1.0
        let eyeDY: CGFloat = (pct > 0.03 && pct < 0.15) ? -0.5 : 0

        // ! mark
        let bangOpacity = lerp([
            (0, 0), (0.03, 1), (0.10, 1), (0.55, 1), (0.62, 0), (1.0, 0),
        ], at: pct)
        let bangScale = lerp([
            (0, 0.3), (0.03, 1.3), (0.10, 1.0), (0.55, 1.0), (0.62, 0.6), (1.0, 0.6),
        ], at: pct)

        return Canvas { c, sz in
            // Taller viewport to fit ! mark above head
            let v = V(sz, svgW: 15, svgH: 12, svgY0: 4)

            // Shadow — reacts to jump height
            let shadowW: CGFloat = 9 * (1.0 - abs(min(0, jumpY)) * 0.04)
            let shadowOp = max(0.08, 0.5 - abs(min(0, jumpY)) * 0.04)
            c.fill(Path(v.r(3 + (9 - shadowW) / 2, 15, shadowW, 1)),
                   with: .color(.black.opacity(shadowOp)))

            // Legs
            for x: CGFloat in [3, 5, 9, 11] {
                c.fill(Path(v.r(x, 11, 1, 4)), with: .color(Self.bodyC))
            }

            // Torso with squash/stretch
            let torsoW = 11 * scaleX
            let torsoH = 7 * scaleY
            let torsoX = 2 - (torsoW - 11) / 2
            let torsoY = 6 + (7 - torsoH)  // stretch from bottom
            c.fill(Path(v.r(torsoX, torsoY, torsoW, torsoH, dy: jumpY)),
                   with: .color(Self.bodyC))

            // Eyes (startled = wider)
            let eyeH = 2 * eyeScale
            let eyeYPos = 8 + (2 - eyeH) / 2 + eyeDY
            c.fill(Path(v.r(4, eyeYPos, 1, eyeH, dy: jumpY)), with: .color(Self.eyeC))
            c.fill(Path(v.r(10, eyeYPos, 1, eyeH, dy: jumpY)), with: .color(Self.eyeC))

            // Arms — correct pivot at body connection
            c.fill(armPath(v, x: 0, y: 9, w: 2, h: 2, pivotX: 2, pivotY: 10,
                           angle: armL, dy: jumpY), with: .color(Self.bodyC))
            c.fill(armPath(v, x: 13, y: 9, w: 2, h: 2, pivotX: 13, pivotY: 10,
                           angle: armR, dy: jumpY), with: .color(Self.bodyC))

            // ! mark — positioned above head, dampened movement (doesn't fly off screen)
            if bangOpacity > 0.01 {
                let bw: CGFloat = 2 * bangScale
                let bx: CGFloat = 13
                let by: CGFloat = 4.5 + jumpY * 0.15 // dampened: only 15% of jump
                c.fill(Path(v.r(bx, by, bw, 3.5 * bangScale, dy: 0)),
                       with: .color(Self.alertC.opacity(bangOpacity)))
                c.fill(Path(v.r(bx, by + 4.0 * bangScale, bw, 1.5 * bangScale, dy: 0)),
                       with: .color(Self.alertC.opacity(bangOpacity)))
            }
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MOOD SCENES — variants of sleep for idle states
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    // HUNGRY — big shake + wide open mouth + food emojis + rumble belly dots
    private var hungryScene: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                let phase = t.truncatingRemainder(dividingBy: 4.5) / 4.5
                let breathe: CGFloat = phase < 0.4 ? sin(phase / 0.4 * .pi) : 0
                // Big hungry shake: two frequencies
                let shake: CGFloat = sin(t * 14) * 0.9 + sin(t * 7.5) * 0.5
                Canvas { c, sz in
                    let v = V(sz, svgW: 17, svgH: 7, svgY0: 9)
                    c.translateBy(x: shake * v.s, y: 0)
                    drawSleeping(c, v: v, breathe: breathe)
                    // Wide open mouth (hunger gape): larger block
                    c.fill(Path(v.r(5, 13.0, 5, 1.5)),
                           with: .color(Self.eyeC.opacity(0.75)))
                    // Rumble belly dots pulsing
                    let rumble: CGFloat = sin(t * 22) > 0 ? 0.5 : 0.0
                    for dx: CGFloat in [0, 1.5, 3] {
                        c.fill(Path(v.r(5.5 + dx, 13.8, 0.7, 0.7)),
                               with: .color(Color(red: 1.0, green: 0.55, blue: 0.1).opacity(0.45 + rumble * 0.35)))
                    }
                    c.translateBy(x: -shake * v.s, y: 0)
                }
            }
            // Multiple food emojis floating up (5 types)
            TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                let foods = ["🍕", "🍔", "🍩", "🌮", "🍎"]
                ZStack {
                    ForEach(0..<5, id: \.self) { i in
                        let ci = Double(i)
                        let cycle = 2.1 + ci * 0.38
                        let delay = ci * 0.55
                        let p = ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle
                        let pp = max(0, p)
                        let xOff = size * CGFloat(-0.25 + ci * 0.14 + sin(pp * .pi * 1.5) * 0.10)
                        let yOff = -size * CGFloat(0.05 + pp * 0.42)
                        let op = pp < 0.70 ? 0.92 : (1.0 - pp) * 3.07 * 0.92
                        Text(foods[i % foods.count])
                            .font(.system(size: max(5, size * 0.20)))
                            .opacity(op)
                            .offset(x: xOff, y: yOff)
                    }
                }
            }
        }
    }

    // TIRED — nodding down + half-closed eye bars + two slow Zs
    private var tiredScene: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.07)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                // Slow shallow breathe
                let breathPhase = t.truncatingRemainder(dividingBy: 5.5) / 5.5
                let breathe: CGFloat = breathPhase < 0.3 ? sin(breathPhase / 0.3 * .pi) * 0.45 : 0
                Canvas { c, sz in
                    let v = V(sz, svgW: 17, svgH: 7, svgY0: 9)
                    drawSleeping(c, v: v, breathe: breathe)
                    // Extra droopy ear lines (wider blocks, more visible)
                    c.fill(Path(v.r(0.5, 7.8, 2.5, 1.0)), with: .color(Self.bodyC.opacity(0.65)))
                    c.fill(Path(v.r(12.0, 7.8, 2.5, 1.0)), with: .color(Self.bodyC.opacity(0.65)))
                    // Half-closed eye slits (on top of shut eyes in drawSleeping)
                    let eyeY: CGFloat = 12.2 - breathe * 2.5
                    // Thinner slit = half-open eyelid
                    c.fill(Path(v.r(3, eyeY + 0.5, 2.5, 0.5)), with: .color(Self.bodyC.opacity(0.6)))
                    c.fill(Path(v.r(9.5, eyeY + 0.5, 2.5, 0.5)), with: .color(Self.bodyC.opacity(0.6)))
                }
            }
            // Two staggered Zs (bigger font, farther travel)
            TimelineView(.periodic(from: .now, by: 0.07)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                ZStack {
                    ForEach(0..<2, id: \.self) { i in
                        let ci = Double(i)
                        let cycle = 3.6 + ci * 0.7
                        let delay = ci * 1.5
                        let phase = ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle
                        let p = max(0, phase)
                        let fontSize = max(7, size * CGFloat(0.23 + p * 0.11 + ci * 0.04))
                        let op = p < 0.75 ? 0.74 : (1.0 - p) * 2.96 * 0.74
                        let yOff = -size * CGFloat(0.10 + p * 0.44)
                        let xOff = size * CGFloat(0.06 + ci * 0.14)
                        Text("z")
                            .font(.system(size: fontSize, weight: .black, design: .monospaced))
                            .foregroundStyle(Color(red: 0.52, green: 0.62, blue: 1.0).opacity(op))
                            .offset(x: xOff, y: yOff)
                    }
                }
            }
        }
    }

    // SAD — cold-dim body + two tear streams + frown mouth mark
    private var sadScene: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.06)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                let phase = t.truncatingRemainder(dividingBy: 4.5) / 4.5
                let breathe: CGFloat = phase < 0.4 ? sin(phase / 0.4 * .pi) * 0.55 : 0
                Canvas { c, sz in
                    let v = V(sz, svgW: 17, svgH: 7, svgY0: 9)
                    // Cold-dim body (opacity + slight blue tint on torso)
                    var gctx = c
                    gctx.opacity = 0.72
                    drawSleeping(gctx, v: v, breathe: breathe)
                    // Frown: downward V below eyes
                    let eyeY: CGFloat = 12.2 - breathe * 2.5
                    c.fill(Path(v.r(5.0, eyeY + 1.5, 1.5, 0.7)), with: .color(Self.eyeC.opacity(0.55)))
                    c.fill(Path(v.r(6.5, eyeY + 2.2, 2.0, 0.7)), with: .color(Self.eyeC.opacity(0.55)))
                    c.fill(Path(v.r(8.5, eyeY + 1.5, 1.5, 0.7)), with: .color(Self.eyeC.opacity(0.55)))
                    // Cold blue wash on torso
                    let puff = max(0, breathe) * 0.25
                    let torsoH: CGFloat = 5 * (1.0 + puff)
                    let torsoY: CGFloat = 15 - torsoH
                    c.fill(Path(v.r(1, torsoY, 13, torsoH)),
                           with: .color(Color(red: 0.25, green: 0.45, blue: 0.90).opacity(0.12)))
                }
            }
            // Two staggered tear streams (longer fall, more visible)
            TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                ZStack {
                    ForEach(0..<2, id: \.self) { i in
                        let ci = Double(i)
                        let cycle = 1.7 + ci * 0.5
                        let delay = ci * 0.80
                        let phase = ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle
                        let pp = max(0, phase)
                        let yOff = size * CGFloat(0.04 + pp * 0.46)   // longer fall
                        let xOff = size * CGFloat(-0.08 + ci * 0.20)
                        let op = pp < 0.62 ? 0.82 : (1.0 - pp) * 2.16 * 0.82
                        Circle()
                            .fill(Color(red: 0.22, green: 0.50, blue: 1.0).opacity(op))
                            .frame(width: size * 0.082, height: size * 0.13)
                            .offset(x: xOff, y: yOff)
                    }
                }
            }
        }
    }

    // SICK — green body tint + big irregular shake + sweat drops (3) + more fever dots
    private var sickScene: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                let phase = t.truncatingRemainder(dividingBy: 4.5) / 4.5
                let breathe: CGFloat = phase < 0.4 ? sin(phase / 0.4 * .pi) * 0.35 : 0
                // Irregular sick shake
                let shake: CGFloat = sin(t * 8.5) * 1.0 + sin(t * 14) * 0.45
                Canvas { c, sz in
                    let v = V(sz, svgW: 17, svgH: 7, svgY0: 9)
                    c.translateBy(x: shake * v.s, y: 0)
                    // Green-tinted body (opacity reduction + green tint overlay)
                    var gctx = c
                    gctx.opacity = 0.78
                    drawSleeping(gctx, v: v, breathe: breathe)
                    // Green wash over torso
                    let puff = max(0, breathe) * 0.25
                    let torsoH: CGFloat = 5 * (1.0 + puff)
                    let torsoY: CGFloat = 15 - torsoH
                    c.fill(Path(v.r(1, torsoY, 13, torsoH)),
                           with: .color(Color(red: 0.2, green: 0.78, blue: 0.3).opacity(0.18)))
                    // X eyes over the existing shut-eye bars
                    let eyeY: CGFloat = 12.2 - puff * 2.5
                    // Left X
                    c.fill(Path(v.r(3.0, eyeY,       1.0, 1.0)), with: .color(Self.eyeC.opacity(0.85)))
                    c.fill(Path(v.r(3.8, eyeY + 0.8, 1.0, 1.0)), with: .color(Self.eyeC.opacity(0.85)))
                    c.fill(Path(v.r(3.8, eyeY,       1.0, 1.0)), with: .color(Self.eyeC.opacity(0.85)))
                    c.fill(Path(v.r(3.0, eyeY + 0.8, 1.0, 1.0)), with: .color(Self.eyeC.opacity(0.85)))
                    // Right X
                    c.fill(Path(v.r(9.5,  eyeY,       1.0, 1.0)), with: .color(Self.eyeC.opacity(0.85)))
                    c.fill(Path(v.r(10.3, eyeY + 0.8, 1.0, 1.0)), with: .color(Self.eyeC.opacity(0.85)))
                    c.fill(Path(v.r(10.3, eyeY,       1.0, 1.0)), with: .color(Self.eyeC.opacity(0.85)))
                    c.fill(Path(v.r(9.5,  eyeY + 0.8, 1.0, 1.0)), with: .color(Self.eyeC.opacity(0.85)))
                    // Fever dots above head (4 dots, bigger)
                    for i: CGFloat in [0, 1, 2, 3] {
                        let dotX = v.r(4.0 + i * 2.2, 7.2, 1.4, 1.4)
                        c.fill(Path(ellipseIn: dotX),
                               with: .color(Color(red: 0.95, green: 0.22, blue: 0.32).opacity(0.82)))
                    }
                    c.translateBy(x: -shake * v.s, y: 0)
                }
            }
            // 3 staggered sweat drops
            TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                ZStack {
                    ForEach(0..<3, id: \.self) { i in
                        let ci = Double(i)
                        let cycle = 1.5 + ci * 0.45
                        let delay = ci * 0.52
                        let p = ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle
                        let pp = max(0, p)
                        let xOff = size * CGFloat(-0.18 + ci * 0.20)
                        let yOff = size * CGFloat(0.06 + pp * 0.38)
                        let op = pp < 0.58 ? 0.80 : (1.0 - pp) * 1.905 * 0.80
                        Circle()
                            .fill(Color(red: 0.35, green: 0.88, blue: 0.55).opacity(op))
                            .frame(width: size * 0.070, height: size * 0.10)
                            .offset(x: xOff, y: yOff)
                    }
                }
            }
            // Stronger green overlay (more visible sick tint)
            Rectangle()
                .fill(Color(red: 0.2, green: 0.85, blue: 0.2).opacity(0.09))
                .frame(width: size, height: size)
                .allowsHitTesting(false)
        }
    }

    // JOYFUL — bouncy breathe + dense 12-particle sparkle ring
    private var joyfulScene: some View {
        ZStack {
            TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                // Bouncy exaggerated breathe
                let phase = t.truncatingRemainder(dividingBy: 3.0) / 3.0
                let breathe: CGFloat = phase < 0.45 ? sin(phase / 0.45 * .pi) * 1.4 : 0
                Canvas { c, sz in
                    let v = V(sz, svgW: 17, svgH: 7, svgY0: 9)
                    drawSleeping(c, v: v, breathe: breathe)
                }
            }
            // Dense sparkle ring: 12 particles (inner 6 gold + outer 6 white)
            TimelineView(.periodic(from: .now, by: 0.04)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate * speed
                ZStack {
                    // Inner ring: 6 bright gold ✦
                    ForEach(0..<6, id: \.self) { i in
                        let ci = Double(i)
                        let cycle = 1.2 + ci * 0.14
                        let delay = ci * 0.20
                        let phase = ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle
                        let p = max(0, phase)
                        let angle = ci * 60.0 * .pi / 180.0
                        let r = size * CGFloat(0.26 + p * 0.18)
                        let xOff = r * CGFloat(cos(angle))
                        let yOff = r * CGFloat(sin(angle)) - size * 0.10
                        let op = p < 0.58 ? 1.0 : (1.0 - p) * 2.38 * 1.0
                        Text("✦")
                            .font(.system(size: max(5, size * 0.16)))
                            .foregroundStyle(Color(red: 1.0, green: 0.82, blue: 0.0).opacity(op))
                            .offset(x: xOff, y: yOff)
                    }
                    // Outer ring: 6 smaller white-yellow ✦ offset by 30°
                    ForEach(0..<6, id: \.self) { i in
                        let ci = Double(i)
                        let cycle = 1.7 + ci * 0.20
                        let delay = ci * 0.28 + 0.10
                        let phase = ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle
                        let p = max(0, phase)
                        let angle = (ci * 60.0 + 30.0) * .pi / 180.0
                        let r = size * CGFloat(0.38 + p * 0.15)
                        let xOff = r * CGFloat(cos(angle))
                        let yOff = r * CGFloat(sin(angle)) - size * 0.07
                        let op = p < 0.52 ? 0.88 : (1.0 - p) * 1.83 * 0.88
                        Text("✦")
                            .font(.system(size: max(4, size * 0.11)))
                            .foregroundStyle(Color(red: 1.0, green: 1.0, blue: 0.65).opacity(op))
                            .offset(x: xOff, y: yOff)
                    }
                }
            }
        }
    }
}
