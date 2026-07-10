import Cocoa

extension NSImage {
    /// Returns a copy filled with `color`, preserving the alpha channel.
    /// Used to draw template-style logo marks in the menu bar foreground color.
    func tinted(with color: NSColor) -> NSImage {
        let result = NSImage(size: size)
        result.lockFocus()
        let rect = NSRect(origin: .zero, size: size)
        draw(in: rect)
        color.set()
        rect.fill(using: .sourceAtop)
        result.unlockFocus()
        result.isTemplate = false
        return result
    }
}
