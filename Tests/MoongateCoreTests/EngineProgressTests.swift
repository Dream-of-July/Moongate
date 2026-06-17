import XCTest
@testable import MoongateCore

final class EngineProgressTests: XCTestCase {
    func testDownloadProgressDoesNotGoBackwardsAcrossSeparateStreams() {
        let state = YtDlpEngine.DownloadProgressTracker()
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
            }
        }

        XCTAssertEqual(recorder.values, [0, 50, 100, 100, 100, 100])
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Double?) {
        guard let value else { return }
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
