import Foundation

enum LuaThreadResumeResult {
    case success([LuaValue])
    case failure(LuaValue)
}

public final class LuaThread: @unchecked Sendable {
    public enum Status: String, Sendable {
        case suspended
        case running
        case normal
        case dead
    }

    private enum Event {
        case yielded([LuaValue])
        case returned([LuaValue])
        case failed(LuaValue)
    }

    private static let tlsKey = "GModLua.LuaThread.current"

    weak var state: LuaState?
    private var entry: LuaValue
    let debugHookState = LuaDebugHookState()
    var environmentTable: LuaTable

    private let condition = NSCondition()
    private var started = false
    private var finished = false
    private var event: Event?
    private var resumeArguments: [LuaValue] = []
    private var hasResumeArguments = false
    private var worker: Thread?
    private var callStack: LuaCallStackBox?
    private var failedFrames: [LuaCallFrame]?
    private var _status: Status = .suspended

    init(state: LuaState, entry: LuaValue) {
        self.state = state
        self.entry = entry
        self.environmentTable = state.currentThreadEnvironmentTable
    }

    public var status: Status {
        condition.lock(); defer { condition.unlock() }
        return _status
    }

    func markNormal() {
        condition.lock()
        if _status == .running { _status = .normal }
        condition.unlock()
    }

    func markRunning() {
        condition.lock()
        if _status == .normal { _status = .running }
        condition.unlock()
    }

    static var current: LuaThread? {
        Thread.current.threadDictionary[tlsKey] as? LuaThread
    }

    /// Lua coroutine.resume semantics, excluding the leading boolean result.
    func resume(_ arguments: [LuaValue]) -> LuaThreadResumeResult {
        condition.lock()

        if finished || _status == .dead {
            condition.unlock()
            return .failure(.string("cannot resume dead coroutine"))
        }
        if _status == .running || _status == .normal {
            condition.unlock()
            return .failure(.string("cannot resume non-suspended coroutine"))
        }

        if !started {
            started = true
            _status = .running
            let initialArguments = arguments
            let thread = Thread { [weak self] in
                guard let self else { return }
                Thread.current.threadDictionary[Self.tlsKey] = self
                defer { Thread.current.threadDictionary.removeObject(forKey: Self.tlsKey) }
                do {
                    guard let state = self.state else {
                        self.finish(.failed(.string("coroutine state released")))
                        return
                    }
                    self.condition.lock()
                    self.callStack = state.currentCallStack()
                    self.condition.unlock()
                    let values = try state.callValue(self.entry, arguments: initialArguments)
                    self.finish(.returned(values))
                } catch let raised as LuaRaisedError {
                    self.finish(.failed(raised.value))
                } catch {
                    let text: String
                    if let luaError = error as? LuaError { text = luaError.description }
                    else { text = String(describing: error) }
                    self.finish(.failed(.string(LuaString(text))))
                }
            }
            worker = thread
            thread.name = "GModLua coroutine"
            thread.start()
        } else {
            _status = .running
            resumeArguments = arguments
            hasResumeArguments = true
            condition.broadcast()
        }

        while event == nil {
            condition.wait()
        }

        let captured = event!
        event = nil
        switch captured {
        case let .yielded(values):
            _status = .suspended
            condition.unlock()
            return .success(values)
        case let .returned(values):
            finished = true
            _status = .dead
            condition.unlock()
            return .success(values)
        case let .failed(value):
            finished = true
            _status = .dead
            condition.unlock()
            return .failure(value)
        }
    }

    /// Called by coroutine.yield from the coroutine worker thread.
    func yield(_ values: [LuaValue]) throws -> [LuaValue] {
        condition.lock()
        guard !finished else {
            condition.unlock()
            throw LuaError.runtime("cannot yield a dead coroutine")
        }

        event = .yielded(values)
        _status = .suspended
        condition.broadcast()

        while !hasResumeArguments && !finished {
            condition.wait()
        }

        if finished {
            condition.unlock()
            throw LuaError.runtime("cannot resume dead coroutine")
        }

        let arguments = resumeArguments
        resumeArguments = []
        hasResumeArguments = false
        _status = .running
        condition.unlock()
        return arguments
    }

    private func finish(_ completed: Event) {
        condition.lock()
        event = completed
        condition.broadcast()
        condition.unlock()
    }

    func callStackFrames() -> [LuaCallFrame] {
        condition.lock(); defer { condition.unlock() }
        return failedFrames ?? callStack?.frames ?? []
    }

    func captureFailureFrames(_ frames: [LuaCallFrame]) {
        condition.lock(); defer { condition.unlock() }
        if failedFrames == nil { failedFrames = frames }
    }

    func failureFramesSnapshot() -> [LuaCallFrame]? {
        condition.lock(); defer { condition.unlock() }
        return failedFrames
    }

    func clearFailureFrames() {
        condition.lock(); defer { condition.unlock() }
        failedFrames = nil
    }

    func luaDebugFrames() -> [LuaCallFrame] {
        callStackFrames().filter { frame in
            if case .nativeFunction = frame.callable { return false }
            return true
        }
    }

    func seedHookLinesFromCurrentPC() {
        condition.lock(); defer { condition.unlock() }
        guard let callStack else { return }
        for index in callStack.frames.indices {
            callStack.frames[index].lastHookLine = callStack.frames[index].currentLine
        }
    }

    func gcReferences() -> (values: [LuaValue], environments: [LuaEnvironment]) {
        condition.lock(); defer { condition.unlock() }
        var values = [entry, .table(environmentTable)] + resumeArguments
        var environments: [LuaEnvironment] = []
        let frames = failedFrames ?? callStack?.frames ?? []
        for frame in frames {
            values.append(frame.callable)
            values.append(contentsOf: frame.temporaries)
            if let environment = frame.environment { environments.append(environment) }
        }
        if let event {
            switch event {
            case let .yielded(eventValues), let .returned(eventValues):
                values.append(contentsOf: eventValues)
            case let .failed(value):
                values.append(value)
            }
        }
        return (values, environments)
    }

    func gcClearReferences() {
        condition.lock(); defer { condition.unlock() }
        guard _status == .dead || !started else { return }
        entry = .nilValue
        resumeArguments.removeAll(keepingCapacity: false)
        event = nil
        failedFrames = nil
        callStack = nil
        worker = nil
    }
}
