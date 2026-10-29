// Offline check of the tremor filter: simulated tremor vs. deliberate twists, run through
// the OneEuro filter + soft deadband with a grid of parameters.
// Run:  mkdir -p /tmp/fsim && sed -n "/^struct OneEuro/,/^}/p" watch-bridge/Sources/Motion.swift > /tmp/fsim/euro.swift \
//       && cp research/filter-sim.swift /tmp/fsim/main.swift && swiftc -O /tmp/fsim/*.swift -o /tmp/fsim/sim && /tmp/fsim/sim
import Foundation
func run(_ sig: [Double], _ mc: Double, _ beta: Double, _ db: Double) -> (net: Double, path: Double, settle: Double) {
    var e = OneEuro(minCutoff: mc, beta: beta); var last: Double? = nil, tot = 0.0, path = 0.0, t95 = -1.0
    var outs = [Double]()
    for v in sig { let f = e.filter(v, dt: 0.04); outs.append(f)
        if let l = last { let d = f - l; let s = d*d*d/(d*d+db*db); let px = s*1100*(1+30*abs(s)); tot += px; path += abs(px) }
        last = f }
    if let fin = outs.last, fin != 0, let i = outs.firstIndex(where: { $0 >= 0.95*fin }) { t95 = Double(i)*0.04 - 1.5 }
    return (tot, path, t95)
}
let n = 250
var tremor = [Double](); for i in 0..<n { let t = Double(i)*0.04; tremor.append(0.0105*sin(2*Double.pi*9.3*t) + 0.004*sin(2*Double.pi*11.7*t+1)) }
var mv = [Double](); for i in 0..<n { let t = Double(i)*0.04; mv.append(t < 1 ? 0 : min(1, (t-1)/0.5) * 30 * Double.pi/180) }
var small = [Double](); for i in 0..<n { let t = Double(i)*0.04; small.append(t < 1 ? 0 : min(1, (t-1)/0.4) * 3 * Double.pi/180) }
print("cutoff beta deadband | tremor-path | 30deg-net settle | 3deg-net")
for mc in [0.8, 0.5, 0.3] { for beta in [2.0, 4.0, 8.0] { for db in [0.0015, 0.003, 0.005] {
    let t = run(tremor, mc, beta, db), m = run(mv, mc, beta, db), s = run(small, mc, beta, db)
    print(String(format: "%.1f %.0f %.4f | %5.0f | %5.0f %.2fs | %4.0f", mc, beta, db, t.path, m.net, m.settle, s.net))
}}}
