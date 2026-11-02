import SwiftUI
import Cocoa
import OpenGL.GL
import OpenGL.GL3
import Libmpv
import OSLog

// MARK: - CAOpenGLLayer render view (IINA pattern)
//
// Each slot gets its own CAOpenGLLayer backed by its own CGL context.
// This is the same architecture IINA uses (ViewLayer.swift). It avoids
// every issue the NSOpenGLView and MoltenVK/Vulkan/CAMetalLayer paths
// hit:
//
// - No drawable invalidation from sibling views (CAOpenGLLayer is a
//   proper CALayer; siblings compose cleanly through Core Animation).
// - No swapchain to recreate on resize (macOS manages the layer's
//   backing FBO; draw() queries GL_FRAMEBUFFER_BINDING + GL_VIEWPORT
//   each frame, so it always renders at the correct size).
// - No MoltenVK context_moltenvk.m resize bug.
// - No dispatch-queue re-entry asserts.
//
// Tradeoff: OpenGL is deprecated on macOS (but still fully functional
// on Apple Silicon and will be for the foreseeable future).

struct MPVLayerView: NSViewRepresentable {
    let player: MPVPlayer

    @available(macOS, deprecated: 10.14)
    func makeNSView(context: Context) -> MPVLayerHostView {
        if let reusable = MPVLayerHostReuseRegistry.shared.takeHost(for: player) {
            AppLog.playback.info("mpv layer host reused for player")
            return reusable
        }
        let host = MPVLayerHostView(player: player)
        MPVLayerHostReuseRegistry.shared.register(host, for: player)
        AppLog.playback.info("mpv layer host created for player")
        return host
    }

    @available(macOS, deprecated: 10.14)
    func updateNSView(_ nsView: MPVLayerHostView, context: Context) {}

    @available(macOS, deprecated: 10.14)
    static func dismantleNSView(_ nsView: MPVLayerHostView, coordinator: ()) {
        if MPVLayerHostReuseRegistry.shared.consumeTransfer(for: nsView) {
            return
        }
        MPVLayerHostReuseRegistry.shared.unregister(nsView)
        nsView.teardown()
    }
}

@available(macOS, deprecated: 10.14)
private final class MPVLayerHostReuseRegistry {
    static let shared = MPVLayerHostReuseRegistry()

    private var hostsByPlayer: [ObjectIdentifier: MPVLayerHostView] = [:]
    private var transferredHosts: Set<ObjectIdentifier> = []

    private init() {}

    func register(_ host: MPVLayerHostView, for player: MPVPlayer) {
        hostsByPlayer[ObjectIdentifier(player)] = host
    }

    func takeHost(for player: MPVPlayer) -> MPVLayerHostView? {
        let playerID = ObjectIdentifier(player)
        guard let host = hostsByPlayer.removeValue(forKey: playerID) else { return nil }
        transferredHosts.insert(ObjectIdentifier(host))
        return host
    }

    func consumeTransfer(for host: MPVLayerHostView) -> Bool {
        transferredHosts.remove(ObjectIdentifier(host)) != nil
    }

    func unregister(_ host: MPVLayerHostView) {
        let hostID = ObjectIdentifier(host)
        hostsByPlayer = hostsByPlayer.filter { ObjectIdentifier($0.value) != hostID }
        transferredHosts.remove(hostID)
    }
}

/// NSView whose backing layer is an `MPVPlayerLayer`.
@available(macOS, deprecated: 10.14)
final class MPVLayerHostView: NSView {
    private var playerLayer: MPVPlayerLayer? { layer as? MPVPlayerLayer }

    init(player: MPVPlayer) {
        super.init(frame: .zero)
        wantsLayer = true
        playerLayer?.attach(player: player)
    }

    required init?(coder: NSCoder) { fatalError() }

