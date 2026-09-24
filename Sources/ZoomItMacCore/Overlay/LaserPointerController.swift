import AppKit

/// Draws a glowing laser-pointer dot, with an optional fading trail, at the
/// mouse pointer. It lives in a transparent, click-through window above every
/// other ZoomIt overlay, so it works over any app as well as during zoom and
/// drawing. The window is shareable, so the dot shows in screen recordings and
/// in screen sharing, but it is excluded from ZoomIt's own zoom captures (see
/// `windowNumberForScreenCaptureExclusion`) so it is never frozen into, or
/// magnified inside, a zoomed image.
@MainActor
final class LaserPointerController {
    private let settingsStore: SettingsStore
    private var window: NSWindow?
    private var pointerView: LaserPointerView?
    private var timer: Timer?
    /// Seconds without mouse movement before the pointer turns itself off, or
    /// nil to stay on until toggled.
    private var idleTimeout: TimeInterval?
    private var lastMouse: CGPoint?
    private var lastMovement: TimeInterval = 0
    private var escapeTap: CFMachPort?
    private var escapeTapSource: CFRunLoopSource?
    private var escapeLocalMonitor: Any?
    /// Input Monitoring is requested at most once per launch.
    private var hasRequestedListenAccess = false
    /// Whether Escape should turn the laser pointer off right now. The owner
    /// returns false while a ZoomIt mode that uses Escape itself (zoom, draw,
    /// snip) is on screen, so Escape exits that mode and the laser stays on.
    var shouldHandleEscape: () -> Bool = { true }

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    var isActive: Bool { window != nil }

