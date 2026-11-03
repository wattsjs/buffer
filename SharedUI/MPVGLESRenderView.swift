import Libmpv
import OpenGLES
import OSLog
import SwiftUI
import UIKit

// MARK: - CAEAGLLayer render view (iOS / iPadOS / tvOS)
//
// The Mac draws through CAOpenGLLayer, which UIKit does not have. Here each
// player gets a CAEAGLLayer-backed view with its own EAGLContext and one
// colour renderbuffer. The mpv render API is used exactly as on the Mac:
// MPVPlayer creates the OpenGL render context, `MPVRenderTarget` publishes it
// to the render queue, and mpv's update callback renders straight onto a
// dedicated queue so a busy main thread never delays or drops frames.
//
// OpenGL ES is what MPVKit's libmpv supports for the render API on these
// platforms (its Vulkan path needs mpv to own the window). GLES cannot show
// 10-bit output (mpv#7846); VideoToolbox still decodes HEVC Main10.

struct MPVLayerView: UIViewRepresentable {
    let player: MPVPlayer

    func makeUIView(context: Context) -> MPVGLESHostView {
        AppLog.playback.info("mpv GLES host created for player")
        return MPVGLESHostView(player: player)
    }

    func updateUIView(_ uiView: MPVGLESHostView, context: Context) {}

    static func dismantleUIView(_ uiView: MPVGLESHostView, coordinator: ()) {
        uiView.teardown()
    }
}

/// UIView whose backing layer is a CAEAGLLayer that one MPVPlayer renders into.
final class MPVGLESHostView: UIView {
    override class var layerClass: AnyClass { CAEAGLLayer.self }

    private var player: MPVPlayer?
    private var renderer: MPVGLESRenderer?
    private var callbackBoxPtr: UnsafeMutableRawPointer?
    private var lastPixelSize: CGSize = .zero
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var torn = false

    init(player: MPVPlayer) {
        self.player = player
        super.init(frame: .zero)
        backgroundColor = .black
        isOpaque = true
        let glLayer = layer as! CAEAGLLayer
        glLayer.isOpaque = true
        glLayer.drawableProperties = [
            kEAGLDrawablePropertyRetainedBacking: false,
            kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8,
        ]
        observeApplicationState()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let window else { return }
        contentScaleFactor = window.screen.nativeScale
        layer.contentsScale = window.screen.nativeScale
        attachIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = layer.contentsScale
        let pixels = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        guard pixels != lastPixelSize else { return }
        lastPixelSize = pixels
        // The renderbuffer is reallocated from the layer on the render
        // queue; redraw immediately so a paused picture follows the resize.
        renderer?.prepareDrawable()
        renderer?.requestRender()
    }

    private func attachIfNeeded() {
        guard renderer == nil, !torn, let player else { return }
        guard let context = EAGLContext(api: .openGLES3) ?? EAGLContext(api: .openGLES2) else {
            AppLog.playback.error("EAGLContext creation failed")
            return
        }
        let renderer = MPVGLESRenderer(context: context, layer: layer as! CAEAGLLayer,
                                       target: player.renderTarget, owner: player)
        EAGLContext.setCurrent(context)
        player.resetRenderContext()
        let ok = player.initRenderContext { _, name in
            guard let name else { return nil }
            let symbol = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingASCII)
            guard let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengles" as CFString) else { return nil }
            return CFBundleGetFunctionPointerForName(bundle, symbol)
        }
        EAGLContext.setCurrent(nil)
        guard ok else { return }
        self.renderer = renderer
        renderer.update(suspended: UIApplication.shared.applicationState == .background)
        if bounds.width > 0, bounds.height > 0 { renderer.prepareDrawable() }

