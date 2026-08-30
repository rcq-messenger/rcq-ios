import Foundation
import os

/// Measures main-thread stalls and says them out loud.
///
/// Born from the 30.08 "фризит 3-5 секунд после входа" hunt: the freeze
/// reproduced only on a large real account, our instruments live on the
/// server, and a phone in the founder's hand has neither. This is the
/// missing gauge: a utility-queue heartbeat posts a block to the main queue
/// every 200ms and measures how long the block waited. A wait is EXACTLY
/// the stall a finger feels, whatever caused it, with no signposts to
/// remember to add. Stalls land in the unified log (`subsystem app.rcq,
/// category stall`), so `log stream` or a sysdiagnose from any tester turns
/// a "it freezes" report into a number with a timestamp.
///
/// Cost when healthy: one no-op main-queue block per 200ms, unmeasurable.
/// Deliberately NOT a Task on the main actor: the cooperative pool would
/// yield around a busy actor and under-report the very thing this exists
/// to see; the main DISPATCH QUEUE is where the frames live.
enum MainThreadWatchdog {
    private static let log = Logger(subsystem: "app.rcq", category: "stall")
    private static let queue = DispatchQueue(label: "rcq.watchdog", qos: .utility)
    private static var started = false

    /// Above this, a wait is a stall worth a log line. Half a second is two
    /// missed animation beats: below it nobody files a report, above it
    /// everybody does.
    private static let thresholdMs = 500

    static func start() {
        guard !started else { return }
        started = true
        queue.async { beat() }
    }

    private static func beat() {
        let sent = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.main.async {
            let waitedMs = Int(Double(DispatchTime.now().uptimeNanoseconds - sent) / 1e6)
            if waitedMs > thresholdMs {
                log.error("main thread stalled ~\(waitedMs, privacy: .public)ms")
                print("[stall] main thread blocked ~\(waitedMs)ms")
            }
            queue.asyncAfter(deadline: .now() + 0.2) { beat() }
        }
    }
}
