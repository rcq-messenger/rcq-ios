import Darwin
import Foundation
import os

/// Measures main-thread stalls, says them out loud - and names the culprit.
///
/// Born from the 30.08 "фризит 3-5 секунд после входа" hunt: the freeze
/// reproduced only on a large real account, our instruments live on the
/// server, and a phone in the founder's hand has neither. A utility-queue
/// heartbeat posts a block to the main queue every 200ms and measures how
/// long the block waited - a wait is EXACTLY the stall a finger feels.
///
/// Round two (31.08): the duration alone said "5590ms" and left us
/// guessing. So when a beat is 700ms overdue, the watchdog SUSPENDS the
/// main thread for a moment, walks its frame-pointer chain, resumes it,
/// and logs the symbolicated stack alongside the duration when the beat
/// finally lands. Suspension rules that keep this safe:
///   - raw addresses are collected while suspended; `dladdr` runs only
///     AFTER resume (it can take the dyld lock, and the main thread may be
///     suspended holding it);
///   - frames are read with `vm_read_overwrite`, so a torn frame pointer
///     ends the walk instead of crashing the process;
///   - one capture per stall, capped depth, PAC bits stripped by mask.
///
/// Cost when healthy: one no-op main-queue block per 200ms, unmeasurable.
/// Deliberately NOT a Task on the main actor: the cooperative pool would
/// yield around a busy actor and under-report the very thing this exists
/// to see; the main DISPATCH QUEUE is where the frames live.
enum MainThreadWatchdog {
    private static let log = Logger(subsystem: "app.rcq", category: "stall")
    private static let queue = DispatchQueue(label: "rcq.watchdog", qos: .utility)
    private static var started = false
    /// The main thread's mach port, captured on `start()` (which runs on
    /// main). `mach_thread_self` takes a ref; kept for the process lifetime.
    private static var mainThread: thread_act_t = 0

    /// Above this, a wait is a stall worth a log line. Half a second is two
    /// missed animation beats: below it nobody files a report, above it
    /// everybody does.
    private static let thresholdMs = 500
    /// How overdue a beat must be before the stack capture fires. Slightly
    /// above the log threshold so the capture lands mid-stall, not at its
    /// tail.
    private static let captureAfter: DispatchTimeInterval = .milliseconds(700)

    static func start() {
        guard !started else { return }
        started = true
        mainThread = mach_thread_self()
        queue.async { beat() }
    }

    private final class BeatState {
        var landed = false
        var stack: [UInt] = []
    }

    private static func beat() {
        let sent = DispatchTime.now().uptimeNanoseconds
        let state = BeatState()
        // Mid-stall probe: if the beat has not landed by then, the main
        // thread is stuck RIGHT NOW - photograph it.
        queue.asyncAfter(deadline: .now() + captureAfter) {
            guard !state.landed, mainThread != 0 else { return }
            state.stack = captureStack(of: mainThread)
        }
        DispatchQueue.main.async {
            let waitedMs = Int(Double(DispatchTime.now().uptimeNanoseconds - sent) / 1e6)
            queue.async {
                state.landed = true
                if waitedMs > thresholdMs {
                    let stack = state.stack.isEmpty ? "" : " | " + symbolicate(state.stack)
                    log.error("main thread stalled ~\(waitedMs, privacy: .public)ms\(stack, privacy: .public)")
                    print("[stall] main thread blocked ~\(waitedMs)ms\(stack)")
                }
                queue.asyncAfter(deadline: .now() + 0.2) { beat() }
            }
        }
    }

    /// Suspend, walk the fp chain, resume. Addresses only - no symbol work
    /// while the target is frozen.
    private static func captureStack(of thread: thread_act_t) -> [UInt] {
        guard thread_suspend(thread) == KERN_SUCCESS else { return [] }
        var pcs: [UInt] = []
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<arm_thread_state64_t>.stride / MemoryLayout<UInt32>.stride
        )
        let kr = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(thread, ARM_THREAD_STATE64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            // PAC strip: userland text lives well under 2^39 on every iOS
            // address layout we run on; signed LR bits live above.
            func strip(_ p: UInt64) -> UInt { UInt(p & 0x0000_007F_FFFF_FFFF) }
            pcs.append(strip(state.__pc))
            if state.__lr != 0 { pcs.append(strip(state.__lr)) }
            var fp = UInt(state.__fp)
            var depth = 0
            while fp != 0, depth < 48 {
                var frame: (prevFP: UInt, lr: UInt) = (0, 0)
                var out: vm_size_t = 0
                let ok = withUnsafeMutableBytes(of: &frame) { buf -> Bool in
                    guard let base = buf.baseAddress else { return false }
                    return vm_read_overwrite(
                        mach_task_self_,
                        vm_address_t(fp),
                        16,
                        vm_address_t(UInt(bitPattern: base)),
                        &out
                    ) == KERN_SUCCESS && out == 16
                }
                guard ok, frame.lr != 0 else { break }
                pcs.append(strip(UInt64(frame.lr)))
                // Stacks grow down; a chain that stops climbing is torn.
                guard frame.prevFP > fp else { break }
                fp = frame.prevFP
                depth += 1
            }
        }
        thread_resume(thread)
        return pcs
    }

    private static func symbolicate(_ pcs: [UInt]) -> String {
        pcs.prefix(32).map { pc -> String in
            var info = Dl_info()
            guard let ptr = UnsafeRawPointer(bitPattern: pc),
                  dladdr(ptr, &info) != 0, let sname = info.dli_sname else {
                return String(format: "0x%lx", pc)
            }
            let sym = String(cString: sname)
            // Overflow-safe: a PAC-stripped pc against an unstripped saddr
            // must degrade to offset 0, not trap.
            let base = info.dli_saddr.map { UInt(bitPattern: $0) } ?? 0
            let off = pc >= base ? pc - base : 0
            return "\(sym)+\(off)"
        }.joined(separator: " <- ")
    }
}
