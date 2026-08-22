import Foundation
import GModLua

/// One Source entity sound accepted by the authoritative realm. The full
/// EHANDLE and emission origin are captured at enqueue time, so removing or
/// recycling the entity before CLIENT delivery cannot retarget the sound.
public struct GMLuaEntitySoundEvent: Equatable, Sendable {
    public let entityIdentity: SourceCanonicalEntityIdentity
    public let sound: LuaString
    public let origin: SourceVector3
    public let level: Double
    public let pitch: Double
    public let volume: Double
    public let channel: Int32
    public let flags: Int32
    public let dsp: Int32

    public init(
        entityIdentity: SourceCanonicalEntityIdentity,
        sound: LuaString,
        origin: SourceVector3,
        level: Double = 75,
        pitch: Double = 100,
        volume: Double = 1,
        channel: Int32 = 0,
        flags: Int32 = 0,
        dsp: Int32 = 0
    ) {
        self.entityIdentity = entityIdentity
        self.sound = sound
        self.origin = origin
        self.level = level
        self.pitch = pitch
        self.volume = volume
        self.channel = channel
        self.flags = flags
        self.dsp = dsp
    }

    public var clientPlayEvent: GMLuaSoundPlayEvent {
        GMLuaSoundPlayEvent(
            realm: .client,
            sound: sound,
            x: Double(origin.x),
            y: Double(origin.y),
            z: Double(origin.z),
            level: level,
            pitch: pitch,
            volume: volume,
            dsp: Double(dsp)
        )
    }
}

public struct GMLuaWeaponAnimationEvent: Equatable, Sendable {
    public let weaponIdentity: SourceCanonicalEntityIdentity
    public let activity: Int32

    public init(
        weaponIdentity: SourceCanonicalEntityIdentity,
        activity: Int32
    ) {
        self.weaponIdentity = weaponIdentity
        self.activity = activity
    }
}

public struct GMLuaPlayerAnimationEvent: Equatable, Sendable {
    public let playerIdentity: SourceCanonicalEntityIdentity
    public let animation: Int32

    public init(
        playerIdentity: SourceCanonicalEntityIdentity,
        animation: Int32
    ) {
        self.playerIdentity = playerIdentity
        self.animation = animation
    }
}

/// Immutable engine events carried by the existing net/console/entity FIFO.
/// These are renderer/audio handoffs, not claims that Metal animation,
/// particles, or a decoded audio asset completed successfully.
public enum GMLuaGameplayEventPayload: Equatable, Sendable {
    case effect(GMLuaEffectRequest)
    case entitySound(GMLuaEntitySoundEvent)
    case weaponAnimation(GMLuaWeaponAnimationEvent)
    case playerAnimation(GMLuaPlayerAnimationEvent)
}

public struct GMLuaGameplayEventDelivery: Equatable, Sendable {
    public let transportSequence: UInt64
    public let payload: GMLuaGameplayEventPayload

    public init(
        transportSequence: UInt64,
        payload: GMLuaGameplayEventPayload
    ) {
        self.transportSequence = transportSequence
        self.payload = payload
    }
}

public typealias GMLuaGameplayEventHandler = @Sendable (
    GMLuaGameplayEventDelivery
) throws -> Void

/// CLIENT-owned observation state installed beside the native bridges. It
/// records the common FIFO sequence for animation/audio/effect consumers while
/// `GMLuaEffects` and `GMLuaSound` retain their existing specialized queues.
public final class GMLuaGameplayEventClientState: @unchecked Sendable {
    public static let maximumCapturedDeliveries = 4_096

    private let lock = NSLock()
    private var deliveries: [GMLuaGameplayEventDelivery] = []
    private var droppedDeliveryCountStorage: UInt64 = 0

    public init() {}

    public var capturedDeliveries: [GMLuaGameplayEventDelivery] {
        lock.lock()
        defer { lock.unlock() }
        return deliveries
    }

    public var droppedDeliveryCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return droppedDeliveryCountStorage
    }

    public func drainCapturedDeliveries() -> [GMLuaGameplayEventDelivery] {
        lock.lock()
        defer { lock.unlock() }
        let result = deliveries
        deliveries.removeAll(keepingCapacity: true)
        droppedDeliveryCountStorage = 0
        return result
    }

    func capture(_ delivery: GMLuaGameplayEventDelivery) {
        lock.lock()
        if deliveries.count < Self.maximumCapturedDeliveries {
            deliveries.append(delivery)
        } else if droppedDeliveryCountStorage < UInt64.max {
            droppedDeliveryCountStorage += 1
        }
        lock.unlock()
    }
}
