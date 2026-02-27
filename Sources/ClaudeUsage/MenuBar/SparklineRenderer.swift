import AppKit
import CoreGraphics

struct SparklineRenderer {
    /// normalise values and build a CGPath polyline, filled with 20% alpha
    static func render(values: [Double], in rect: CGRect) -> CGPath {
        guard values.count >= 2 else { return CGMutablePath() }
        let minV = values.min()!
        let maxV = values.max()!
        let range = maxV - minV
        let path = CGMutablePath()
        func x(_ i: Int) -> CGFloat { rect.minX + CGFloat(i) / CGFloat(values.count - 1) * rect.width }
        func y(_ v: Double) -> CGFloat {
            let norm = range > 0 ? (v - minV) / range : 0.5
            return rect.minY + CGFloat(norm) * rect.height
        }
        path.move(to: CGPoint(x: x(0), y: y(values[0])))
        for i in 1..<values.count { path.addLine(to: CGPoint(x: x(i), y: y(values[i]))) }
        // close fill area
        path.addLine(to: CGPoint(x: x(values.count - 1), y: rect.minY))
        path.addLine(to: CGPoint(x: x(0), y: rect.minY))
        path.closeSubpath()
        return path
    }
}

struct MenuBarSparklineImage {
    static func render(values: [Double]) -> NSImage {
        let size = NSSize(width: 22, height: 16)
        let img = NSImage(size: size)
        img.lockFocus()
        let rect = CGRect(origin: .zero, size: CGSize(width: size.width, height: size.height))
        if let ctx = NSGraphicsContext.current?.cgContext {
            let path = SparklineRenderer.render(values: values, in: rect)
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.2).cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1)
            ctx.addPath(path)
            ctx.strokePath()
        }
        img.unlockFocus()
        img.isTemplate = true
        return img
    }
}
