import XCTest
@testable import MoongateCore

final class QueueProgressTests: XCTestCase {
    func testTaskOverallProgressStaysMonotonicWhenPhasePercentFallsBack() throws {
        let plan = QueueProgressPlan(shouldTranscode: true, shouldTranslate: true, shouldBurn: true)

        let afterDownload = try XCTUnwrap(QueueProgressEstimator.taskOverallProgress(
            plan: plan,
            currentPhase: .download,
            phaseProgress: 1.0,
            previousOverallProgress: nil
        ))
        let secondStreamRestart = try XCTUnwrap(QueueProgressEstimator.taskOverallProgress(
            plan: plan,
            currentPhase: .download,
            phaseProgress: 0.05,
            previousOverallProgress: afterDownload
        ))
        let translating = try XCTUnwrap(QueueProgressEstimator.taskOverallProgress(
            plan: plan,
            currentPhase: .translate,
            phaseProgress: 0.10,
            previousOverallProgress: secondStreamRestart
        ))

        XCTAssertEqual(afterDownload, 0.25, accuracy: 0.0001)
        XCTAssertEqual(secondStreamRestart, afterDownload, accuracy: 0.0001)
        XCTAssertGreaterThan(translating, secondStreamRestart)
    }

    func testEtaParsingAndSlopeRemaining() throws {
        XCTAssertEqual(QueueProgressEstimator.parseEtaSeconds("00:45"), 45)
        XCTAssertEqual(QueueProgressEstimator.parseEtaSeconds("01:02:03"), 3723)
        XCTAssertNil(QueueProgressEstimator.parseEtaSeconds("Unknown"))

        let remaining = try XCTUnwrap(QueueProgressEstimator.estimatedRemainingSeconds(
            elapsedSeconds: 10,
            phaseProgress: 0.25,
            sourceEtaSeconds: nil
        ))

        XCTAssertEqual(remaining.seconds, 30, accuracy: 0.0001)
        XCTAssertEqual(remaining.isApproximate, true)
    }

    func testQueueSnapshotAveragesOverallProgressAndUsesLongestKnownRemaining() {
        let snapshot = QueueProgressEstimator.queueSnapshot(items: [
            TaskProgressSnapshot(overallProgress: 0.50, remainingSeconds: 120, isEstimatingRemaining: false, isTerminal: false),
            TaskProgressSnapshot(overallProgress: 0.25, remainingSeconds: 300, isEstimatingRemaining: false, isTerminal: false),
            TaskProgressSnapshot(overallProgress: nil, remainingSeconds: nil, isEstimatingRemaining: true, isTerminal: false),
            TaskProgressSnapshot(overallProgress: 1.0, remainingSeconds: nil, isEstimatingRemaining: false, isTerminal: true),
        ])

        XCTAssertEqual(snapshot.overallProgress, 0.4375, accuracy: 0.0001)
        XCTAssertEqual(snapshot.remainingSeconds, 300)
        XCTAssertTrue(snapshot.isEstimatingRemaining)
    }

    func testQueueSnapshotUsesPhaseMediansForQueuedWork() {
        let plan = QueueProgressPlan(shouldTranscode: false, shouldTranslate: true, shouldBurn: true)
        let snapshot = QueueProgressEstimator.queueSnapshot(
            items: [
                TaskProgressSnapshot(
                    overallProgress: nil,
                    remainingSeconds: nil,
                    isEstimatingRemaining: false,
                    isTerminal: false,
                    plan: plan,
                    currentPhase: nil
                ),
            ],
            phaseMedianDurations: [
                .download: 60,
                .translate: 120,
                .burn: 180,
            ],
            phaseCapacities: [
                .download: 2,
                .translate: 1,
                .burn: 1,
            ]
        )

        XCTAssertEqual(try XCTUnwrap(snapshot.remainingSeconds), 360, accuracy: 0.0001)
        XCTAssertFalse(snapshot.isEstimatingRemaining)
    }

    func testQueueSnapshotStaysEstimatingWhenQueuedWorkLacksSamples() {
        let plan = QueueProgressPlan(shouldTranscode: false, shouldTranslate: true, shouldBurn: true)
        let snapshot = QueueProgressEstimator.queueSnapshot(
            items: [
                TaskProgressSnapshot(
                    overallProgress: nil,
                    remainingSeconds: nil,
                    isEstimatingRemaining: false,
                    isTerminal: false,
                    plan: plan,
                    currentPhase: nil
                ),
            ],
            phaseMedianDurations: [
                .download: 60,
            ],
            phaseCapacities: [
                .download: 2,
                .translate: 1,
                .burn: 1,
            ]
        )

        XCTAssertNil(snapshot.remainingSeconds)
        XCTAssertTrue(snapshot.isEstimatingRemaining)
    }
}