    @available(macOS, deprecated: 10.14)
    override func makeBackingLayer() -> CALayer {
        return MPVPlayerLayer()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let scale = window?.backingScaleFactor {
            playerLayer?.contentsScale = scale
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor {
            playerLayer?.contentsScale = scale
        }
    }

    func teardown() {
        playerLayer?.teardown()
    }
}

/// CAOpenGLLayer that renders one MPVPlayer instance.
///
/// Each layer owns its own CGL context (via `copyCGLContext`). The mpv
/// render context is initialized against this CGL context the first time
/// CoreAnimation calls `copyCGLContext`. After that, the mpv update
/// callback renders on the layer's own queue whenever a new frame is
/// ready, independent of the main thread; `draw(inCGLContext:)` does the
/// actual render.
///
/// Resize is automatic: each `draw` call queries `GL_VIEWPORT` from the
/// layer's CoreAnimation-managed FBO, so the render target is always the
/// correct pixel size for the current layer bounds.
///
/// Performance tuning:
/// - kCGLCEMPEngine (multi-threaded GL) is enabled for Apple Silicon GPU
///   parallelism. This lets the GL driver distribute work across GPU cores
///   instead of serializing through a single command stream.
/// - CGL context locking protects setup/teardown, and `MPVRenderTarget`
///   keeps the mpv context alive for any render in flight. Frame updates
///   from mpv are coalesced with a lock before dispatching to the render queue.
/// - Advanced render control is enabled: mpv reports frame timing info
///   and we call report_swap() after each present for accurate A/V sync.
@available(macOS, deprecated: 10.14)
final class MPVPlayerLayer: CAOpenGLLayer {
    private var player: MPVPlayer?
    private var ownedCGL: CGLContextObj?
    private var renderReady = false
    private var callbackBoxPtr: UnsafeMutableRawPointer?
    private var torn = false

    /// mpv's update callback renders straight onto `renderQueue`, so a busy
    /// main thread (guide loads, Smart Channels rebuilds) cannot delay or
    /// drop video frames. Mirrors IINA's mpvGLQueue: display() runs on the
    /// queue and CATransaction.flush() publishes the new contents.
    private nonisolated final class CallbackBox: @unchecked Sendable {
        let gate = RenderInvalidationGate()
        let renderQueue = DispatchQueue(label: "com.wattsjs.buffer.mpv-render", qos: .userInteractive)
        let target: MPVRenderTarget
        weak var layer: CALayer?
        init(layer: CALayer, target: MPVRenderTarget) {
            self.layer = layer
            self.target = target
        }

        func render() {
            gate.complete()
            guard let layer, target.hasContext else { return }
            // Background multi-view thumbnails have video disabled; skip the
            // GL path entirely rather than waking it for 8 tiny layers.
            if target.isBackgroundSuspended, layer.bounds.height < 140 { return }
            layer.display()
            CATransaction.flush()
        }
    }

    // Drawing state, read on whichever thread CoreAnimation draws on.
    // Attach/teardown write it on main under `drawLock`; teardown clears the
    // target so a retired layer can never draw a later context of its player.
    private let drawLock = NSLock()
    nonisolated(unsafe) private var attachedTarget: MPVRenderTarget?
    nonisolated(unsafe) private weak var attachedOwner: MPVPlayer?
    nonisolated private var renderTarget: MPVRenderTarget? { drawLock.withLock { attachedTarget } }
    nonisolated private var renderOwner: MPVPlayer? { drawLock.withLock { attachedOwner } }
    // Only touched inside draw, which CoreAnimation serializes with the CGL
    // context lock: spacing between decoded frames, for cadence/jitter.
    nonisolated(unsafe) private var lastDecodedFrameAt: ContinuousClock.Instant?

    override init() {
        super.init()
        isAsynchronous = false
        isOpaque = true
        backgroundColor = CGColor(gray: 0, alpha: 1)
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError() }

    func attach(player: MPVPlayer) {
        self.player = player
        drawLock.withLock {
            attachedTarget = player.renderTarget
            attachedOwner = player
        }
        setNeedsDisplay()
    }

