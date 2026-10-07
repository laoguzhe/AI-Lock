// 排查脚本：打印各屏在全局坐标系里的真实位置，以及 Dock 当前在哪块屏
import Cocoa

var count: UInt32 = 0
CGGetActiveDisplayList(0, nil, &count)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
CGGetActiveDisplayList(count, &ids, &count)

print("=== 屏幕排列（全局坐标，原点=主屏左上角，y 向下）===")
for id in ids.prefix(Int(count)) {
    let b = CGDisplayBounds(id)
    let tags = [
        CGDisplayIsBuiltin(id) != 0 ? "内置" : "外接",
        CGDisplayIsMain(id) != 0 ? "主屏" : nil,
    ].compactMap { $0 }.joined(separator: "/")
    print(String(format: "id=%-10u %-7@ x:%7.0f…%7.0f  y:%7.0f…%7.0f  (%.0f×%.0f)",
                 id, tags as NSString, b.minX, b.maxX, b.minY, b.maxY, b.width, b.height))
}

print("\n=== 每块屏底边下方 2pt 处，是否压着另一块屏（压着=当前逻辑会整条放行）===")
for id in ids.prefix(Int(count)) {
    let b = CGDisplayBounds(id)
    var covered: [String] = []
    // 沿底边横向采样，看有多少比例被下方屏覆盖
    let samples = 21
    for i in 0..<samples {
        let x = b.minX + b.width * CGFloat(i) / CGFloat(samples - 1)
        let p = CGPoint(x: min(x, b.maxX - 1), y: b.maxY + 2)
        if let hit = ids.prefix(Int(count)).first(where: { $0 != id && CGDisplayBounds($0).contains(p) }) {
            covered.append("\(hit)")
        }
    }
    let ratio = Double(covered.count) / Double(samples) * 100
    print(String(format: "id=%-10u 底边被下方屏覆盖 %.0f%%  %@", id, ratio,
                 (covered.isEmpty ? "→ 会拦截" : "→ 被放行(命中屏:\(Set(covered).sorted().joined(separator: ",")))") as NSString))
}

print("\n=== Dock 当前所在位置 ===")
if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
    for w in list where (w[kCGWindowOwnerName as String] as? String) == "Dock" {
        guard let d = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
        let r = CGRect(x: d["X"] ?? 0, y: d["Y"] ?? 0, width: d["Width"] ?? 0, height: d["Height"] ?? 0)
        let layer = w[kCGWindowLayer as String] as? Int ?? -1
        let onScreen = ids.prefix(Int(count)).first { CGDisplayBounds($0).intersects(r) }
        print(String(format: "layer=%-4d bounds=(%.0f,%.0f %.0f×%.0f)  所在屏=%u", layer,
                     r.minX, r.minY, r.width, r.height, onScreen ?? 0))
    }
} else {
    print("(无法读取窗口列表)")
}
