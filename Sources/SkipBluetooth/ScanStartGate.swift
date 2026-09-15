// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
#if !SKIP_BRIDGE
import Foundation

/// What a scan request asks of Android's LE scanner.
enum ScanStartDecision: Equatable {
    /// No scan is running: start one.
    case start
    /// A scan with the same filter is already running: leave it alone.
    case keepRunning
    /// A scan with a different filter is running: stop it, then start the new one.
    case restart
}

/// Decides whether a `scanForPeripherals` call starts Android's scanner.
///
/// CoreBluetooth takes a repeated `scanForPeripherals` in its stride, and callers written against
/// it ask again freely — the camera library re-asks after every failed connect. Android counts each
/// `startScan` against a limit of five starts per 30 s per app and answers a sixth with an empty
/// scan for the rest of the window, so a request for the scan that is already running must not
/// start it again. The gate holds only what the central told it: a start, a stop, a failed scan,
/// or the radio leaving the powered-on state (which ends any scan without a callback).
struct ScanStartGate {
    private var isRunning = false
    private var runningFilter: [String] = []

    /// The decision for a request with this filter, recorded as the scan now running.
    /// `filter` names the service and solicitation UUIDs; its order does not matter.
    mutating func request(filter: [String]) -> ScanStartDecision {
        let normalised = filter.map { $0.uppercased() }.sorted()
        let decision: ScanStartDecision
        if !isRunning {
            decision = .start
        } else if normalised == runningFilter {
            decision = .keepRunning
        } else {
            decision = .restart
        }
        isRunning = true
        runningFilter = normalised
        return decision
    }

    /// The scan ended: stopped by the caller, failed, or cut by the radio powering off.
    mutating func scanEnded() {
        isRunning = false
        runningFilter = []
    }
}
#endif
