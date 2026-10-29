// AirMouse watch bridge — talks the classic Huami BLE protocol (as implemented in
// Gadgetbridge's HuamiSupport / InitOperation) to an Amazfit T-Rex Pro.
//
// Modes (first CLI arg):
//   probe  — connect, dump GATT, authenticate (if key), log raw sensor + device events. No mouse.
//   run    — probe + drive the macOS cursor.
//
// Everything is logged to watch-bridge/logs/airmouse.log so experiments are reproducible.

import Foundation
import CoreBluetooth
import CommonCrypto

// MARK: - Paths / logging

let projectDir: URL = {
    // The binary lives in watch-bridge/build/AirMouse.app/Contents/MacOS/
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    return exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
}()
let logURL = projectDir.appendingPathComponent("logs/airmouse.log")
let configURL = projectDir.appendingPathComponent("config.json")
let t0 = Date()

func log(_ s: String) {
    let line = String(format: "%8.3f ", Date().timeIntervalSince(t0)) + s + "\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined(separator: ":") }
    init?(hexString: String) {
        var s = hexString.lowercased()
        if s.hasPrefix("0x") { s.removeFirst(2) }
        guard s.count % 2 == 0 else { return nil }
        var d = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
            d.append(b); i = j
        }
        self = d
    }
}

// MARK: - Config

struct Config: Codable {
    var authKey: String?                // 16-byte hex from huami-token (with or without 0x)
    var deviceName: String?             // substring of the advertised name; default "T-Rex"
    var deviceNameContains: String { deviceName ?? "T-Rex" }

    // Motion tuning (all optional; defaults in Motion.swift)
    var gain: Double?                   // cursor pixels per radian of tilt change
    var smoothing: Double?              // EMA alpha 0..1 on gravity vector (lower = smoother)
    var deadband: Double?               // radians per sample ignored as hand tremor
    var acceleration: Double?           // extra gain for fast movements
    var invertX: Bool?
    var invertY: Bool?
    // Calibration (written by `calibrate` mode): raw gravity vectors
    var neutral: [Double]?
    var tiltRight: [Double]?
    var tiltUp: [Double]?
    // Device-event hex (e.g. "fe03") -> action: left, right, scrollUp, scrollDown, pause, recenter
    var buttons: [String: String]?
    var multiPressWindow: Double?       // seconds to wait for a 2nd/3rd press (delays single click)
    var scrollGain: Double?             // scroll pixels per cursor pixel in scroll mode
    var playbackSeconds: Double?        // replay each 0.81 s watch batch in this long (lower = less lag, more pulsing)
    var glide: Double?                  // 0..1 share of pending motion emitted per 10 ms (lower = smoother)
    var tremorCutoff: Double?           // 1€ min cutoff Hz (lower = more tremor removed when still)
    var tremorBeta: Double?             // 1€ speed coefficient (higher = less lag on fast moves)
}

func saveConfig(_ c: Config) {
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let d = try? enc.encode(c) { try? d.write(to: configURL) }
}

func loadConfig() -> Config {
    guard let d = try? Data(contentsOf: configURL) else { return Config() }
    do { return try JSONDecoder().decode(Config.self, from: d) } catch {
        log("config.json parse error: \(error)"); return Config()
    }
}

// MARK: - Huami protocol constants (Gadgetbridge HuamiService / Huami2021Service)

func huamiUUID(_ short: String) -> CBUUID { CBUUID(string: "0000\(short)-0000-3512-2118-0009af100700") }
let UUID_AUTH = huamiUUID("0009")
let UUID_DEVICE_EVENT = huamiUUID("0010")
let UUID_RAW_CTL = huamiUUID("0001")
let UUID_RAW_DATA = huamiUUID("0002")

var verboseRaw = CommandLine.arguments.contains("--verbose")

let CRYPT_FLAGS: UInt8 = 0x80   // AmazfitGTSSupport.getCryptFlags (T-Rex Pro extends GTS)
let AUTH_FLAGS: UInt8 = 0x00

func aes128ecb(_ block: Data, key: Data) -> Data? {
    var out = Data(count: block.count + kCCBlockSizeAES128)
    var moved = 0
    let outCap = out.count
    let st = out.withUnsafeMutableBytes { o in
        block.withUnsafeBytes { i in
            key.withUnsafeBytes { k in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                        k.baseAddress, key.count, nil, i.baseAddress, block.count,
                        o.baseAddress, outCap, &moved)
            }
        }
    }
    guard st == kCCSuccess else { return nil }
    return out.prefix(moved)
}

