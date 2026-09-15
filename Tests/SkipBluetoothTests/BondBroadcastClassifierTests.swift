// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
import XCTest
import Foundation
@testable import SkipBluetooth

final class BondBroadcastClassifierTests: XCTestCase {
    /// The Pixel on 2026-09-15 (install 13): the phone kept its bond with a BMPCC4K that had lost
    /// the keys, and the stack broadcast key-missing with the device still bonded.
    func testKeyMissingOnABondedDeviceIsABondLoss() {
        XCTAssertEqual(BondBroadcastClassifier.classify(action: BondBroadcastClassifier.actionKeyMissing,
                                                        bondState: BondBroadcastClassifier.bondBonded,
                                                        previousBondState: -1),
                       BondBroadcastOutcome.bondLost)
    }

    /// With no bond on the phone there is nothing to forget: the next connect pairs afresh.
    func testKeyMissingWithoutABondIsIgnored() {
        XCTAssertEqual(BondBroadcastClassifier.classify(action: BondBroadcastClassifier.actionKeyMissing,
                                                        bondState: BondBroadcastClassifier.bondNone,
                                                        previousBondState: -1),
                       BondBroadcastOutcome.ignored)
    }

    /// A user dismissing the PIN prompt: bonding, then no bond. That is a cancel, never a bond loss.
    func testBondingThenNoBondIsACancel() {
        XCTAssertEqual(BondBroadcastClassifier.classify(action: BondBroadcastClassifier.actionBondStateChanged,
                                                        bondState: BondBroadcastClassifier.bondNone,
                                                        previousBondState: BondBroadcastClassifier.bondBonding),
                       BondBroadcastOutcome.pairingCancelled)
    }

    func testBondedThenNoBondIsAnUnbond() {
        XCTAssertEqual(BondBroadcastClassifier.classify(action: BondBroadcastClassifier.actionBondStateChanged,
                                                        bondState: BondBroadcastClassifier.bondNone,
                                                        previousBondState: BondBroadcastClassifier.bondBonded),
                       BondBroadcastOutcome.unbonded)
    }

    func testBondStateChangesToBondingAndBonded() {
        XCTAssertEqual(BondBroadcastClassifier.classify(action: BondBroadcastClassifier.actionBondStateChanged,
                                                        bondState: BondBroadcastClassifier.bondBonding,
                                                        previousBondState: BondBroadcastClassifier.bondNone),
                       BondBroadcastOutcome.bonding)
        XCTAssertEqual(BondBroadcastClassifier.classify(action: BondBroadcastClassifier.actionBondStateChanged,
                                                        bondState: BondBroadcastClassifier.bondBonded,
                                                        previousBondState: BondBroadcastClassifier.bondBonding),
                       BondBroadcastOutcome.bonded)
    }

    func testOtherActionsAreIgnored() {
        XCTAssertEqual(BondBroadcastClassifier.classify(action: "android.bluetooth.device.action.ACL_DISCONNECTED",
                                                        bondState: BondBroadcastClassifier.bondBonded,
                                                        previousBondState: -1),
                       BondBroadcastOutcome.ignored)
        XCTAssertEqual(BondBroadcastClassifier.classify(action: nil,
                                                        bondState: BondBroadcastClassifier.bondBonded,
                                                        previousBondState: -1),
                       BondBroadcastOutcome.ignored)
    }
}
