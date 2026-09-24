import CoreGraphics
import Foundation

/// Hides the system mouse pointer while the laser pointer is on, so the dot
/// isn't drawn on top of an arrow.
///
/// macOS ignores cursor hiding from an app that isn't frontmost, and the laser
/// pointer must not take focus from the app being presented. The WindowServer
/// connection property `SetsCursorInBackground` lifts that restriction. It is
/// private API, so it is looked up at run time and compiled out of the App
/// Store build, where the arrow simply stays visible. The hide count belongs to
/// ZoomIt's WindowServer connection, so if ZoomIt quits or crashes macOS shows
/// the cursor again on its own.
///
/// Switching apps (Cmd-Tab, clicking another app, Mission Control) resets the
/// hide, so the laser pointer calls `reassertIfNeeded()` on every frame to hide
/// the cursor again as soon as it reappears.
@MainActor
final class LaserPointerCursorHider {
    private var isHidden = false

    /// Whether this build and macOS version can hide the cursor in the
    /// background.
    static var isSupported: Bool {
        #if ZOOMIT_APP_STORE
        false
        #else
        BackgroundCursorSPI.shared != nil
        #endif
    }

    func hide() {
        #if !ZOOMIT_APP_STORE
        guard !isHidden, let spi = BackgroundCursorSPI.shared else { return }
        spi.setsCursorInBackground(true)
        CGDisplayHideCursor(CGMainDisplayID())
        isHidden = true
        #endif
    }

    /// Hides the cursor again if something, such as an app switch, has shown
    /// it while the laser pointer is on.
    func reassertIfNeeded() {
        #if !ZOOMIT_APP_STORE
        guard isHidden, let spi = BackgroundCursorSPI.shared, spi.isCursorVisible() else { return }
        spi.setsCursorInBackground(true)
        // The app switch already cleared the hide, so show-then-hide keeps
        // ZoomIt's hide/show calls balanced whatever state it left behind.
        CGDisplayShowCursor(CGMainDisplayID())
        CGDisplayHideCursor(CGMainDisplayID())
        #endif
    }

    func show() {
        #if !ZOOMIT_APP_STORE
        guard isHidden, let spi = BackgroundCursorSPI.shared else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        spi.setsCursorInBackground(false)
        isHidden = false
        #endif
    }
}

#if !ZOOMIT_APP_STORE
private struct BackgroundCursorSPI {
    private typealias MainConnectionFunction = @convention(c) () -> Int32
    private typealias SetConnectionPropertyFunction = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    private typealias CursorIsVisibleFunction = @convention(c) () -> Int32

    private let mainConnection: MainConnectionFunction
    private let setConnectionProperty: SetConnectionPropertyFunction
    private let cursorIsVisible: CursorIsVisibleFunction

    /// nil when the private functions can't be found (for example, if a future
    /// macOS removes them); the laser pointer then leaves the arrow visible.
    static let shared: BackgroundCursorSPI? = {
        let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let main = dlsym(handle, "_CGSDefaultConnection") ?? dlsym(handle, "CGSMainConnectionID"),
              let set = dlsym(handle, "CGSSetConnectionProperty"),
              // Still exported, but marked unavailable to Swift callers.
              let visible = dlsym(handle, "CGCursorIsVisible") else {
            return nil
        }
        return BackgroundCursorSPI(
            mainConnection: unsafeBitCast(main, to: MainConnectionFunction.self),
            setConnectionProperty: unsafeBitCast(set, to: SetConnectionPropertyFunction.self),
            cursorIsVisible: unsafeBitCast(visible, to: CursorIsVisibleFunction.self)
        )
    }()

    func isCursorVisible() -> Bool {
        cursorIsVisible() != 0
    }

    func setsCursorInBackground(_ enabled: Bool) {
        let connection = mainConnection()
        _ = setConnectionProperty(
            connection,
            connection,
            "SetsCursorInBackground" as CFString,
            (enabled ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef
        )
    }
}
#endif