    /// Above the zoom/draw overlays (.screenSaver) and above ZoomIt's other
    /// floating windows at .screenSaver + 1 (DemoMirror, the webcam preview,
    /// panorama and recording chrome), which re-order themselves to the front
    /// and would otherwise cover the dot.
    static let windowLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)

    /// Called once the laser window is on screen but still transparent, so a
    /// running live zoom can add it to its capture exclusions (see
    /// `windowNumberForScreenCaptureExclusion`) before the dot is drawn. The dot
    /// becomes visible when the handler returns.
    var prepareToShow: (@MainActor () async -> Void)?

    /// The pointer window's number while active, so ZoomIt's screen captures
    /// can leave the dot out of the source image.
    var windowNumberForScreenCaptureExclusion: Int? {
        window?.windowNumber
    }

    func toggle() {
        if isActive {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard !isActive else { return }
        let settings = settingsStore.load()

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = Self.windowLevel
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.sharingType = .readOnly

        let view = LaserPointerView(
            color: Self.color(rgb: settings.laserPointerColorRGB),
            trailLifetime: TimeInterval(max(0, settings.laserPointerTrailMilliseconds)) / 1000
        )
        idleTimeout = settings.laserPointerIdleMinutes > 0 ? TimeInterval(settings.laserPointerIdleMinutes * 60) : nil
        lastMouse = nil
        window.contentView = view
        self.window = window
        pointerView = view

        tick()
        if let prepareToShow {
            // Order in fully transparent so the window is on screen (and can be
            // excluded from capture) before anything is drawn.
            window.alphaValue = 0
            window.orderFrontRegardless()
            Task { @MainActor [weak self, weak window] in
                await prepareToShow()
                guard let window, self?.window === window else { return }
                window.alphaValue = 1
            }
        } else {
            window.orderFrontRegardless()
        }

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        installEscapeMonitor()
    }

    func stop() {
        removeEscapeMonitor()
        timer?.invalidate()
        timer = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
        pointerView = nil
    }

    /// Escape turns the laser pointer off, like the other ZoomIt tools, without
    /// swallowing the key: the frontmost app (a slide show, a dialog) still
    /// receives it.
    ///
    /// Seeing keys typed into other apps needs a listen-only event tap, which
    /// macOS allows with Input Monitoring permission. (An NSEvent global
    /// monitor would need the broader Accessibility permission instead.)
    /// Without the permission, Escape still works while ZoomIt is frontmost,
    /// and the hotkey and idle auto-off still turn the laser off.
    private func installEscapeMonitor() {
        removeEscapeMonitor()
        if !CGPreflightListenEventAccess(), !hasRequestedListenAccess {
            hasRequestedListenAccess = true
            CGRequestListenEventAccess()
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        if let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<LaserPointerController>.fromOpaque(userInfo).takeUnretainedValue()
                MainActor.assumeIsolated {
                    controller.handleTapEvent(type: type, keyCode: event.getIntegerValueField(.keyboardEventKeycode))
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) {
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            escapeTap = tap
            escapeTapSource = source
        } else {
            escapeLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard event.keyCode == 53 else { return event }
                MainActor.assumeIsolated { self?.handleEscape() }
                return event
            }
        }
    }

    private func handleTapEvent(type: CGEventType, keyCode: Int64) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS disables a tap that stalls; turn it back on.
            if let escapeTap {
                CGEvent.tapEnable(tap: escapeTap, enable: true)
            }
        case .keyDown where keyCode == 53:
            handleEscape()
        default:
            break
        }
    }

    private func removeEscapeMonitor() {
        if let escapeTap {
            CGEvent.tapEnable(tap: escapeTap, enable: false)
            CFMachPortInvalidate(escapeTap)
        }
        if let escapeTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), escapeTapSource, .commonModes)
        }
        escapeTap = nil
        escapeTapSource = nil
        if let escapeLocalMonitor {
            NSEvent.removeMonitor(escapeLocalMonitor)
        }
        escapeLocalMonitor = nil
    }

    private func handleEscape() {
        guard isActive, shouldHandleEscape() else { return }
        stop()
    }

    private func tick() {
        guard let window, let pointerView else { return }
        let mouse = NSEvent.mouseLocation
        let now = ProcessInfo.processInfo.systemUptime

        if mouse != lastMouse {
            lastMouse = mouse
            lastMovement = now
        } else if Self.hasIdledOut(lastMovement: lastMovement, now: now, timeout: idleTimeout) {
            // Forgotten after a talk: turn off rather than leave a dot on screen.
            stop()
            return
        }

        // Follow the pointer across displays: the window covers only the screen
        // the pointer is on, and the trail restarts when it changes screens.
        if !window.frame.contains(mouse),
           let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            window.setFrame(screen.frame, display: false)
            pointerView.resetTrail()
        }

        let local = CGPoint(x: mouse.x - window.frame.minX, y: mouse.y - window.frame.minY)
        pointerView.update(pointer: local, now: now)
    }

    /// Draws the current dot and trail onto a rendered zoom/draw frame for the
    /// recorder, which records ZoomIt's canvas instead of the screen while an
    /// overlay is up and so would otherwise leave the laser out.
    /// `imageScreenFrame` is the screen area the image shows, in AppKit screen
    /// coordinates. Returns nil when the laser isn't on that screen.
    func compositeForRecording(onto image: CGImage, imageScreenFrame: CGRect) -> CGImage? {
        guard let window, let pointerView, window.alphaValue > 0 else { return nil }
        return Self.composite(
            onto: image,
            imageScreenFrame: imageScreenFrame,
            layerScreenFrame: window.frame
        ) { context in
            pointerView.renderContents(in: context)
        }
    }

    /// Draws `drawLayer` (in points, relative to `layerScreenFrame`) over
    /// `image`, which covers `imageScreenFrame` at its own pixel scale.
    static func composite(
        onto image: CGImage,
        imageScreenFrame: CGRect,
        layerScreenFrame: CGRect,
        drawLayer: (CGContext) -> Void
    ) -> CGImage? {
        guard imageScreenFrame.width > 0, layerScreenFrame.intersects(imageScreenFrame),
              let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let scale = CGFloat(image.width) / imageScreenFrame.width
        context.scaleBy(x: scale, y: scale)
        context.translateBy(
            x: layerScreenFrame.minX - imageScreenFrame.minX,
            y: layerScreenFrame.minY - imageScreenFrame.minY
        )
        drawLayer(context)
        return context.makeImage()
    }

    static func color(rgb: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    /// Whether the pointer has been still long enough to turn itself off.
    static func hasIdledOut(lastMovement: TimeInterval, now: TimeInterval, timeout: TimeInterval?) -> Bool {
        guard let timeout else { return false }
        return now - lastMovement >= timeout
    }

    /// Drops trail samples older than `lifetime`. Kept separate so the
    /// self-test can check the trail without a window.
    static func prunedTrail(_ trail: [LaserPointerView.TrailPoint], now: TimeInterval, lifetime: TimeInterval) -> [LaserPointerView.TrailPoint] {
        trail.filter { now - $0.time < lifetime }
    }
}

