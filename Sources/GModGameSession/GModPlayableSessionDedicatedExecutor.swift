import Foundation

/// A single, long-lived engine thread used as the serial executor for one
/// playable session lane. The Source/Lua graph performs deep synchronous Swift
/// calls and uses thread-local bookkeeping, so it must not inherit the small,
/// thread-hopping execution environment of the cooperative global pool.
final class GModPlayableSessionDedicatedExecutor: SerialExecutor,
    @unchecked Sendable
{
    static let stackSize = 16 * 1_024 * 1_024

    private typealias ShutdownCleanup = (_ workerIdentity: String) -> Void

    private struct PendingJob: Sendable {
        let job: UnownedJob

        // `UnownedSerialExecutor` does not retain its executor. Keeping this
        // strong reference with the queued job guarantees that the identity
        // passed to runSynchronously remains alive until that one execution.
        let executor: GModPlayableSessionDedicatedExecutor
    }

    private enum PendingWork {
        case job(PendingJob)
        case shutdownCleanup(ShutdownCleanup)
    }

    private final class WorkerState: @unchecked Sendable {
        let identity = UUID().uuidString
        let threadMarkerKey =
            "GModGameSession.DedicatedExecutor." + UUID().uuidString

        private let condition = NSCondition()
        private var pending: [PendingJob] = []
        private var shutdownCleanup: ShutdownCleanup?
        private var stopRequested = false
        private var workerFinished = false

        func enqueue(_ pendingJob: PendingJob) {
            condition.lock()
            // SerialExecutor jobs may never be dropped: doing so leaks and
            // permanently suspends the task represented by the job.
            precondition(
                !stopRequested,
                "playable session executor received a job after shutdown"
            )
            pending.append(pendingJob)
            condition.signal()
            condition.unlock()
        }

        func takeNext() -> PendingWork? {
            condition.lock()
            while pending.isEmpty, !stopRequested {
                condition.wait()
            }
            if !pending.isEmpty {
                let next = pending.removeFirst()
                condition.unlock()
                return .job(next)
            }
            if let cleanup = shutdownCleanup {
                shutdownCleanup = nil
                condition.unlock()
                return .shutdownCleanup(cleanup)
            }
            workerFinished = true
            condition.broadcast()
            condition.unlock()
            return nil
        }

        func replaceShutdownCleanup(_ cleanup: @escaping ShutdownCleanup) {
            condition.lock()
            precondition(
                !stopRequested,
                "playable session executor installed cleanup after shutdown"
            )
            let retiredCleanup = shutdownCleanup
            shutdownCleanup = cleanup
            condition.unlock()

            // The caller is the worker. Keep the retired capture alive until
            // after the lock is released, then release it on that same worker.
            withExtendedLifetime(retiredCleanup) {}
        }

        func clearShutdownCleanup() {
            condition.lock()
            let retiredCleanup = shutdownCleanup
            shutdownCleanup = nil
            condition.unlock()

            // Session teardown already completed on the worker. Its fallback
            // strong reference must also be retired there.
            withExtendedLifetime(retiredCleanup) {}
        }

        func requestStop() {
            condition.lock()
            stopRequested = true
            condition.broadcast()
            condition.unlock()
        }

        func waitUntilFinished() {
            condition.lock()
            while !workerFinished {
                condition.wait()
            }
            condition.unlock()
        }

        var isCurrentWorker: Bool {
            Thread.current.threadDictionary[threadMarkerKey] as? Bool == true
        }
    }

    private let state: WorkerState
    private let worker: Thread

    init() {
        let state = WorkerState()
        self.state = state
        worker = Thread {
            Thread.current.threadDictionary[state.threadMarkerKey] = true
            defer {
                Thread.current.threadDictionary.removeObject(
                    forKey: state.threadMarkerKey
                )
            }

            while let work = state.takeNext() {
                #if canImport(Darwin)
                autoreleasepool {
                    Self.run(work, state: state)
                }
                #else
                Self.run(work, state: state)
                #endif
            }
        }
        worker.name = "GMod playable session"
        worker.stackSize = Self.stackSize
        worker.qualityOfService = .userInitiated
        worker.start()
    }

    deinit {
        state.requestStop()
        // The last queued job can release the last executor reference on the
        // worker itself. Waiting for that same thread would deadlock; in that
        // case the loop observes stopRequested on its next iteration.
        if !state.isCurrentWorker {
            state.waitUntilFinished()
        }
    }

    func enqueue(_ job: UnownedJob) {
        enqueueImpl(job)
    }

    #if compiler(>=5.9)
    #if os(Windows) || os(Linux)
    func enqueue(_ job: consuming ExecutorJob) {
        enqueueImpl(UnownedJob(job))
    }
    #else
    @available(
        macOS 14.0,
        iOS 17.0,
        tvOS 17.0,
        watchOS 10.0,
        *)
    func enqueue(_ job: consuming ExecutorJob) {
        enqueueImpl(UnownedJob(job))
    }
    #endif
    #endif

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    var workerIdentity: String { state.identity }
    var isCurrentWorker: Bool { state.isCurrentWorker }

    /// Retains a worker-owned fallback until normal session close clears it.
    /// The cleanup runs after all accepted jobs and before the worker exits.
    /// It must not capture this executor, which would create a shutdown cycle.
    func replaceShutdownCleanup(
        _ cleanup: @escaping (_ workerIdentity: String) -> Void
    ) {
        preconditionIsCurrentWorker()
        state.replaceShutdownCleanup(cleanup)
    }

    func clearShutdownCleanup() {
        preconditionIsCurrentWorker()
        state.clearShutdownCleanup()
    }

    func preconditionIsCurrentWorker(
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        precondition(
            state.isCurrentWorker,
            "playable session actor escaped its dedicated engine thread",
            file: file,
            line: line
        )
    }

    private func enqueueImpl(_ job: UnownedJob) {
        state.enqueue(PendingJob(job: job, executor: self))
    }

    private static func run(_ work: PendingWork, state: WorkerState) {
        switch work {
        case let .job(pendingJob):
            pendingJob.job.runSynchronously(
                on: pendingJob.executor.asUnownedSerialExecutor()
            )
        case let .shutdownCleanup(cleanup):
            cleanup(state.identity)
        }
    }
}
