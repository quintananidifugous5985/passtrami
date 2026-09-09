import AppKit
import Darwin

// A stopped engine reports a write error instead of terminating the menu app.
signal(SIGPIPE, SIG_IGN)
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
