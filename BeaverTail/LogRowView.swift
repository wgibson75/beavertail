//
//  LogRowView.swift
//  BeaverTail
//
import AppKit
// MARK: - LogRowView
// Custom row view that paints the highlight-rule background AND a faint
// selection tint layered on top of it, so selection is visible on every row
// regardless of whether a highlight rule colours that row.
final class LogRowView: NSTableRowView {
    var ruleBackgroundColor: NSColor = .clear {
        didSet { needsDisplay = true }
    }
    // Redraw whenever the selection state changes
    override var isSelected: Bool {
        didSet { needsDisplay = true }
    }
    // Always treat the row as emphasized so the selection tint stays at full
    // strength even when the table view is not the first responder. Without this
    // AppKit fades/greys the selection once focus moves away after a click.
    override var isEmphasized: Bool {
        get { true }
        set { }
    }
    var isMarked: Bool = false {
        didSet { needsDisplay = true }
    }
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if ruleBackgroundColor != .clear {
            ruleBackgroundColor.setFill()
            dirtyRect.fill()
        }
        if isMarked {
            let diameter: CGFloat = 6.0
            let circleRect = NSRect(x: 4.0, y: (bounds.height - diameter) / 2.0, width: diameter, height: diameter)
            let path = NSBezierPath(ovalIn: circleRect)
            NSColor.systemYellow.setStroke()
            path.lineWidth = 1.5
            path.stroke()
            NSColor(red: 0.0, green: 0.2, blue: 0.7, alpha: 1.0).setFill()
            path.fill()
        }
    }
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        // Faint translucent tint so any rule colour beneath still shows through
        let selectionColor = NSColor.selectedContentBackgroundColor
        selectionColor.withAlphaComponent(0.35).setFill()
        bounds.fill()
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 2.0
        let minX = bounds.minX + 1.0
        let maxX = bounds.maxX - 1.0
        let topY = !isPreviousRowSelected ? bounds.minY + 1.0 : bounds.minY
        let bottomY = !isNextRowSelected ? bounds.maxY - 1.0 : bounds.maxY
        path.move(to: NSPoint(x: minX, y: bottomY))
        path.line(to: NSPoint(x: minX, y: topY))
        if !isPreviousRowSelected {
            path.line(to: NSPoint(x: maxX, y: topY))
        } else {
            path.move(to: NSPoint(x: maxX, y: topY))
        }
        path.line(to: NSPoint(x: maxX, y: bottomY))
        if !isNextRowSelected {
            path.line(to: NSPoint(x: minX, y: bottomY))
        }
        path.stroke()
    }
    func shimmer() {
        self.wantsLayer = true
        let flashLayer = CALayer()
        flashLayer.frame = self.bounds
        flashLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        flashLayer.backgroundColor = NSColor.controlAccentColor.cgColor
        flashLayer.opacity = 0.0
        self.layer?.addSublayer(flashLayer)
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.timingFunction = CAMediaTimingFunction(name: .linear)
        anim.fromValue = 0.0
        anim.toValue = 0.9
        anim.duration = 1.6
        anim.autoreverses = true
        anim.repeatCount = 5
        flashLayer.add(anim, forKey: "shimmer")
        DispatchQueue.main.asyncAfter(deadline: .now() + 16.0) {
            flashLayer.removeFromSuperlayer()
        }
    }
}
