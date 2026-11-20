import Foundation
import Testing
@testable import CompositorPro

@Suite("Parsed LUT cache budget")
struct LUTLoaderCacheTests {
    private func cube(dimension: Int) -> LUTLoader.CubeLUT {
        let count = dimension * dimension * dimension
        var rgba = [Float](repeating: 0, count: count * 4)
        for index in 0..<count {
            rgba[index * 4] = 0.5
            rgba[index * 4 + 3] = 1
        }
        return LUTLoader.CubeLUT(dimension: dimension, data: Data(rgba.map { UInt8($0 * 255) }))
    }

    @Test func evictionKeepsRetainedBytesInsideTheBudget() {
        let previousLimit = LUTLoader.cacheByteLimit
        defer {
            LUTLoader.cacheByteLimit = previousLimit
            LUTLoader.releaseCachedLUTs()
        }
        LUTLoader.releaseCachedLUTs()

        let entryBytes = 64 * 4
        LUTLoader.cacheByteLimit = entryBytes * 2

        let first = cube(dimension: 4)
        let second = cube(dimension: 4)
        let third = cube(dimension: 4)
        LUTLoader.cache(first, path: "/tmp/lut-budget-1.cube")
        LUTLoader.cache(second, path: "/tmp/lut-budget-2.cube")
        #expect(LUTLoader.cachedByteCount <= LUTLoader.cacheByteLimit)

        // A third entry evicts the least recently used one rather than growing the cache.
        LUTLoader.cache(third, path: "/tmp/lut-budget-3.cube")
        #expect(LUTLoader.cachedByteCount <= LUTLoader.cacheByteLimit)
        #expect(LUTLoader.cachedByteCount > 0)
    }

    @Test func releaseDropsEveryRetainedLUT() {
        let previousLimit = LUTLoader.cacheByteLimit
        defer {
            LUTLoader.cacheByteLimit = previousLimit
            LUTLoader.releaseCachedLUTs()
        }
        LUTLoader.releaseCachedLUTs()
        LUTLoader.cache(cube(dimension: 4), path: "/tmp/lut-release.cube")
        #expect(LUTLoader.cachedByteCount > 0)

        LUTLoader.releaseCachedLUTs()
        #expect(LUTLoader.cachedByteCount == 0)
    }
}
