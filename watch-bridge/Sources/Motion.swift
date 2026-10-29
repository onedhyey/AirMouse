// Tilt -> cursor engine and macOS event output.
//
// The watch only exposes an accelerometer (no gyro), so we can sense pitch/roll relative to
// gravity but not yaw. Samples arrive in 20-sample batches every ~0.81 s (firmware FIFO), so:
//   * batches are replayed at 25 Hz by a 100 Hz timer (smooth motion, constant delay), and
//   * the cursor moves by the *change* in tilt angle (position-like control): when the hand
//     stops, the cursor stops — no overshoot from the batching delay, unlike tilt-rate control.

import Foundation
import CoreGraphics
import ApplicationServices

typealias V3 = SIMD3<Double>
func norm(_ v: V3) -> V3 { let l = (v * v).sum().squareRoot(); return l > 0 ? v / l : v }
func dot(_ a: V3, _ b: V3) -> Double { (a * b).sum() }
func cross(_ a: V3, _ b: V3) -> V3 {
    V3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}
func v3(_ a: [Double]?) -> V3? { guard let a, a.count == 3 else { return nil }; return V3(a[0], a[1], a[2]) }

// MARK: - Mouse output

enum Mouse {
    static func trusted(prompt: Bool) -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    static var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    static var desktop: CGRect {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &n)
        return ids.prefix(Int(n)).map { CGDisplayBounds($0) }.reduce(CGRect.null) { $0.union($1) }
    }

    static var leftDown = false

    static func move(dx: Double, dy: Double) {
        let d = desktop
        var p = location
        p.x = min(max(p.x + dx, d.minX), d.maxX - 1)
        p.y = min(max(p.y + dy, d.minY), d.maxY - 1)
        let type: CGEventType = leftDown ? .leftMouseDragged : .mouseMoved
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    static func click(right: Bool) {
        let p = location
        let (down, up, btn): (CGEventType, CGEventType, CGMouseButton) =
            right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
        CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: p, mouseButton: btn)?.post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: p, mouseButton: btn)?.post(tap: .cghidEventTap)
    }

    static func scrollPixels(dx: Int32, dy: Int32) {
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    static func scroll(lines: Int32, horizontal: Bool = false) {
        let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                        wheel1: horizontal ? 0 : lines, wheel2: horizontal ? lines : 0, wheel3: 0)
        e?.post(tap: .cghidEventTap)
    }
}

// MARK: - Motion engine

/// 1€ filter (Casiez et al., CHI 2012): adaptive low-pass for pointing. Heavy smoothing when the
/// signal is slow (kills hand tremor), light smoothing when it moves fast (keeps latency low).
struct OneEuro {
    var minCutoff: Double, beta: Double, dCutoff = 1.0
    var x: Double?, dx = 0.0
    static func alpha(_ cutoff: Double, _ dt: Double) -> Double { 1 / (1 + 1 / (2 * .pi * cutoff * dt)) }
    mutating func filter(_ v: Double, dt: Double) -> Double {
        guard let px = x else { x = v; return v }
        let ad = OneEuro.alpha(dCutoff, dt)
        dx = dx + ad * ((v - px) / dt - dx)
        let a = OneEuro.alpha(minCutoff + beta * abs(dx), dt)
        let nx = px + a * (v - px)
        x = nx
        return nx
    }
}

final class Motion {
    var cfg: Config
    var queue: [V3] = []
    var budget = 0.0
    var filtered: V3?
    var g0 = V3(0, 0, 1), u = V3(1, 0, 0), v = V3(0, 1, 0)
    var last: (Double, Double)?
    var euroX: OneEuro, euroY: OneEuro
    var pending = (0.0, 0.0)          // pixels decided but not yet emitted (released smoothly at 100 Hz)
    var rem = (0.0, 0.0)
    var paused = false
    var scrollMode = false
    var moved = (0.0, 0.0), movedT = Date()
    var moving: Bool   // false in calibrate mode
    var timer: Timer?
    var onSample: ((V3) -> Void)?   // raw (unfiltered, unit-less) sample tap for calibration

    static let sampleDt = 1.0 / 25     // watch sampling period (verified 25 Hz)
    static let batchSamples = 20.0     // watch FIFO batch size (verified)

    var gain: Double { cfg.gain ?? 1600 }
    var alpha: Double { cfg.smoothing ?? 0.6 }            // light pre-filter on the gravity vector
    var deadband: Double { cfg.deadband ?? 0.003 }       // soft: moves much smaller than this fade out
    var accel: Double { cfg.acceleration ?? 10 }
    var playbackSeconds: Double { cfg.playbackSeconds ?? 0.35 }   // replay one 0.81 s batch in this long
    var glide: Double { cfg.glide ?? 0.35 }               // fraction of pending pixels emitted per 10 ms

