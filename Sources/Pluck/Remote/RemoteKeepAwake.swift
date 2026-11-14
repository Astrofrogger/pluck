import Foundation
import IOKit.pwr_mgt

/// Keeps the host Mac from idle sleep (an IOPMAssertion, the standard API) while it serves file
/// pieces, makes proxies or renders for paired Macs; lets it sleep again as soon as none is going on.
/// The display may still sleep.
@MainActor
enum RemoteKeepAwake {
    private static var assertion: IOPMAssertionID?
    private static var lastTransfer = Date.distantPast
    private static var watcher: Task<Void, Never>?

    /// A file piece was asked for: transfers count as busy for a minute and a half after the last one.
    static func transferred() {
        lastTransfer = .now
        update()
    }

    static func start() {
        guard watcher == nil else { return }
        watcher = Task {
            while !Task.isCancelled {
                update()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    static var busy: Bool {
        OfficeRenderServer.shared.isRunning
            && (OfficeRenderServer.shared.isRendering || OfficeProxies.shared.working != nil || RemoteProxyJobs.shared.working != nil
                || Date.now.timeIntervalSince(lastTransfer) < 90)
    }

    static var isHolding: Bool { assertion != nil }

    static func update() {
        if busy, assertion == nil {
            var id = IOPMAssertionID(0)
            let reason = "Pluck Edit Anywhere is serving a paired Mac" as CFString
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           reason, &id) == kIOReturnSuccess {
                assertion = id
            }
        } else if !busy, let id = assertion {
            IOPMAssertionRelease(id)
            assertion = nil
        }
    }
}
