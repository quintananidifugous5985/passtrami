import AppKit

extension NSWindow.StyleMask {
    // Private macOS 27 glass style; no public SDK name is available.
    @available(macOS 27.0, *)
    static let passtramiGlass = NSWindow.StyleMask(rawValue: UInt(1) << 36)
}