    func teardown() {
        guard !torn else { return }
        torn = true
        renderReady = false
        drawLock.withLock {
            attachedTarget = nil
            attachedOwner = nil
        }

        if let ctx = player?.renderContextHandle {
            mpv_render_context_set_update_callback(ctx, nil, nil)
        }

        if let ptr = callbackBoxPtr {
            Unmanaged<CallbackBox>.fromOpaque(ptr).release()
            callbackBoxPtr = nil
        }

        // Free the render context while the CGL context is still alive.
        if let cgl = ownedCGL {
            CGLLockContext(cgl)
            CGLSetCurrentContext(cgl)
            player?.resetRenderContext()
            CGLUnlockContext(cgl)
        } else {
            player?.resetRenderContext()
        }

        player = nil
    }

    // MARK: - CGL context lifecycle

    @available(macOS, deprecated: 10.14)
    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        let attrs: [CGLPixelFormatAttribute] = [
            kCGLPFADoubleBuffer,
            kCGLPFAAccelerated,
            kCGLPFAOpenGLProfile,
            CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
            kCGLPFAColorSize, CGLPixelFormatAttribute(24),
            kCGLPFAAlphaSize, CGLPixelFormatAttribute(8),
            kCGLPFADepthSize, CGLPixelFormatAttribute(0),
            kCGLPFAStencilSize, CGLPixelFormatAttribute(0),
            kCGLPFAAllowOfflineRenderers,
            kCGLPFASupportsAutomaticGraphicsSwitching,
            CGLPixelFormatAttribute(0),
        ]
        var pf: CGLPixelFormatObj?
        var n: GLint = 0
        CGLChoosePixelFormat(attrs, &pf, &n)
        return pf ?? super.copyCGLPixelFormat(forDisplayMask: mask)
    }

    @available(macOS, deprecated: 10.14)
    override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj {
        var ctx: CGLContextObj?
        CGLCreateContext(pf, nil, &ctx)
        guard let ctx else {
            return super.copyCGLContext(forPixelFormat: pf)
        }
        ownedCGL = ctx

        // Disable vsync — CAOpenGLLayer drives frame pacing via its own
        // CVDisplayLink. A non-zero swap interval would add a second
        // layer of blocking and cause missed vsync deadlines.
        var swap: GLint = 0
        CGLSetParameter(ctx, kCGLCPSwapInterval, &swap)

        // Multi-threaded GL engine. On Apple Silicon this lets the GPU driver
        // distribute command processing across multiple hardware queues,
        // reducing serialization bottlenecks in the GL→Metal translation layer.
        CGLEnable(ctx, kCGLCEMPEngine)

        bindMPVRenderContext(cgl: ctx)
        return ctx
    }

