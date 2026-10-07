// 生成 App 图标：深蓝 squircle + 显示器 + Dock 条 + 挂锁
// 用法：swiftc -swift-version 5 -o /tmp/makeicon makeicon.swift && /tmp/makeicon out.png
import Cocoa

let S: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
ctx.setAllowsAntialiasing(true)
ctx.interpolationQuality = .high

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: a)
}
func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// MARK: 背景 squircle（macOS 图标惯例：1024 画布里内容占 824，四周留白）
let bg = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.saveGState()
ctx.addPath(rounded(bg, 185))
ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [rgb(96, 125, 255), rgb(38, 52, 140)] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 100), options: [])
ctx.restoreGState()

// MARK: 显示器外框
let screen = CGRect(x: 248, y: 380, width: 528, height: 400)
ctx.setStrokeColor(rgb(255, 255, 255))
ctx.setLineWidth(38)
ctx.addPath(rounded(screen.insetBy(dx: 19, dy: 19), 40))
ctx.strokePath()

// 显示器支架
ctx.setFillColor(rgb(255, 255, 255))
ctx.addPath(rounded(CGRect(x: 470, y: 310, width: 84, height: 80), 18))
ctx.fillPath()
ctx.addPath(rounded(CGRect(x: 407, y: 292, width: 210, height: 40), 20))
ctx.fillPath()

// MARK: 屏幕内的 Dock 条（图标语义的核心：Dock 就贴在这块屏的底边）
let dock = CGRect(x: 300, y: 440, width: 424, height: 82)
ctx.setFillColor(rgb(255, 255, 255, 0.95))
ctx.addPath(rounded(dock, 41))
ctx.fillPath()

// Dock 里的图标：用背景蓝挖空，避免颜色喧宾夺主
ctx.setFillColor(rgb(58, 76, 170))
for i in 0..<4 {
    let cx = 384.5 + CGFloat(i) * 85
    ctx.fillEllipse(in: CGRect(x: cx - 23, y: 481 - 23, width: 46, height: 46))
}

// MARK: 挂锁（压在右下角，先用背景色描一圈把它和显示器分开）
let bodyRect = CGRect(x: 640, y: 160, width: 210, height: 170)
let shackleCenter = CGPoint(x: 745, y: 330)
let shackleR: CGFloat = 60

func drawLock(inflate: CGFloat, color: CGColor) {
    ctx.setStrokeColor(color)
    ctx.setFillColor(color)
    // 锁梁
    ctx.setLineWidth(34 + inflate * 2)
    ctx.setLineCap(.round)
    ctx.addArc(center: shackleCenter, radius: shackleR,
               startAngle: 0, endAngle: .pi, clockwise: false)
    ctx.strokePath()
    // 锁体
    ctx.addPath(rounded(bodyRect.insetBy(dx: -inflate, dy: -inflate), 34 + inflate))
    ctx.fillPath()
}
drawLock(inflate: 22, color: rgb(45, 60, 155))   // 分隔描边
drawLock(inflate: 0, color: rgb(255, 200, 71))   // 锁本体

// 锁孔
ctx.setFillColor(rgb(45, 60, 155))
ctx.fillEllipse(in: CGRect(x: 745 - 24, y: 256 - 24, width: 48, height: 48))
ctx.addPath(rounded(CGRect(x: 745 - 13, y: 200, width: 26, height: 60), 13))
ctx.fillPath()

// MARK: 导出
guard let img = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: img)
guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! data.write(to: URL(fileURLWithPath: out))
print("✅ \(out)")
