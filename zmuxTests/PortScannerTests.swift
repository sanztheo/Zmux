import XCTest

#if canImport(zmux_DEV)
@testable import zmux_DEV
#elseif canImport(zmux)
@testable import zmux
#endif

final class PortScannerProcessCaptureTests: XCTestCase {
    private func openFDCount() -> Int? {
        try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
    }

    func testCaptureStandardOutputDoesNotLeakPipeFDs() throws {
        guard let baseline = openFDCount() else {
            throw XCTSkip("Unable to inspect /dev/fd on this runner")
        }

        var maxCount = baseline
        for _ in 0..<200 {
            let output = PortScanner.captureStandardOutput(
                executablePath: "/usr/bin/printf",
                arguments: ["zmux"]
            )
            XCTAssertEqual(output, "zmux")
            if let current = openFDCount() {
                maxCount = max(maxCount, current)
            }
        }

        guard let finalCount = openFDCount() else {
            throw XCTSkip("Unable to inspect final /dev/fd count on this runner")
        }

        XCTAssertLessThanOrEqual(maxCount - baseline, 8)
        XCTAssertLessThanOrEqual(finalCount - baseline, 8)
    }
}