    private func bindMPVRenderContext(cgl: CGLContextObj) {
        guard let player, !renderReady else { return }

        CGLLockContext(cgl)
        CGLSetCurrentContext(cgl)

        player.resetRenderContext()
        let ok = player.initRenderContext { _, name in
            guard let name else { return nil }
            let sym = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingASCII)
            guard let fw = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString) else { return nil }
            return CFBundleGetFunctionPointerForName(fw, sym)
        }

        CGLUnlockContext(cgl)

        guard ok else { return }
        renderReady = true

        let box = Unmanaged.passRetained(CallbackBox(layer: self, target: player.renderTarget))
        let ptr = box.toOpaque()
        callbackBoxPtr = ptr

        player.setRenderUpdateCallback({ ctx in
            guard let ctx else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(ctx).takeUnretainedValue()
            guard box.gate.schedule() else { return }
            box.renderQueue.async { box.render() }
        }, context: ptr)
        player.nudgeVideoOutputAfterRenderContextAttach()
    }

    // MARK: - Drawing

    @available(macOS, deprecated: 10.14)
    nonisolated override func canDraw(
        inCGLContext ctx: CGLContextObj,
        pixelFormat pf: CGLPixelFormatObj,
        forLayerTime t: CFTimeInterval,
        displayTime ts: UnsafePointer<CVTimeStamp>?
    ) -> Bool {
        guard let target = renderTarget, target.hasContext else { return false }
        // Extra guard: never draw for disabled bg thumbnails even if a
        // stale setNeedsDisplay sneaks through during rapid layout changes.
        return !(target.isBackgroundSuspended && bounds.height < 140)
    }

    @available(macOS, deprecated: 10.14)
    nonisolated override func draw(
        inCGLContext ctx: CGLContextObj,
        pixelFormat pf: CGLPixelFormatObj,
        forLayerTime t: CFTimeInterval,
        displayTime ts: UnsafePointer<CVTimeStamp>?
    ) {
        func clear() {
            glClearColor(0, 0, 0, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        }
        // Thumbnail guard (defense-in-depth for layout-change races / pooled reuse).
        guard let target = renderTarget, !(target.isBackgroundSuspended && bounds.height < 140) else {
            clear()
            return
        }

        CGLSetCurrentContext(ctx)
        // Query the FBO + viewport that CoreAnimation set up for this layer.
        // This auto-tracks the layer's current pixel dimensions.
        var fbo: GLint = 0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &fbo)

        var dims: [GLint] = [0, 0, 0, 0]
        glGetIntegerv(GLenum(GL_VIEWPORT), &dims)
        let w = dims[2]
        let h = dims[3]
        guard w > 0, h > 0 else { return }

        // Core Animation may replace the backing framebuffer on resize or
        // request an existing frame again after uncovering this layer. Every
        // draw must fill that target, including while playback is paused.
        // mpv redraws its retained picture when update() has no new frame;
        // SKIP_RENDERING would ignore the framebuffer and leave it blank.
        // Keep the update flag for decoded-frame telemetry so these display
        // redraws never count as playback progress or another first frame.
        // The item identity is read with the context, before rendering, so a
        // queued old frame is never labelled as a newer request whose
        // FILE_LOADED event has not arrived. Holding the target's lock for
        // the whole render keeps teardown from freeing the context mid-frame.
        let renderStarted = ContinuousClock.now
        let result = target.withContext { renderCtx, itemIdentity, block -> (hasFrame: Bool, identity: MPVItemLifecycle.Identity?) in
            let flags = mpv_render_context_update(renderCtx)
            let hasFrame = (flags & 1) != 0  // MPV_RENDER_UPDATE_FRAME

            var fboParam = mpv_opengl_fbo(fbo: fbo, w: w, h: h, internal_format: 0)
            var flip: Int32 = 1
            var depth: Int32 = 8
            var blockForTargetTime = block

            withUnsafeMutablePointer(to: &fboParam) { fboPtr in
                withUnsafeMutablePointer(to: &flip) { flipPtr in
                    withUnsafeMutablePointer(to: &depth) { depthPtr in
                        withUnsafeMutablePointer(to: &blockForTargetTime) { timingPtr in
                            var params = [
                                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fboPtr)),
                                mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPtr)),
                                mpv_render_param(type: MPV_RENDER_PARAM_DEPTH, data: UnsafeMutableRawPointer(depthPtr)),
                                mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: UnsafeMutableRawPointer(timingPtr)),
                                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                            ]
                            mpv_render_context_render(renderCtx, &params)
                        }
                    }
                }
            }
            glFlush()
            mpv_render_context_report_swap(renderCtx)
            return (hasFrame, itemIdentity)
        }
        guard let result else {
            clear()
            return
        }

        let renderMs = PerfMetrics.milliseconds(since: renderStarted)
        if result.hasFrame {
            PerfMetrics.shared.record("render.mpv.frameRenderMs", renderMs)
            PerfMetrics.shared.increment("render.mpv.decodedFrames")
            if let lastDecodedFrameAt {
                let interval = PerfMetrics.milliseconds(since: lastDecodedFrameAt, now: renderStarted)
                // Ignore pauses; keep only steady-state cadence.
                if interval < 500 { PerfMetrics.shared.record("render.mpv.frameIntervalMs", interval) }
            }
            lastDecodedFrameAt = renderStarted
        } else {
            PerfMetrics.shared.increment("render.mpv.redraws")
        }
        if result.hasFrame, let itemIdentity = result.identity {
            let frameWidth = Int(w)
            let frameHeight = Int(h)
            let renderedAt = ContinuousClock.now
            let owner = renderOwner
            Task { @MainActor [weak owner] in
                owner?.noteRenderedFrame(width: frameWidth, height: frameHeight, identity: itemIdentity, renderedAt: renderedAt)
            }
        }
    }
}
