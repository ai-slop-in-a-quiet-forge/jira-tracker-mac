import AppKit
import ChronoCore

/// Draws the menu bar glyph at runtime.
///
/// No image assets: the icon is a few strokes, and drawing it in code means it is crisp on any
/// display scale, adapts to the state (a dot appears when tracking), and correctly inverts in
/// dark mode and when the menu bar is highlighted — which is what `isTemplate` gives us for free.
enum TrayIcon {

    /// 16pt is the standard menu bar icon size on macOS.
    private static let side: CGFloat = 16

    static func image(for status: TrackingStatus) -> NSImage {
        let showsDot: Bool
        switch status {
        case .idle: showsDot = false
        case .running, .paused: showsDot = true
        }

        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            draw(showsDot: showsDot)
            return true
        }
        // Template images are recoloured by AppKit to match the menu bar, so the icon is
        // legible in light mode, dark mode, and while the item is highlighted.
        image.isTemplate = true
        return image
    }

    private static func draw(showsDot: Bool) {
        let centre = CGPoint(x: side / 2, y: side / 2)
        let radius: CGFloat = 6.0
        let lineWidth: CGFloat = 1.4

        NSColor.black.setStroke()
        NSColor.black.setFill()

        // Clock face.
        let face = NSBezierPath(
            ovalIn: CGRect(
                x: centre.x - radius,
                y: centre.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        )
        face.lineWidth = lineWidth
        face.stroke()

        // Hands, pointing at roughly ten past ten — the angle clock faces are always drawn at,
        // because it reads as a clock at 16 pixels where a vertical hand does not.
        let hands = NSBezierPath()
        hands.lineWidth = lineWidth
        hands.lineCapStyle = .round

        hands.move(to: centre)
        hands.line(to: CGPoint(x: centre.x, y: centre.y + radius * 0.52))   // minute
        hands.move(to: centre)
        hands.line(to: CGPoint(x: centre.x + radius * 0.42, y: centre.y + radius * 0.20)) // hour
        hands.stroke()

        guard showsDot else { return }

        // Punch a transparent gap so the dot stays legible against the ring, then fill it.
        let dotCentre = CGPoint(x: side - 3.4, y: 3.4)
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSBezierPath(ovalIn: CGRect(
            x: dotCentre.x - 3.1, y: dotCentre.y - 3.1, width: 6.2, height: 6.2
        )).fill()

        NSGraphicsContext.current?.compositingOperation = .sourceOver
        NSBezierPath(ovalIn: CGRect(
            x: dotCentre.x - 2.1, y: dotCentre.y - 2.1, width: 4.2, height: 4.2
        )).fill()
    }
}
