import Foundation

/// Connects stock `constraint.Rope` commands to the same authoritative FIFO
/// already used by Entity replication, console, net, rigid bodies, and welds.
/// The adapter owns no second sequence clock and performs exact suffix
/// rollback through `GMLuaNetTransport`.
public final class SourceCanonicalRopePhysicsCommandQueue:
    SourceCanonicalRopeConstraintCommandQueue,
    @unchecked Sendable
{
    private let transport: GMLuaNetTransport

    public init(transport: GMLuaNetTransport) {
        self.transport = transport
    }

    @discardableResult
    public func enqueueCanonicalRopeConstraintCommands(
        _ commands: [SourceCanonicalRopeConstraintCommand]
    ) throws -> [SourceCanonicalQueuedRopeConstraintCommand] {
        let mapped = try commands.map(Self.physicsPayload)
        var accepted: [SourcePhysicsCommand] = []
        accepted.reserveCapacity(mapped.count)
        do {
            for payload in mapped {
                let queued: [SourcePhysicsCommand]
                switch payload {
                case let .createLengthConstraint(creation):
                    queued = try transport
                        .enqueueCanonicalPhysicsConstraintCommands([
                            .createLength(creation),
                        ])
                case let .mutateBody(mutation):
                    queued = try transport.enqueueCanonicalPhysicsBodyCommands([
                        .mutate(mutation),
                    ])
                case let .deleteConstraint(deletion):
                    queued = try transport
                        .enqueueCanonicalPhysicsConstraintCommands([
                            .delete(deletion),
                        ])
                default:
                    preconditionFailure("rope emitted a non-rope payload")
                }
                precondition(queued.count == 1)
                accepted.append(queued[0])
            }
        } catch {
            transport.rollbackCanonicalPhysicsConstraintCommands(accepted)
            throw error
        }
        return zip(commands, accepted).map { command, physics in
            SourceCanonicalQueuedRopeConstraintCommand(
                sequence: physics.sequence,
                command: command
            )
        }
    }

    public func rollbackCanonicalRopeConstraintCommands(
        _ commands: [SourceCanonicalQueuedRopeConstraintCommand]
    ) {
        let physics = commands.map { queued -> SourcePhysicsCommand in
            guard let payload = try? Self.physicsPayload(queued.command) else {
                preconditionFailure(
                    "only validated rope commands may reach FIFO rollback"
                )
            }
            return SourcePhysicsCommand(
                sequence: queued.sequence,
                payload: payload
            )
        }
        transport.rollbackCanonicalPhysicsConstraintCommands(physics)
    }

    private static func physicsPayload(
        _ command: SourceCanonicalRopeConstraintCommand
    ) throws -> SourcePhysicsCommandPayload {
        switch command {
        case let .create(request):
            guard request.forceLimit == 0 else {
                throw SourceCanonicalRopeConstraintBackendError
                    .breakableLengthConstraintUnavailable
            }
            let first = try endpoint(request.first)
            let second = try endpoint(request.second)
            // CPhysConstraint consistently places the world object in slot 0.
            let reference: SourcePhysicsLengthConstraintEndpoint
            let attached: SourcePhysicsLengthConstraintEndpoint
            if second.kind == .staticWorld, first.kind != .staticWorld {
                reference = second
                attached = first
            } else {
                reference = first
                attached = second
            }
            let minimumLength = request.isRigid ? request.maximumLength : 0
            return .createLengthConstraint(
                try SourcePhysicsLengthConstraintCreationCommand(
                    constraintID: request.constraintID,
                    reference: reference,
                    attached: attached,
                    minimumLength: minimumLength,
                    maximumLength: request.maximumLength,
                    forceLimitKilogramInchesPerSecond: 0
                )
            )
        case let .wake(bodyID):
            return .mutateBody(try SourcePhysicsBodyMutationCommand(
                bodyID: bodyID,
                mutation: .wake
            ))
        case let .delete(constraintID):
            return .deleteConstraint(SourcePhysicsConstraintDeletionCommand(
                constraintID: constraintID
            ))
        }
    }

    private static func endpoint(
        _ endpoint: SourceCanonicalRopePhysicsEndpoint
    ) throws -> SourcePhysicsLengthConstraintEndpoint {
        let kind: SourcePhysicsLengthConstraintEndpointKind
        switch endpoint.kind {
        case .dynamicBody:
            kind = .body
        case .staticWorld:
            kind = .staticWorld
        }
        return try SourcePhysicsLengthConstraintEndpoint(
            bodyID: endpoint.bodyID,
            kind: kind,
            localAnchor: endpoint.localAnchor
        )
    }
}
