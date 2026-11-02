import Foundation
import Libmpv

/// Render-thread view of one player's mpv render context.
///
/// Video frames are drawn on a dedicated render queue so main-thread work
/// (guide loads, Smart Channels rebuilds, sync merges) cannot delay them.
/// The player still owns the context's lifetime on the main actor; this box
/// only publishes what drawing needs and serializes free against an
/// in-flight render, so teardown can never free a context mid-frame.
nonisolated final class MPVRenderTarget: @unchecked Sendable {
    private let lock = NSLock()
    private var context: OpaquePointer?
    private var backgroundSuspended = false
    private var itemIdentity: MPVItemLifecycle.Identity?
    private var blockForTargetTime: Int32 = 1

    var hasContext: Bool { lock.withLock { context != nil } }
    var isBackgroundSuspended: Bool { lock.withLock { backgroundSuspended } }

    /// `blockForTargetTime` is MPVRenderTiming's value, read on the main
    /// actor when the context is created.
    func install(_ ctx: OpaquePointer, blockForTargetTime block: Int32) {
        lock.withLock {
            context = ctx
            blockForTargetTime = block
        }
    }

    /// Waits for any render in progress, then detaches and frees the context.
    func free() {
        lock.withLock {
            guard let ctx = context else { return }
            context = nil
            mpv_render_context_set_update_callback(ctx, nil, nil)
            mpv_render_context_free(ctx)
        }
    }

    func update(backgroundSuspended value: Bool) {
        lock.withLock { backgroundSuspended = value }
    }

    func update(itemIdentity value: MPVItemLifecycle.Identity?) {
        lock.withLock { itemIdentity = value }
    }

    /// Runs `body` with the live context and the item it currently belongs
    /// to, holding the lock so the context stays valid for the whole render.
    func withContext<T>(_ body: (OpaquePointer, MPVItemLifecycle.Identity?, Int32) -> T) -> T? {
        lock.withLock {
            guard let context else { return nil }
            return body(context, itemIdentity, blockForTargetTime)
        }
    }
}
