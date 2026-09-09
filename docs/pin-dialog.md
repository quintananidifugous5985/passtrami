# PIN dialog reference

Inspected the native arm64e binaries on macOS 27 build 26A5425a in Hopper on 2026-09-09. Passtrami recreates the layout with its own SwiftUI content and PIN field.

## System implementation

- `coreautha`, `-[LAAuthDialogView initWithStyle:]`: calls `LACUIAuthenticationDialogInit()` and embeds its view.
- `LocalAuthenticationCoreUI`, `LACUIAuthenticationDialogInit`, `0x25fef59c4`: selects `LACUIAuthenticationDialogViewController` when the SwiftUI dialog feature is enabled.
- `LACUIAuthenticationDialogViewController.loadView` (use the named symbol in Hopper): hosts `LACUIAuthenticationDialogView` in `NSHostingViewSuppressingSafeArea`.
- `LACUIAuthenticationDialogViewSheetMetrics.init`, `0x25ff20370`: defines the small dialog's layout. A fresh, empty controller's view model confirmed these values at runtime:

| Property | Value |
| --- | --- |
| Width | 260 pt |
| Section spacing | 16 pt |
| Text inset / spacing | 8 pt / 4 pt |
| Title / body font | headline / body |
| Main icon | 45 pt |
| Icon top / bottom spacing | 8 pt / 16 pt |
| Badge size / offset | 0.53 × main icon / (7, 0) pt |

`coreautha`'s `-[LAAuthWindow initWithContentRect:styleMask:backing:defer:]` at `0x100001348` removes the resizable bit and adds `0x200008001`: titled, full-size content, and private style bit 33. It sets `titlebarAppearsTransparent`, `titlebarHidden`, and `titleVisibility`, makes the window nonopaque, and hides the window buttons. Passtrami uses this setup with a nonactivating panel. The system draws the rounded window surface.

## Passtrami changes

The main icon is resolved with the Passwords bundle ID (`com.apple.Passwords`) through `NSWorkspace`. The badge comes from `NSApp.applicationIconImage`. Both are loaded each time the PIN window opens.

A centered monospaced text field replaces the positive action. Its container is 28 pt high, the same as the Cancel button. Auto Layout centers the field at its natural text height inside a white rounded border. This avoids the system bezel's gray fill and extra text insets on macOS 27. It has no focus ring. It accepts six ASCII digits and submits once on digit six. While checking, the field is disabled and the code and instructions stay visible. Return with an incomplete code calls `NSWindow._shake` and keeps the entered digits. A rejection from the engine clears the field, replaces the instruction, restores focus, and uses the same shake. Dismissal clears the field. Cancel and Escape use the existing lock callback.

The layout was compared with a temporary local instance of Apple's dialog view. That reference did not start authentication or access credentials. The build target remains macOS 26.2; the live UI check used macOS 27.
