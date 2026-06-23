import XCTest
@testable import MoongateCore

final class EngineProgressTests: XCTestCase {
    func testDownloadProgressAggregatesSeparateMediaStreams() {
        let state = YtDlpEngine.DownloadProgressTracker(expectedMediaDownloads: 2)
        let recorder = ProgressRecorder()

        for line in [
            "MGP| 0.0%| 1MiB/s|00:10",
            "MGP| 50.0%| 1MiB/s|00:05",
            "MGP|100.0%| 1MiB/s|00:00",
            "MGP| 0.0%| 500KiB/s|00:03",
            "MGP| 30.0%| 500KiB/s|00:02",
            "MGP|100.0%| 500KiB/s|00:00",
        ] {
            YtDlpEngine.handleOutputLine(line, state: state) { update in
                recorder.append(update.percent)
                recorder.appendETA(update.etaText)
            }
        }

        XCTAssertEqual(recorder.values.count, 6)
        zip(recorder.values, [0, 25, 50, 50, 65, 98]).forEach { actual, expected in
            XCTAssertEqual(actual, expected, accuracy: 0.0001)
        }
        XCTAssertEqual(recorder.etaValues, [nil, nil, nil, nil, nil, nil])
    }

    func testExpectedMediaDownloadCountClassifiesKnownSelectors() {
        let exact4K = YtDlpEngine.videoTierFormatSelector(height: 2160)
        let hdr4K = YtDlpEngine.applyHDRPreference(to: exact4K, preferHDR: true)

        XCTAssertEqual(YtDlpEngine.expectedMediaDownloadCount(for: exact4K), 2)
        XCTAssertEqual(YtDlpEngine.expectedMediaDownloadCount(for: hdr4K), 2)
        XCTAssertEqual(YtDlpEngine.expectedMediaDownloadCount(for: "ba[ext=m4a]/ba/best"), 1)
        XCTAssertEqual(YtDlpEngine.expectedMediaDownloadCount(for: "best"), 1)
        XCTAssertEqual(YtDlpEngine.expectedMediaDownloadCount(for: "b[dynamic_range=HDR10+]/best"), 1)
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    private var etaStorage: [String?] = []

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var etaValues: [String?] {
        lock.lock()
        defer { lock.unlock() }
        return etaStorage
    }

    func append(_ value: Double?) {
        guard let value else { return }
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    func appendETA(_ value: String?) {
        lock.lock()
        etaStorage.append(value)
        lock.unlock()
    }
}