    init(cfg: Config, moving: Bool) {
        self.cfg = cfg
        self.moving = moving
        euroX = OneEuro(minCutoff: cfg.tremorCutoff ?? 0.3, beta: cfg.tremorBeta ?? 4)
        euroY = OneEuro(minCutoff: cfg.tremorCutoff ?? 0.3, beta: cfg.tremorBeta ?? 4)
        setAxes()
        timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// Basis from calibration: g0 = neutral gravity, u = "tilt right" direction, v = "tilt up" direction,
    /// both projected perpendicular to g0. Without calibration, assume face-up and the watch's own x/y.
    func setAxes() {
        if let n = v3(cfg.neutral), let r = v3(cfg.tiltRight), let up = v3(cfg.tiltUp) {
            g0 = norm(n)
            u = norm(norm(r) - dot(norm(r), g0) * g0)
            var vv = norm(norm(up) - dot(norm(up), g0) * g0)
            vv = norm(vv - dot(vv, u) * u)
            v = vv
            log("axes from calibration g0=\(g0) u=\(u) v=\(v)")
        } else {
            log("no calibration — using default axes (run `calibrate`)")
        }
    }

    /// Re-anchor neutral to the current pose, keeping the right/up directions. Cursor does not move.
    func recenter() {
        guard let f = filtered else { return }
        g0 = norm(f)
        u = norm(u - dot(u, g0) * g0)
        v = norm(cross(g0, u) * (dot(cross(g0, u), v) >= 0 ? 1 : -1))
        last = nil
        euroX.x = nil; euroY.x = nil
        pending = (0, 0)
        log("recentered g0=\(g0)")
    }

    func push(x: Int16, y: Int16, z: Int16) {
        let s = V3(Double(x), Double(y), Double(z)) / 4100
        queue.append(s)
        onSample?(s)
    }

    func tick() {
        // Replay a batch faster than real time (20 samples in `playbackSeconds`), and faster still if a
        // backlog builds, so the added delay stays small and never accumulates.
        let rate = Motion.batchSamples / max(0.05, playbackSeconds)
        let backlog = max(0, Double(queue.count) - Motion.batchSamples) / Motion.batchSamples
        budget += 0.01 * rate * (1 + backlog)
        while budget >= 1, !queue.isEmpty {
            budget -= 1
            step(queue.removeFirst())
        }
        if queue.isEmpty { budget = min(budget, 1) }
        emit()
    }

    var samplesSeen = 0

    func step(_ s: V3) {
        filtered = filtered.map { $0 + alpha * (s - $0) } ?? s
        samplesSeen += 1
        if samplesSeen == 10 { recenter() }   // the pose you start in is neutral
        let g = norm(filtered!)
        let c = dot(g, g0)
        let ax = euroX.filter(atan2(dot(g, u), c), dt: Motion.sampleDt)
        let ay = euroY.filter(atan2(dot(g, v), c), dt: Motion.sampleDt)
        defer { last = (ax, ay) }
        guard moving, !paused, let (lx, ly) = last else { return }
        func shape(_ d: Double) -> Double {
            // Soft deadband: d·d²/(d²+t²) — tiny moves fade out smoothly instead of snapping on/off.
            let t = deadband, soft = d * d * d / (d * d + t * t)
            return soft * gain * (1 + accel * abs(soft))
        }
        var dx = shape(ax - lx), dy = -shape(ay - ly)    // screen y grows downward
        if cfg.invertX == true { dx = -dx }
        if cfg.invertY == true { dy = -dy }
        if scrollMode {
            // Tilt scrolls instead of pointing: tilt up shows content above, tilt right shows content to the right.
            let k = cfg.scrollGain ?? 1.0
            dx *= -k; dy *= -k
        }
        pending.0 += dx; pending.1 += dy
    }

    /// Release pending pixels as a 100 Hz glide so the cursor moves smoothly between samples.
    func emit() {
        var ox = pending.0 * glide, oy = pending.1 * glide
        if abs(pending.0) < 1 { ox = pending.0 }
        if abs(pending.1) < 1 { oy = pending.1 }
        pending.0 -= ox; pending.1 -= oy
        rem.0 += ox; rem.1 += oy
        let ix = rem.0.rounded(.towardZero), iy = rem.1.rounded(.towardZero)
        rem.0 -= ix; rem.1 -= iy
        moved.0 += abs(ix); moved.1 += abs(iy)
        if Date().timeIntervalSince(movedT) >= 3 {
            if moved.0 + moved.1 > 0 {
                log(String(format: "moved |dx|=%.0f |dy|=%.0f px in 3 s (%@)", moved.0, moved.1, scrollMode ? "scroll" : "pointer"))
            }
            moved = (0, 0); movedT = Date()
        }
        guard ix != 0 || iy != 0 else { return }
        if scrollMode { Mouse.scrollPixels(dx: Int32(ix), dy: Int32(iy)) } else { Mouse.move(dx: ix, dy: iy) }
    }
}

// MARK: - Calibration (spoken prompts; the watch data arrives ~0.8 s late, so phases are generous)

func say(_ s: String, then: (() -> Void)? = nil) {
    log("SAY: \(s)")
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/say"); p.arguments = [s]
    if let then { p.terminationHandler = { _ in DispatchQueue.main.async(execute: then) } }
    do { try p.run() } catch { then?() }
}

func play(_ sound: String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
    p.arguments = ["/System/Library/Sounds/\(sound).aiff"]
    try? p.run()
}

final class Calibrator {
    var samples: [(Date, V3)] = []
    let motion: Motion
    init(motion: Motion) {
        self.motion = motion
        motion.onSample = { [weak self] s in self?.samples.append((Date(), s)) }
    }

