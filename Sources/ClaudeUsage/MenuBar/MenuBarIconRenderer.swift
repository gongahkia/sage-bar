import AppKit
import CoreGraphics

enum HealthDot { case healthy, estimated, error }

struct MenuBarIconRenderer {
    static func render(
        inputRatio: Double, // 0..1 proportion of input tokens
        outputRatio: Double, // 0..1 proportion of output tokens
        cacheRatio: Double, // 0..1 proportion of cache tokens
        health: HealthDot
    ) -> NSImage {
        let size = NSSize(width: 28, height: 18)
        let img = NSImage(size: size)
        img.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            img.unlockFocus()
            return img
        }
        let barWidth: CGFloat = 4
        let barSpacing: CGFloat = 2
        let barBottom: CGFloat = 2
        let maxBarHeight: CGFloat = 14
        let barX: CGFloat = 4
        let barColor = adaptiveMenuBarGlyphColor()
        let bars: [(ratio: Double, alpha: CGFloat)] = [
            (inputRatio, 0.95),
            (outputRatio, 0.72),
            (cacheRatio, 0.48),
        ]
        for (i, bar) in bars.enumerated() {
            let h = max(2, CGFloat(max(0, min(1, bar.ratio))) * maxBarHeight)
            let x = barX + CGFloat(i) * (barWidth + barSpacing)
            let rect = CGRect(x: x, y: barBottom, width: barWidth, height: h)
            ctx.setFillColor(barColor.withAlphaComponent(bar.alpha).cgColor)
            let path = CGPath(roundedRect: rect, cornerWidth: 1, cornerHeight: 1, transform: nil)
            ctx.addPath(path)
            ctx.fillPath()
        }
        // health dot
        let dotRadius: CGFloat = 2.5
        let dotCenter = CGPoint(x: barX + 3 * (barWidth + barSpacing) + dotRadius + 1, y: size.height - dotRadius - 1)
        let dotColor: CGColor
        switch health {
        case .healthy: dotColor = NSColor.systemGreen.cgColor
        case .estimated: dotColor = NSColor.systemOrange.cgColor
        case .error: dotColor = NSColor.systemRed.cgColor
        }
        ctx.setFillColor(dotColor)
        ctx.fillEllipse(in: CGRect(
            x: dotCenter.x - dotRadius,
            y: dotCenter.y - dotRadius,
            width: dotRadius * 2,
            height: dotRadius * 2
        ))
        img.unlockFocus()
        img.isTemplate = false // colored dot requires non-template
        return img
    }

    private static func adaptiveMenuBarGlyphColor() -> NSColor {
        let appearance = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        return appearance == .darkAqua ? .white : .labelColor
    }

    static func renderFromSnapshot(
        _ snapshot: UsageSnapshot?,
        health: HealthDot
    ) -> NSImage {
        guard let snap = snapshot else {
            return render(inputRatio: 0, outputRatio: 0, cacheRatio: 0, health: health)
        }
        let total = max(1, Double(snap.inputTokens + snap.outputTokens + snap.cacheCreationTokens + snap.cacheReadTokens))
        return render(
            inputRatio: Double(snap.inputTokens) / total,
            outputRatio: Double(snap.outputTokens) / total,
            cacheRatio: Double(snap.cacheCreationTokens + snap.cacheReadTokens) / total,
            health: health
        )
    }
}
