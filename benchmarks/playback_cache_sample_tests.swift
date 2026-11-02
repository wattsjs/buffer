import Foundation

@main enum PlaybackCacheSampleTests {
    static func main() {
        var checks = 0
        func check(_ condition: Bool, _ message: String) { checks += 1; precondition(condition, message) }
        var cache = PlaybackCacheSample()
        check(cache.currentSeconds(generation: 1, at: 0) == nil, "no cache observation must remain unknown")
        cache.observe(0, generation: 1, at: 10)
        check(cache.currentSeconds(generation: 1, at: 10) == 0, "valid current zero must retain underrun meaning")
        check(cache.currentSeconds(generation: 2, at: 10) == nil, "previous load cannot supply cache control")
        check(cache.currentSeconds(generation: 1, at: 9) == nil, "backward monotonic timestamp cannot produce freshness")
        check(cache.currentSeconds(generation: 1, at: 12.5) == 0, "sample is current through the bounded deadline")
        check(cache.currentSeconds(generation: 1, at: 12.50001) == nil, "expired low cache cannot trigger timer pause")
        for invalid in [Double?.none, .some(-1), .some(.nan), .some(.infinity), .some(-.infinity)] {
            cache.observe(0.6, generation: 3, at: 20)
            check(cache.currentSeconds(generation: 3, at: 20.1) == 0.6, "valid low reserve observation missing")
            cache.observe(invalid, generation: 3, at: 20.1)
            check(cache.currentSeconds(generation: 3, at: 20.2) == nil,
                "invalid/unavailable observation must retire an earlier low sample immediately")
        }
        cache.observe(1.19, generation: 4, at: 30)
        check(cache.currentSeconds(generation: 4, at: 30.1) == 1.19,
            "control uses actual reserve above the floor even if rounded UI retained a lower value")
        cache.observe(4, generation: 4, at: .nan)
        check(cache.currentSeconds(generation: 4, at: 30.2) == nil, "invalid timestamp cannot retain a previous sample")
        cache.observe(2, generation: 5, at: 40)
        check(cache.currentSeconds(generation: 5, at: .infinity) == nil, "invalid current clock cannot prove freshness")
        cache.reset()
        check(cache.currentSeconds(generation: 5, at: 40) == nil, "reuse must clear exact cache control")
        print("PASS \(checks) precise cache control checks")
    }
}
