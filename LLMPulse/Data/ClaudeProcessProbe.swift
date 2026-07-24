import Darwin
import Foundation

/// What can be established about a process id without touching it.
struct ClaudeProcessFacts: Equatable, Sendable {
    /// Seconds since the epoch at which the process started. Used to reject a
    /// recycled pid whose registry file outlived its process.
    let startedAt: Int

    /// True while the process has exited but has not been reaped. A zombie's
    /// start time still matches its registry entry, so nothing else can rule
    /// it out.
    let isZombie: Bool

    /// Absolute path of the running executable. Immutable for a live process,
    /// and — unlike the argument vector — it cannot be made to look like
    /// Claude by a wrapper that merely passes the path as an argument.
    let executablePath: String
}

protocol ClaudeProcessProbing: Sendable {
    /// Returns `nil` when the pid is dead, unreachable, or owned by another
    /// user. Every failure is indistinguishable from "not running" on purpose:
    /// a monitor that cannot see a process must not claim it is alive.
    func facts(forProcessID processID: Int32) -> ClaudeProcessFacts?
}

/// Reads process facts through `libproc`.
///
/// Deliberately syscall-only. Spawning `ps` would cost roughly four orders of
/// magnitude more per poll, and parsing its localized, space-padded timestamp
/// back into a `Date` is an entire class of bug that simply does not exist
/// when the kernel hands over an epoch integer.
struct LibprocProcessProbe: ClaudeProcessProbing {
    /// `SZOMB` from `sys/proc.h`, which Swift does not re-export.
    private static let zombieStatus: UInt32 = 5

    /// `PROC_PIDPATHINFO_MAXSIZE` from `libproc.h` — a macro, so it is also
    /// absent from Swift. Defined there as `4 * MAXPATHLEN`.
    private static let executablePathBufferSize = 4 * Int(MAXPATHLEN)

    func facts(forProcessID processID: Int32) -> ClaudeProcessFacts? {
        // A pid of 0 or -1 addresses process groups, and `kill` succeeds for
        // both. A truncated registry file yielding 0 would otherwise become a
        // permanent phantom row.
        guard processID > 1 else { return nil }

        // `EPERM` means the pid belongs to another user, which for a 0700
        // same-uid registry can only mean the pid was recycled.
        if kill(processID, 0) != 0 { return nil }

        var info = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, infoSize)
        guard read == infoSize else { return nil }
        guard info.pbi_status != Self.zombieStatus else { return nil }

        var pathBuffer = [CChar](repeating: 0, count: Self.executablePathBufferSize)
        let pathLength = proc_pidpath(
            processID,
            &pathBuffer,
            UInt32(Self.executablePathBufferSize)
        )
        guard pathLength > 0 else { return nil }

        let pathBytes = pathBuffer.prefix(Int(pathLength)).map { UInt8(bitPattern: $0) }
        return ClaudeProcessFacts(
            startedAt: Int(info.pbi_start_tvsec),
            isZombie: false,
            executablePath: String(decoding: pathBytes, as: UTF8.self)
        )
    }
}