// MARK: - Watch link

protocol WatchDelegate: AnyObject {
    func watchAccel(x: Int16, y: Int16, z: Int16)
    func watchEvent(_ bytes: Data)
    func watchReady()
}

final class WatchLink: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    let cfg: Config
    weak var delegate: WatchDelegate?
    var central: CBCentralManager!
    var peripheral: CBPeripheral?
    var chars: [CBUUID: CBCharacteristic] = [:]
    var pendingServices = 0
    var authenticated = false

    // stats
    var rawPackets = 0, rawSamples = 0, statT = Date()

    init(cfg: Config) {
        self.cfg = cfg
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        log("BT state=\(c.state.rawValue) auth=\(CBManager.authorization.rawValue)")
        guard c.state == .poweredOn else { return }
        let connected = c.retrieveConnectedPeripherals(withServices: [CBUUID(string: "FEE0"), CBUUID(string: "FEE1")])
        log("already-connected Huami peripherals: \(connected.map { $0.name ?? "?" })")
        if let p = connected.first(where: { ($0.name ?? "").localizedCaseInsensitiveContains(cfg.deviceNameContains) }) {
            attach(p); return
        }
        log("scanning for name containing '\(cfg.deviceNameContains)' ...")
        c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        if name.isEmpty { return }
        log("adv \(p.identifier) rssi=\(rssi) name=\(name) svcs=\((ad[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? [])")
        if name.localizedCaseInsensitiveContains(cfg.deviceNameContains) {
            c.stopScan(); attach(p)
        }
    }

    func attach(_ p: CBPeripheral) {
        peripheral = p; p.delegate = self
        log("connecting to \(p.name ?? "?") \(p.identifier)")
        central.connect(p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        log("connected; discovering services")
        p.discoverServices(nil)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log("connect failed: \(String(describing: error))")
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        log("disconnected: \(String(describing: error)); reconnecting in 2s")
        authenticated = false; chars = [:]
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { c.connect(p) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        let svcs = p.services ?? []
        pendingServices = svcs.count
        for s in svcs { p.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        log("[S] \(s.uuid)")
        for ch in s.characteristics ?? [] {
            log("   [C] \(ch.uuid) props=0x\(String(ch.properties.rawValue, radix: 16))")
            chars[ch.uuid] = ch
        }
        pendingServices -= 1
        if pendingServices == 0 { startSession() }
    }

    func startSession() {
        guard let p = peripheral else { return }
        for u in [UUID_AUTH, UUID_DEVICE_EVENT, UUID_RAW_CTL, UUID_RAW_DATA] {
            if let ch = chars[u], ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                p.setNotifyValue(true, for: ch)
            }
        }
        if cfg.authKey == nil {
            log("NO authKey in config.json — skipping auth; trying raw sensor unauthenticated (expected to fail)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.startRawSensor() }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        log("notify \(ch.uuid) on=\(ch.isNotifying) err=\(String(describing: error))")
        if ch.uuid == UUID_AUTH, ch.isNotifying, cfg.authKey != nil {
            write(UUID_AUTH, Data([CRYPT_FLAGS | 0x02, AUTH_FLAGS, 0x02, 0x01, 0x00]))
        }
    }

    func write(_ u: CBUUID, _ d: Data) {
        guard let p = peripheral, let ch = chars[u] else { log("write: missing char \(u)"); return }
        let type: CBCharacteristicWriteType = ch.properties.contains(.write) ? .withResponse : .withoutResponse
        log("-> \(u.uuidString.prefix(8)) \(d.hex)")
        p.writeValue(d, for: ch, type: type)
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        if let error { log("write err \(ch.uuid): \(error)") }
    }

    func startRawSensor() {
        // Default: Huami2021Service CMD_RAW_SENSOR_START_1..3 (used by HuamiSupport.setRawSensor).
        // Override for experiments: --start=010319,010300000019,02
        // Verified: 01:01:00:00:00:19 + 02 = accelerometer only, 25 Hz, delivered as 20-sample batches every ~0.81 s.
        var cmds = ["010100000019", "02"]
        if let a = CommandLine.arguments.first(where: { $0.hasPrefix("--start=") }) {
            cmds = a.dropFirst(8).split(separator: ",").map(String.init)
        }
        for c in cmds { if let d = Data(hexString: c) { write(UUID_RAW_CTL, d) } }
        // Experiment: --flush=<ms>:<hex>,<hex> periodically writes commands to try to force the FIFO out early.
        if flushTimer == nil, let a = CommandLine.arguments.first(where: { $0.hasPrefix("--flush=") }) {
            let parts = a.dropFirst(8).split(separator: ":")
            let ms = Double(parts[0]) ?? 200
            let fcmds = parts.count > 1 ? parts[1].split(separator: ",").compactMap { Data(hexString: String($0)) } : []
            flushTimer = Timer.scheduledTimer(withTimeInterval: ms / 1000, repeats: true) { [weak self] _ in
                guard let self, self.authenticated, let p = self.peripheral, let ch = self.chars[UUID_RAW_CTL] else { return }
                for d in fcmds { p.writeValue(d, for: ch, type: .withoutResponse) }
            }
        }
    }
    var flushTimer: Timer?

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let v = ch.value else { return }
        switch ch.uuid {
        case UUID_AUTH: handleAuth(v)
        case UUID_RAW_DATA: handleRaw(v)
        case UUID_DEVICE_EVENT:
            log("EVENT \(v.hex)")
            delegate?.watchEvent(v)
        default:
            log("<- \(ch.uuid.uuidString.prefix(8)) \(v.hex)")
        }
    }

    func handleAuth(_ v: Data) {
        log("<- AUTH \(v.hex)")
        let b = [UInt8](v)
        guard b.count >= 3, b[0] == 0x10 else { return }
        if (b[1] & 0x0f) == 0x02, b[2] == 0x01, b.count >= 19 {
            guard let key = Data(hexString: cfg.authKey ?? ""), key.count == 16,
                  let enc = aes128ecb(Data(b[3..<19]), key: key) else {
                log("bad authKey (need 32 hex chars)"); return
            }
            write(UUID_AUTH, Data([CRYPT_FLAGS | 0x03, AUTH_FLAGS]) + enc)
        } else if (b[1] & 0x0f) == 0x03 {
            if b[2] == 0x01 {
                log("AUTH OK")
                authenticated = true
                startRawSensor()
                delegate?.watchReady()
            } else {
                log("AUTH FAILED (code \(b[2])) — key wrong or watch re-paired")
            }
        }
    }

    func handleRaw(_ v: Data) {
        let b = [UInt8](v)
        guard b.count >= 2 else { return }
        rawPackets += 1
        if b[0] == 0x00, (b.count - 2) % 6 == 0 {
            if verboseRaw { log("PKT0 idx=\(b[1]) n=\((b.count - 2) / 6)") }
            var i = 2
            while i + 6 <= b.count {
                let x = Int16(bitPattern: UInt16(b[i]) | UInt16(b[i + 1]) << 8)
                let y = Int16(bitPattern: UInt16(b[i + 2]) | UInt16(b[i + 3]) << 8)
                let z = Int16(bitPattern: UInt16(b[i + 4]) | UInt16(b[i + 5]) << 8)
                rawSamples += 1
                delegate?.watchAccel(x: x, y: y, z: z)
                i += 6
            }
        } else if verboseRaw {
            log("RAW type=\(b[0]) \(v.hex)")
        }
        let dt = Date().timeIntervalSince(statT)
        if dt >= 2 {
            log(String(format: "raw stats: %.1f pkt/s, %.1f samples/s", Double(rawPackets) / dt, Double(rawSamples) / dt))
            rawPackets = 0; rawSamples = 0; statT = Date()
        }
    }
}

// MARK: - Controller

final class Controller: WatchDelegate {
    let mode: String
    let motion: Motion
    var n = 0
    var calibrator: Calibrator?
    var buttonTest: ButtonTest?

    init(mode: String, cfg: Config) {
        self.mode = mode
        motion = Motion(cfg: cfg, moving: mode == "run")
    }

    func watchAccel(x: Int16, y: Int16, z: Int16) {
        n += 1
        if mode == "probe", n % 5 == 0 { log("ACC \(x) \(y) \(z)") }
        motion.push(x: x, y: y, z: z)
    }

    func watchEvent(_ bytes: Data) {
        let key = bytes.map { String(format: "%02x", $0) }.joined()
        buttonTest?.record(key)
        guard mode == "run" else { return }
        // Verified (buttontest): SELECT/UP/DOWN all send `04`, long SELECT sends `0b`, BACK and touch send nothing.
        // So `04` is press-counted: "04x1", "04x2", ... are looked up after the multi-press window closes.
        let map = buttonMap
        if map.keys.contains(where: { $0.hasPrefix(key + "x") }) {
            pressCount[key, default: 0] += 1
            pressTimer[key]?.cancel()
            let w = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let n = self.pressCount[key] ?? 1
                self.pressCount[key] = 0
                if let a = map["\(key)x\(n)"] { self.perform(a) } else { log("no action for \(key)x\(n)") }
            }
            pressTimer[key] = w
            DispatchQueue.main.asyncAfter(deadline: .now() + (motion.cfg.multiPressWindow ?? 0.45), execute: w)
        } else if let a = map[key] {
            perform(a)
        }
    }

    var pressCount: [String: Int] = [:]
    var pressTimer: [String: DispatchWorkItem] = [:]
    var buttonMap: [String: String] {
        motion.cfg.buttons ?? ["04x1": "left", "04x2": "right", "04x3": "pause", "0b": "scrollMode"]
    }

    func perform(_ action: String) {
        log("action \(action)")
        switch action {
        case "left": Mouse.click(right: false)
        case "right": Mouse.click(right: true)
        case "scrollUp": Mouse.scroll(lines: 3)
        case "scrollDown": Mouse.scroll(lines: -3)
        case "pause":
            motion.paused.toggle()
            if !motion.paused { motion.recenter() }
            say(motion.paused ? "paused" : "resumed")
        case "recenter": motion.recenter()
        case "scrollMode":
            motion.scrollMode.toggle()
            motion.recenter()
            say(motion.scrollMode ? "scroll" : "pointer")
        default: log("unknown action \(action)")
        }
    }

    func watchReady() {
        log("ready (mode \(mode))")
        if mode == "buttontest", buttonTest == nil {
            buttonTest = ButtonTest()
            buttonTest?.run { exit(0) }
        }
        if mode == "calibrate", calibrator == nil {
            calibrator = Calibrator(motion: motion)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.calibrator?.run { exit(0) }
            }
        }
    }
}