        let box = Unmanaged.passRetained(renderer)
        let pointer = box.toOpaque()
        callbackBoxPtr = pointer
        player.setRenderUpdateCallback({ ctx in
            guard let ctx else { return }
            Unmanaged<MPVGLESRenderer>.fromOpaque(ctx).takeUnretainedValue().requestRender()
        }, context: pointer)
        player.nudgeVideoOutputAfterRenderContextAttach()
        renderer.requestRender()
    }

    /// GL work is forbidden while the app is in the background on iOS.
    private func observeApplicationState() {
        let center = NotificationCenter.default
        lifecycleObservers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderer?.update(suspended: true) }
        })
        lifecycleObservers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.renderer?.update(suspended: false)
                self?.renderer?.requestRender()
            }
        })
    }

    func teardown() {
        guard !torn else { return }
        torn = true
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        lifecycleObservers.removeAll()
        if let ctx = player?.renderContextHandle {
            mpv_render_context_set_update_callback(ctx, nil, nil)
        }
        if let renderer {
            // Waits for an in-flight frame, then frees the mpv context and
            // GL objects with the EAGL context current.
            renderer.retire()
            renderer.withCurrentContext {
                player?.resetRenderContext()
                renderer.deleteDrawable()
            }
        } else {
            player?.resetRenderContext()
        }
        if let pointer = callbackBoxPtr {
            Unmanaged<MPVGLESRenderer>.fromOpaque(pointer).release()
            callbackBoxPtr = nil
        }
        renderer = nil
        player = nil
    }
}

