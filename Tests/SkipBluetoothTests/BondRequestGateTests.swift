// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
import XCTest
import Foundation
@testable import SkipBluetooth

final class BondRequestGateTests: XCTestCase {
    /// The Pixel on 2026-09-21 (HW1): the encrypted write answered with the pairing prompt and
    /// the stack started nothing — no dialog, no broadcast. This is the case the gate exists for.
    func testAnUnbondedDeviceAsksForTheBond() {
        XCTAssertEqual(BondRequestGate.onPark(bondState: BondRequestGate.bondNone),
                       BondRequestDecision.requestBond)
    }

    /// The stack's own implicit pairing got there first. Asking again would be a second dialog.
    func testADeviceAlreadyBondingIsWaitedFor() {
        XCTAssertEqual(BondRequestGate.onPark(bondState: BondRequestGate.bondBonding),
                       BondRequestDecision.park)
    }

    /// Fast "Just Works" bonding can complete between the callback thread reading the status and
    /// the main actor acting on it. The held operations then have their answer.
    func testADeviceBondedByTheTimeWeLookIsReplayed() {
        XCTAssertEqual(BondRequestGate.onPark(bondState: BondRequestGate.bondBonded),
                       BondRequestDecision.replay)
    }

    /// A state Android does not name is not a reason to declare a failure.
    func testAnUnknownBondStateIsWaitedFor() {
        XCTAssertEqual(BondRequestGate.onPark(bondState: -1), BondRequestDecision.park)
    }

    func testATrueReturnIsWaitedFor() {
        XCTAssertEqual(BondRequestGate.afterRequest(started: true, bondState: BondRequestGate.bondNone),
                       BondRequestDecision.park)
    }

    /// `createBond()` answers false while a bond is already in flight, so the state decides.
    func testAFalseReturnWhileBondingIsWaitedFor() {
        XCTAssertEqual(BondRequestGate.afterRequest(started: false, bondState: BondRequestGate.bondBonding),
                       BondRequestDecision.park)
    }

    /// It also answers false when the bond already exists.
    func testAFalseReturnWhenAlreadyBondedIsReplayed() {
        XCTAssertEqual(BondRequestGate.afterRequest(started: false, bondState: BondRequestGate.bondBonded),
                       BondRequestDecision.replay)
    }

    /// The one shape that means no bond is coming: refused, and nothing started.
    func testAFalseReturnWithNoBondFails() {
        XCTAssertEqual(BondRequestGate.afterRequest(started: false, bondState: BondRequestGate.bondNone),
                       BondRequestDecision.fail)
    }

    /// The window is for a bond that never started. Once `BOND_BONDING` has been seen the user is
    /// at a PIN prompt, which takes as long as it takes.
    func testTheWindowDoesNotCutAPromptShort() {
        XCTAssertEqual(BondRequestGate.onCheck(bondingSeen: true, bondState: BondRequestGate.bondNone),
                       BondRequestDecision.park)
    }

    /// A broadcast this process missed still leaves the state to read.
    func testTheWindowDoesNotFireWhileBonding() {
        XCTAssertEqual(BondRequestGate.onCheck(bondingSeen: false, bondState: BondRequestGate.bondBonding),
                       BondRequestDecision.park)
    }

    func testTheWindowReplaysWhenTheBondLanded() {
        XCTAssertEqual(BondRequestGate.onCheck(bondingSeen: false, bondState: BondRequestGate.bondBonded),
                       BondRequestDecision.replay)
    }

    /// Ten seconds on, nothing bonding and nothing bonded: the operation is told, rather than
    /// waiting out the 37 minutes the Pixel waited.
    func testTheWindowFailsWhenNoBondEverStarted() {
        XCTAssertEqual(BondRequestGate.onCheck(bondingSeen: false, bondState: BondRequestGate.bondNone),
                       BondRequestDecision.fail)
    }

    func testTheWindowIsTenSeconds() {
        // 10.0, not 10: transpiled, an Int literal compares unequal to a Double.
        XCTAssertEqual(BondRequestGate.bondStartTimeoutSeconds, 10.0)
    }

    /// The gate's literals are Android's `BluetoothDevice.BOND_*` values, and the bond broadcasts
    /// are classified against the same numbers.
    func testTheBondStatesMatchTheBroadcastClassifier() {
        XCTAssertEqual(BondRequestGate.bondNone, BondBroadcastClassifier.bondNone)
        XCTAssertEqual(BondRequestGate.bondBonding, BondBroadcastClassifier.bondBonding)
        XCTAssertEqual(BondRequestGate.bondBonded, BondBroadcastClassifier.bondBonded)
    }
}
