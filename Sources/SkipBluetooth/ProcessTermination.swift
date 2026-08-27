// SPDX-License-Identifier: LGPL-3.0-only WITH LGPL-3.0-linking-exception
#if !SKIP_BRIDGE
import Foundation

#if SKIP
import android.bluetooth.__

/// Releases every open GATT connection when the process ends.
///
/// CoreBluetooth gives this for free: a link belongs to the app process, and
/// when that process goes away — cleanly or by crash — iOS tears the link
/// down. Android's GATT client lives in `com.android.bluetooth`, so a link
/// outlives the app that opened it whenever the stack's binder-death cleanup
/// does not fire, and the next launch finds the camera already connected to a
/// client it has no handle for.
///
/// Closing the connections ourselves at the two exits we can observe — an
/// orderly VM shutdown, and an uncaught exception — restores the iOS
/// behaviour. A `SIGKILL` (force-stop, low-memory kill, swipe from Recents on
/// most builds) runs no user code at all; there the stack's own cleanup is the
/// only backstop, on Android as on iOS.
internal final class ProcessTerminationCleanup {
    static let shared = ProcessTerminationCleanup()

    private let lock = NSLock()
    private var centrals: [WeakCentralBox] = []
    private var installed = false

    private init() { }

    /// Starts observing process exit, and adds `central` to what gets closed.
    /// Idempotent: every `CBCentralManager` calls this from its initializer.
    func register(_ central: CBCentralManager) {
        lock.lock()
        centrals.append(WeakCentralBox(central))
        let needsInstall = !installed
        installed = true
        lock.unlock()

        guard needsInstall else { return }
        java.lang.Runtime.getRuntime().addShutdownHook(GattCleanupThread())
        java.lang.Thread.setDefaultUncaughtExceptionHandler(
            GattCleanupExceptionHandler(
                previous: java.lang.Thread.getDefaultUncaughtExceptionHandler()))
    }

    func unregister(_ central: CBCentralManager) {
        lock.lock(); defer { lock.unlock() }
        centrals = centrals.filter { $0.central !== central && $0.central != nil }
    }

    /// Disconnects and closes every GATT this process holds.
    ///
    /// Runs on the shutdown-hook thread or on whichever thread threw, never on
    /// the main actor — `clearConnectedDevice` is lock-guarded and touches only
    /// Android objects, so that is safe. Delegate callbacks that the closes
    /// provoke are dropped: the pipeline that would deliver them is a main-actor
    /// task, and the main thread is on its way out.
    func closeAllConnections(reason: String) {
        lock.lock()
        let live = centrals.compactMap { $0.central }
        lock.unlock()

        guard !live.isEmpty else { return }
        logger.log("ProcessTerminationCleanup: closing GATT connections (\(reason))")
        for central in live {
            central.clearConnectedDevice()
        }
    }
}

private final class WeakCentralBox {
    weak var central: CBCentralManager?
    init(_ central: CBCentralManager) {
        self.central = central
    }
}

private final class GattCleanupThread: java.lang.Thread {
    init() {
        super.init()
    }

    override func run() {
        ProcessTerminationCleanup.shared.closeAllConnections(reason: "VM shutdown")
    }
}

/// Chains rather than replaces: the previous handler is what actually reports
/// the crash and kills the process, and swallowing it would turn a crash into
/// a hang.
private final class GattCleanupExceptionHandler: java.lang.Thread.UncaughtExceptionHandler {
    private let previous: java.lang.Thread.UncaughtExceptionHandler?

    init(previous: java.lang.Thread.UncaughtExceptionHandler?) {
        self.previous = previous
    }

    override func uncaughtException(t: java.lang.Thread, e: kotlin.Throwable) {
        ProcessTerminationCleanup.shared.closeAllConnections(reason: "uncaught exception")
        previous?.uncaughtException(t, e)
    }
}

#endif
#endif