// MARK: - Guided button test: spoken prompts, events attributed to the prompt window they arrive in

final class ButtonTest {
    var current: String?
    var hits: [String: [String]] = [:]
    var order: [String] = []

    func record(_ key: String) {
        guard let c = current else { log("event outside window: \(key)"); return }
        hits[c, default: []].append(key)
    }

    func run(done: @escaping () -> Void) {
        var prompts: [(String, String)] = [("idle", "Button test. Don't touch the watch for a few seconds.")]
        for b in ["select", "up", "down", "back"] {
            for i in 1...3 { prompts.append(("\(b) \(i)", "Press \(b == "select" ? "select, upper right" : b == "up" ? "up, upper left" : b == "down" ? "down, lower left" : "back, lower right"), once.")) }
        }
        prompts += [("tap", "Tap the middle of the screen once."),
                    ("swipe up", "Swipe up on the screen."), ("swipe down", "Swipe down on the screen."),
                    ("swipe left", "Swipe left on the screen."), ("swipe right", "Swipe right on the screen."),
                    ("long select", "Press and hold select for two seconds.")]
        var t = 1.0
        for (key, text) in prompts {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                self.current = key; self.order.append(key); say(text)
            }
            t += 6
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + t) {
            self.current = nil
            var lines = ["button test \(Date())"]
            for k in self.order { lines.append("\(k.padding(toLength: 12, withPad: " ", startingAt: 0)) \(self.hits[k]?.joined(separator: " ") ?? "-")") }
            let summary = lines.joined(separator: "\n")
            log("BUTTON TEST SUMMARY\n" + summary)
            try? summary.write(to: projectDir.appendingPathComponent("logs/buttontest-summary.txt"), atomically: true, encoding: .utf8)
            say("Button test finished.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { done() }
        }
    }
}

// MARK: - main

try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
let mode = CommandLine.arguments.dropFirst().first ?? "probe"
let cfg = loadConfig()
log("=== AirMouse start mode=\(mode) key=\(cfg.authKey == nil ? "none" : "set") project=\(projectDir.path)")
if mode == "run" {
    var trusted = Mouse.trusted(prompt: true)
    log("accessibility trusted=\(trusted)")
    if !trusted { say("AirMouse needs Accessibility permission to move the cursor.") }
    // The grant can arrive while running (and is tied to this exact build), so poll and announce it.
    Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
        let now = Mouse.trusted(prompt: false)
        if now != trusted { trusted = now; log("accessibility trusted=\(now)"); say(now ? "Mouse control enabled." : "Mouse control disabled.") }
    }
}
let controller = Controller(mode: mode, cfg: cfg)
let link = WatchLink(cfg: cfg)
link.delegate = controller
RunLoop.main.run()
