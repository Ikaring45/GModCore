public final class GMEngine {

    // Source/GMod実測に合わせた最初の固定tick。
    public static let tickInterval: Double = 0.015

    private static let maxTicksPerFrame = 8

    private var accumulator: Double = 0

    public private(set) var tickCount: UInt64 = 0

    public private(set) var isRunning = false

    public private(set) var rotation: Float = 0

    public var curTime: Double {
        Double(tickCount) * Self.tickInterval
    }

    public init() {
    }

    public func boot() {

        accumulator = 0
        tickCount = 0
        rotation = 0

        isRunning = true
    }

    public func shutdown() {

        isRunning = false
        accumulator = 0
    }

    @discardableResult
    public func frame(
        deltaTime rawDeltaTime: Double
    ) -> Int {

        guard isRunning else {
            return 0
        }

        var deltaTime = rawDeltaTime

        if deltaTime < 0 {
            deltaTime = 0
        }

        // アプリ復帰などで巨大なdeltaが来ても
        // 物理演算が暴走しないようにする。
        if deltaTime > 0.25 {
            deltaTime = 0.25
        }

        accumulator += deltaTime

        var executedTicks = 0

        while
            accumulator >= Self.tickInterval &&
            executedTicks < Self.maxTicksPerFrame
        {

            accumulator -= Self.tickInterval

            tick()

            executedTicks += 1
        }

        // Spiral of Death防止。
        if
            executedTicks == Self.maxTicksPerFrame &&
            accumulator >= Self.tickInterval
        {
            accumulator = 0
        }

        return executedTicks
    }

    private func tick() {

        tickCount &+= 1

        /*
         今はテストとして回転角を更新。

         後でここが、

         PlayerMovement
         Physics
         Entity Think
         Lua hooks
         Constraints

         などのSource風simulationになる。
        */

        let angularVelocity: Float = 0.8

        rotation +=
            angularVelocity *
            Float(Self.tickInterval)

        let fullTurn =
            Float.pi * 2

        if rotation >= fullTurn {
            rotation -= fullTurn
        }
    }
}