final class LaserPointerView: NSView {
    struct TrailPoint: Equatable {
        var point: CGPoint
        var time: TimeInterval
    }

    private let color: NSColor
    /// How long a trail sample stays visible, in seconds; 0 draws no trail.
    private let trailLifetime: TimeInterval
    private var showsTrail: Bool { trailLifetime > 0 }
    private var pointer: CGPoint?
    private var trail: [TrailPoint] = []

    /// Radius of the solid dot; the glow extends to about three times this.
    static let dotRadius: CGFloat = 6

    init(color: NSColor, trailLifetime: TimeInterval) {
        self.color = color
        self.trailLifetime = trailLifetime
        super.init(frame: .zero)
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }

    func resetTrail() {
        trail.removeAll()
        pointer = nil
        needsDisplay = true
    }

    func update(pointer newPointer: CGPoint, now: TimeInterval) {
        let moved = newPointer != pointer
        let oldTrail = trail
        if showsTrail {
            if moved {
                trail.append(TrailPoint(point: newPointer, time: now))
            }
            trail = LaserPointerController.prunedTrail(trail, now: now, lifetime: trailLifetime)
        }
        // Redraw only while something changes: the pointer moved or a trail
        // segment faded out. Invalidate both the old and new areas so faded
        // segments are erased.
        guard moved || trail != oldTrail else { return }
        if let pointer {
            setNeedsDisplay(dirtyRect(around: pointer))
        }
        pointer = newPointer
        setNeedsDisplay(dirtyRect(around: newPointer))
        for samples in [oldTrail, trail] {
            if let bounds = Self.bounds(of: samples) {
                setNeedsDisplay(bounds)
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(dirtyRect)
        renderContents(in: context)
    }

    /// Draws the trail and dot in view coordinates. Also used to add the laser
    /// to recorded zoom/draw frames.
    func renderContents(in context: CGContext) {
        if showsTrail, trail.count > 1 {
            drawTrail(in: context)
        }
        if let pointer {
            drawDot(at: pointer, in: context)
        }
    }

    private func drawTrail(in context: CGContext) {
        let newest = trail.last?.time ?? 0
        // Stroke opaque segments inside one translucent layer so the round caps
        // where segments meet don't stack into darker beads.
        context.saveGState()
        context.setAlpha(0.5)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setLineCap(.round)
        context.setStrokeColor(color.cgColor)
        for (previous, current) in zip(trail, trail.dropFirst()) {
            // Older segments taper to a point.
            let age = min(1, (newest - current.time) / trailLifetime)
            context.setLineWidth(max(1, Self.dotRadius * 1.4 * CGFloat(1 - age)))
            context.move(to: previous.point)
            context.addLine(to: current.point)
            context.strokePath()
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    private func drawDot(at point: CGPoint, in context: CGContext) {
        let r = Self.dotRadius
        // Soft glow: concentric circles of decreasing opacity.
        for (scale, alpha) in [(3.0, 0.12), (2.2, 0.22), (1.6, 0.4)] as [(CGFloat, CGFloat)] {
            context.setFillColor(color.withAlphaComponent(alpha).cgColor)
            context.fillEllipse(in: circle(at: point, radius: r * scale))
        }
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: circle(at: point, radius: r))
        // Hot white core, like a real laser spot.
        context.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        context.fillEllipse(in: circle(at: point, radius: r * 0.4))
    }

    private func circle(at point: CGPoint, radius: CGFloat) -> CGRect {
        CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
    }

    private func dirtyRect(around point: CGPoint) -> CGRect {
        circle(at: point, radius: Self.dotRadius * 3 + 2)
    }

    private static func bounds(of samples: [TrailPoint]) -> CGRect? {
        guard let first = samples.first else { return nil }
        var bounds = CGRect(origin: first.point, size: .zero)
        for sample in samples {
            bounds = bounds.union(CGRect(origin: sample.point, size: .zero))
        }
        return bounds.insetBy(dx: -dotRadius * 2, dy: -dotRadius * 2)
    }
}

