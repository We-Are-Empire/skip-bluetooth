// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
import XCTest
import Foundation
@testable import SkipBluetooth

final class ScanStartGateTests: XCTestCase {
    /// A caller that asks for the scan after every failed connect asks for it far more than five
    /// times in 30 s. Only the first request may start Android's scanner.
    func testARepeatedRequestForTheRunningScanStartsNothing() {
        var gate = ScanStartGate()
        XCTAssertEqual(gate.request(filter: ["291D567A-6D75-11E6-8B77-86F30CA893D3"]), ScanStartDecision.start)
        for _ in 0..<10 {
            XCTAssertEqual(gate.request(filter: ["291d567a-6d75-11e6-8b77-86f30ca893d3"]), ScanStartDecision.keepRunning,
                           "the same filter, however it is spelled, is the scan already running")
        }
    }

    func testADifferentFilterRestartsTheScan() {
        var gate = ScanStartGate()
        XCTAssertEqual(gate.request(filter: ["A", "B"]), ScanStartDecision.start)
        XCTAssertEqual(gate.request(filter: ["B", "A"]), ScanStartDecision.keepRunning, "order does not change the filter")
        XCTAssertEqual(gate.request(filter: ["C"]), ScanStartDecision.restart)
        XCTAssertEqual(gate.request(filter: ["C"]), ScanStartDecision.keepRunning)
    }

    /// A stop, a failed scan and a radio power-off all end the scan, so the next request starts one.
    func testTheNextRequestAfterTheScanEndsStartsIt() {
        var gate = ScanStartGate()
        XCTAssertEqual(gate.request(filter: []), ScanStartDecision.start)
        gate.scanEnded()
        XCTAssertEqual(gate.request(filter: []), ScanStartDecision.start)
        XCTAssertEqual(gate.request(filter: []), ScanStartDecision.keepRunning)
    }
}
