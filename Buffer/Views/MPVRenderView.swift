import SwiftUI
import Cocoa
import OpenGL.GL
import OpenGL.GL3
import Libmpv

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
        MPVLayerHostView(player: player)
    }

    @available(macOS, deprecated: 10.14)
    func updateNSView(_ nsView: MPVLayerHostView, context: Context) {}

    @available(macOS, deprecated: 10.14)
    static func dismantleNSView(_ nsView: MPVLayerHostView, coordinator: ()) {
        nsView.teardown()
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
/// callback marks the layer dirty on the main thread whenever a new
/// frame is ready; `draw(inCGLContext:)` does the actual render.
///
/// Resize is automatic: each `draw` call queries `GL_VIEWPORT` from the
/// layer's CoreAnimation-managed FBO, so the render target is always the
/// correct pixel size for the current layer bounds.
@available(macOS, deprecated: 10.14)
final class MPVPlayerLayer: CAOpenGLLayer {
    private var player: MPVPlayer?
    private var ownedCGL: CGLContextObj?
    private var renderReady = false
    private var callbackBoxPtr: UnsafeMutableRawPointer?
    private var torn = false
    /// Coalesces update-callback dispatches so only one
    /// `setNeedsDisplay()` is queued on the main thread at a time.
    nonisolated(unsafe) private var displayScheduled = false

    private class CallbackBox {
        weak var layer: MPVPlayerLayer?
        init(layer: MPVPlayerLayer) { self.layer = layer }
    }

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
        setNeedsDisplay()
    }

    func teardown() {
        guard !torn else { return }
        torn = true
        renderReady = false

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

        var swap: GLint = 0
        CGLSetParameter(ctx, kCGLCPSwapInterval, &swap)

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

        let box = Unmanaged.passRetained(CallbackBox(layer: self))
        let ptr = box.toOpaque()
        callbackBoxPtr = ptr

        player.setRenderUpdateCallback({ ctx in
            guard let ctx else { return }
            let box = Unmanaged<CallbackBox>.fromOpaque(ctx).takeUnretainedValue()
            guard let layer = box.layer, !layer.displayScheduled else { return }
            layer.displayScheduled = true
            DispatchQueue.main.async { [weak layer] in
                guard let layer else { return }
                guard !layer.torn else {
                    layer.displayScheduled = false
                    return
                }
                // Let Core Animation coalesce multiple mpv frame callbacks
                // into one draw pass instead of forcing an immediate redraw
                // on every callback.
                layer.setNeedsDisplay()
            }
        }, context: ptr)
    }

    // MARK: - Drawing

    @available(macOS, deprecated: 10.14)
    override func canDraw(
        inCGLContext ctx: CGLContextObj,
        pixelFormat pf: CGLPixelFormatObj,
        forLayerTime t: CFTimeInterval,
        displayTime ts: UnsafePointer<CVTimeStamp>?
    ) -> Bool {
        return renderReady && !torn
    }

    @available(macOS, deprecated: 10.14)
    override func draw(
        inCGLContext ctx: CGLContextObj,
        pixelFormat pf: CGLPixelFormatObj,
        forLayerTime t: CFTimeInterval,
        displayTime ts: UnsafePointer<CVTimeStamp>?
    ) {
        displayScheduled = false

        guard renderReady, !torn, let renderCtx = player?.renderContextHandle else {
            glClearColor(0, 0, 0, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
            return
        }

        CGLSetCurrentContext(ctx)

        // Query the FBO + viewport that CoreAnimation set up for this layer.
        // This auto-tracks the layer's current pixel dimensions — no manual
        // drawableSize management, no swapchain recreation, no crashes on
        // resize.
        var fbo: GLint = 0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &fbo)

        var dims: [GLint] = [0, 0, 0, 0]
        glGetIntegerv(GLenum(GL_VIEWPORT), &dims)
        let w = dims[2]
        let h = dims[3]
        guard w > 0, h > 0 else { return }

        _ = mpv_render_context_update(renderCtx)

        var fboParam = mpv_opengl_fbo(fbo: fbo, w: w, h: h, internal_format: 0)
        var flip: Int32 = 1
        var blockForTargetTime: Int32 = 0
        withUnsafeMutablePointer(to: &fboParam) { fboPtr in
            withUnsafeMutablePointer(to: &flip) { flipPtr in
                withUnsafeMutablePointer(to: &blockForTargetTime) { blockPtr in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fboPtr)),
                        mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPtr)),
                        mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: UnsafeMutableRawPointer(blockPtr)),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                    ]
                    mpv_render_context_render(renderCtx, &params)
                }
            }
        }

        glFlush()
        mpv_render_context_report_swap(renderCtx)
    }
}