    func mean(from a: Date, to b: Date) -> V3? {
        let sel = samples.filter { $0.0 >= a && $0.0 <= b }.map { $0.1 }
        guard sel.count >= 10 else { return nil }
        return sel.reduce(V3(0, 0, 0), +) / Double(sel.count)
    }

    func run(done: @escaping () -> Void) {
        let steps: [(String, String?)] = [
            ("Calibration. Hold the watch in your pointing pose. After each tink, hold still until the pop.", "neutral"),
            // Turning the hand flat (yaw) is invisible to an accelerometer, so ask for a wrist twist (roll).
            ("Twist your wrist clockwise, like turning a key, a quarter turn, for cursor right.", "right"),
            ("Back to neutral.", nil),
            ("Tilt the watch up, for cursor up.", "up"),
        ]
        var results: [String: V3] = [:]
        // Sequential: speak, wait for speech to end, "tink" = start holding, measure, "pop" = done.
        // Samples arrive up to ~0.8 s late (watch FIFO), so the window starts 1.6 s after the tink.
        func next(_ i: Int) {
            guard i < steps.count else { finish(); return }
            let (text, key) = steps[i]
            say(text) {
                guard let key else { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { next(i + 1) }; return }
                play("Tink")
                let t = Date()
                DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                    if let m = self.mean(from: t.addingTimeInterval(1.6), to: t.addingTimeInterval(4.0)) {
                        results[key] = m
                        log("calib \(key) = \(m)  (|g|=\((m * m).sum().squareRoot()))")
                    } else { log("calib \(key): not enough samples") }
                    play("Pop")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { next(i + 1) }
                }
            }
        }
        func finish() {
            guard let n = results["neutral"], var r = results["right"], let up = results["up"] else {
                say("Calibration failed. Not enough data.", then: done); return
            }
            let ang = { (a: V3, b: V3) in acos(min(1, dot(norm(a), norm(b)))) * 180 / .pi }
            log(String(format: "tilt right = %.1f°, tilt up = %.1f°", ang(n, r), ang(n, up)))
            if ang(n, up) < 10 {
                say(String(format: "Calibration failed. The up tilt was only %.0f degrees. Please tilt further.", ang(n, up)), then: done); return
            }
            // Weak or ambiguous twist: derive "right" as perpendicular to "up" (sign fixable with invertX).
            let g0 = norm(n)
            let vDir = norm(norm(up) - dot(norm(up), g0) * g0)
            let rDir = norm(norm(r) - dot(norm(r), g0) * g0)
            if ang(n, r) < 8 || abs(dot(rDir, vDir)) > 0.7 {
                var perp = cross(g0, vDir)
                if ang(n, r) >= 3, dot(perp, rDir) < 0 { perp = -perp }   // keep the user's sign if there is one
                r = g0 + 0.5 * perp
                log("right derived as perpendicular to up: \(r)")
            }
            var c = loadConfig()
            c.neutral = [n.x, n.y, n.z]; c.tiltRight = [r.x, r.y, r.z]; c.tiltUp = [up.x, up.y, up.z]
            saveConfig(c)
            say("Calibration saved.", then: done)
        }
        next(0)
    }
}
