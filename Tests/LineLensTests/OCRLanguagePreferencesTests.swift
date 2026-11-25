import XCTest
@testable import LineLens

final class OCRLanguagePreferencesTests: XCTestCase {
    private actor Loads {
        var calls: [String] = []
        func load(target: String, quality: TranslationQuality) -> [String] {
            calls.append("\(target):\(quality.rawValue)")
            return calls.count == 1 ? ["en"] : ["en", "ja"]
        }
    }

    func testRepeatedFramesReuseInstalledLanguagesAndTargetOrQualityChangesReload() async throws {
        let loads = Loads()
        let preferences = OCRLanguagePreferences { target, quality in
            await loads.load(target: target, quality: quality)
        }
        let first = try await preferences.languages(target: "ko", quality: .speed)
        let nextFrame = try await preferences.languages(target: "ko", quality: .speed)
        XCTAssertEqual(first, ["en"])
        XCTAssertEqual(nextFrame, first)
        _ = try await preferences.languages(target: "ja", quality: .speed)
        _ = try await preferences.languages(target: "ja", quality: .quality)
        let calls = await loads.calls
        XCTAssertEqual(calls, ["ko:speed", "ja:speed", "ja:quality"])
    }

    func testManualRefreshChecksForNewlyInstalledLanguagesWithoutWaitingForExpiry() async throws {
        let loads = Loads()
        let preferences = OCRLanguagePreferences { target, quality in
            await loads.load(target: target, quality: quality)
        }
        _ = try await preferences.languages(target: "ko", quality: .speed)
        let updated = try await preferences.languages(target: "ko", quality: .speed, forceRefresh: true)
        XCTAssertEqual(updated, ["en", "ja"])
        let calls = await loads.calls
        XCTAssertEqual(calls.count, 2)
    }

    func testExpiredSnapshotIsRefreshedOnDemand() async throws {
        let loads = Loads()
        let preferences = OCRLanguagePreferences(cacheLifetime: .zero) { target, quality in
            await loads.load(target: target, quality: quality)
        }
        _ = try await preferences.languages(target: "ko", quality: .speed)
        let updated = try await preferences.languages(target: "ko", quality: .speed)
        XCTAssertEqual(updated, ["en", "ja"])
    }

    func testLoadingIsLazyAndCancelledRequestDoesNotPopulateCache() async throws {
        let loads = Loads()
        let preferences = OCRLanguagePreferences { target, quality in
            let result = await loads.load(target: target, quality: quality)
            if result == ["en"] { throw CancellationError() }
            return result
        }
        let initialCalls = await loads.calls
        XCTAssertTrue(initialCalls.isEmpty)
        do {
            _ = try await preferences.languages(target: "ko", quality: .speed)
            XCTFail("The cancelled load must be propagated")
        } catch is CancellationError { }
        let updated = try await preferences.languages(target: "ko", quality: .speed)
        XCTAssertEqual(updated, ["en", "ja"])
    }
}