/// Render-queue half of the GLES host. Frames are drawn on `renderQueue`.
/// Binding the renderbuffer to the layer touches the layer, which UIKit
/// allows only on the main thread, so that (and teardown) runs on main;
/// `glLock` keeps the EAGL context current on one thread at a time.
nonisolated final class MPVGLESRenderer: @unchecked Sendable {
    let context: EAGLContext
    private let layer: CAEAGLLayer
    private let target: MPVRenderTarget
    private weak var owner: MPVPlayer?
    private let gate = RenderInvalidationGate()
    private let renderQueue = DispatchQueue(label: "com.wattsjs.buffer.mpv-render", qos: .userInteractive)

    private let stateLock = NSLock()
    private let glLock = NSLock()
    private var suspended = false
    private var retired = false
    private var drawableValid = false

    // Render-queue state.
    private var framebuffer: GLuint = 0
    private var colorbuffer: GLuint = 0
    private var pixelWidth: GLint = 0
    private var pixelHeight: GLint = 0
    private var lastDecodedFrameAt: ContinuousClock.Instant?

    init(context: EAGLContext, layer: CAEAGLLayer, target: MPVRenderTarget, owner: MPVPlayer) {
        self.context = context
        self.layer = layer
        self.target = target
        self.owner = owner
    }

    func update(suspended value: Bool) {
        stateLock.withLock { suspended = value }
        if value { withCurrentContext { glFinish() } }
    }

    /// Main thread: (re)binds the colour renderbuffer to the layer's size.
    func prepareDrawable() {
        withCurrentContext { _ = allocateDrawable() }
    }

    /// Runs `body` with the EAGL context current, excluding the render queue.
    func withCurrentContext(_ body: () -> Void) {
        glLock.withLock {
            guard EAGLContext.setCurrent(context) else { return }
            body()
            EAGLContext.setCurrent(nil)
        }
    }

    /// Coalesced: at most one render is queued at a time.
    func requestRender() {
        guard gate.schedule() else { return }
        renderQueue.async { [self] in render() }
    }

    func retire() {
        stateLock.withLock { retired = true }
        renderQueue.sync {}
    }

    /// Called on main after `retire()`, with `context` current.
    func deleteDrawable() {
        if framebuffer != 0 { glDeleteFramebuffers(1, &framebuffer); framebuffer = 0 }
        if colorbuffer != 0 { glDeleteRenderbuffers(1, &colorbuffer); colorbuffer = 0 }
    }

    private func render() {
        gate.complete()
        let (isSuspended, isRetired, valid) = stateLock.withLock { (suspended, retired, drawableValid) }
        guard !isSuspended, !isRetired, target.hasContext else { return }
        guard valid, framebuffer != 0 else {
            DispatchQueue.main.async { [self] in
                prepareDrawable()
                requestRender()
            }
            return
        }
        glLock.lock()
        defer { glLock.unlock() }
        guard EAGLContext.setCurrent(context) else { return }
        defer { EAGLContext.setCurrent(nil) }

        guard pixelWidth > 0, pixelHeight > 0 else { return }
        if target.isBackgroundSuspended, pixelHeight < 140 { return }

        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        glViewport(0, 0, pixelWidth, pixelHeight)
        let width = pixelWidth, height = pixelHeight, fbo = GLint(framebuffer)
        let renderStarted = ContinuousClock.now
        let result = target.withContext { renderCtx, itemIdentity, block -> (hasFrame: Bool, identity: MPVItemLifecycle.Identity?) in
            let flags = mpv_render_context_update(renderCtx)
            let hasFrame = (flags & 1) != 0  // MPV_RENDER_UPDATE_FRAME
            var fboParam = mpv_opengl_fbo(fbo: fbo, w: width, h: height, internal_format: 0)
            var flip: Int32 = 1
            var blockForTargetTime = block
            withUnsafeMutablePointer(to: &fboParam) { fboPtr in
                withUnsafeMutablePointer(to: &flip) { flipPtr in
                    withUnsafeMutablePointer(to: &blockForTargetTime) { timingPtr in
                        var params = [
                            mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fboPtr)),
                            mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPtr)),
                            mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: UnsafeMutableRawPointer(timingPtr)),
                            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                        ]
                        mpv_render_context_render(renderCtx, &params)
                    }
                }
            }
            glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorbuffer)
            context.presentRenderbuffer(Int(GL_RENDERBUFFER))
            mpv_render_context_report_swap(renderCtx)
            return (hasFrame, itemIdentity)
        }
        guard let result else { return }

        let renderMs = PerfMetrics.milliseconds(since: renderStarted)
        if result.hasFrame {
            PerfMetrics.shared.record("render.mpv.frameRenderMs", renderMs)
            PerfMetrics.shared.increment("render.mpv.decodedFrames")
            if let lastDecodedFrameAt {
                let interval = PerfMetrics.milliseconds(since: lastDecodedFrameAt, now: renderStarted)
                if interval < 500 { PerfMetrics.shared.record("render.mpv.frameIntervalMs", interval) }
            }
            lastDecodedFrameAt = renderStarted
        } else {
            PerfMetrics.shared.increment("render.mpv.redraws")
        }
        if result.hasFrame, let itemIdentity = result.identity {
            let frameWidth = Int(width), frameHeight = Int(height)
            let renderedAt = ContinuousClock.now
            let owner = owner
            Task { @MainActor [weak owner] in
                owner?.noteRenderedFrame(width: frameWidth, height: frameHeight, identity: itemIdentity, renderedAt: renderedAt)
            }
        }
    }

    /// (Re)binds the colour renderbuffer to the layer's current drawable.
    private func allocateDrawable() -> Bool {
        if framebuffer == 0 { glGenFramebuffers(1, &framebuffer) }
        if colorbuffer == 0 { glGenRenderbuffers(1, &colorbuffer) }
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), framebuffer)
        glBindRenderbuffer(GLenum(GL_RENDERBUFFER), colorbuffer)
        guard context.renderbufferStorage(Int(GL_RENDERBUFFER), from: layer) else {
            AppLog.playback.error("mpv GLES renderbuffer storage failed bounds=\(String(describing: self.layer.bounds), privacy: .public)")
            return false
        }
        glFramebufferRenderbuffer(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_RENDERBUFFER), colorbuffer)
        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_WIDTH), &pixelWidth)
        glGetRenderbufferParameteriv(GLenum(GL_RENDERBUFFER), GLenum(GL_RENDERBUFFER_HEIGHT), &pixelHeight)
        let complete = glCheckFramebufferStatus(GLenum(GL_FRAMEBUFFER)) == GLenum(GL_FRAMEBUFFER_COMPLETE)
        AppLog.playback.info("mpv GLES drawable width=\(self.pixelWidth, privacy: .public) height=\(self.pixelHeight, privacy: .public) complete=\(complete, privacy: .public)")
        stateLock.withLock { drawableValid = complete }
        return complete
    }
}
