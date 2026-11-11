internal import Crypto
import Foundation
internal import NIOCore
internal import NIOSSH
internal import NIOTransportServices
import Synchronization

/// One SSH connection running one git command, read and written as a
/// blocking stream for libgit2.
///
/// The connection runs on an event loop of its own; libgit2 calls in on the
/// repository's thread, which waits here, a slice at a time so that it can
/// notice cancellation, until data comes or can be sent.
final class SSHConnection: Sendable {
    /// How long connecting, the handshake and logging in may take.
    static let connectTimeout: Duration = .seconds(30)
    /// How long a read or write may go with nothing moving. Long, since a
    /// server can be quiet while it counts the objects of a big repository.
    static let idleTimeout: Duration = .seconds(300)
    /// Data from the server is held up to about this much before the
    /// connection stops reading, which leaves the server's window to fill.
    static let readBufferLimit = 4 << 20
    private static let writeChunk = 32 << 10

    let address: SSHAddress
    private let state: State
    private let channel: any Channel
    private let parent: any Channel

    private init(address: SSHAddress, state: State, channel: any Channel, parent: any Channel) {
        self.address = address
        self.state = state
        self.channel = channel
        self.parent = parent
    }

    /// The threads the connections run on. The thread doing a fetch or push
    /// blocks while it waits for these, and that work is started by the
    /// user, so they run at the same priority: on the shared default-priority
    /// loops a waiting operation would be held up behind lower-priority work.
    private static let eventLoops = NIOTSEventLoopGroup(loopCount: 1, defaultQoS: .userInitiated)

    /// Connects, checks the host's key, logs in with the first of `keys` the
    /// server accepts, and starts `command`.
    static func open(
        _ address: SSHAddress,
        command: String,
        keys: [SSHPrivateKey],
        validator: (any SSHHostKeyValidator)?,
        isCancelled: () -> Bool
    ) throws -> SSHConnection {
        let state = State()
        let deadline = ContinuousClock.now + connectTimeout
        let hostKeys = HostKeyCheck(address: address, validator: validator, state: state)
        let login = Login(address: address, keys: keys, state: state)

        let group = Self.eventLoops
        let bootstrap = NIOTSConnectionBootstrap(group: group)
            .connectTimeout(.seconds(Int64(connectTimeout.components.seconds)))
            // Fail at once when the host refuses or there is no network,
            // rather than wait for one to appear.
            .channelOption(NIOTSChannelOptions.waitForActivity, value: false)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let configuration = SSHClientConfiguration(userAuthDelegate: login, serverAuthDelegate: hostKeys)
                    try channel.pipeline.syncOperations.addHandlers(
                        NIOSSHHandler(
                            role: .client(configuration), allocator: channel.allocator,
                            inboundChildChannelInitializer: nil
                        ),
                        ConnectionErrorHandler(state: state)
                    )
                }
            }
        let parent: any Channel
        do {
            parent = try state.wait(for: bootstrap.connect(host: address.host, port: address.port),
                                    until: deadline, isCancelled: isCancelled)
        } catch let error as SSHFailure {
            throw error
        } catch {
            throw SSHFailure.connection(address.host, Self.describe(error))
        }

        do {
            let childPromise = parent.eventLoop.makePromise(of: (any Channel).self)
            parent.eventLoop.execute {
                do {
                    let handler = try parent.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                    handler.createChannel(childPromise, channelType: .session) { child, _ in
                        child.setOption(ChannelOptions.autoRead, value: false).flatMap {
                            child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                        }.flatMapThrowing {
                            try child.pipeline.syncOperations.addHandler(GitChannelHandler(state: state))
                        }
                    }
                } catch {
                    childPromise.fail(error)
                }
            }
            let child = try state.wait(for: childPromise.futureResult, until: deadline, isCancelled: isCancelled)
            let connection = SSHConnection(address: address, state: state, channel: child, parent: parent)
            do {
                let exec = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
                _ = try state.wait(for: child.triggerUserOutboundEvent(exec), until: deadline, isCancelled: isCancelled)
                child.read()
                try state.waitForExecReply(until: deadline, isCancelled: isCancelled)
            } catch {
                connection.close()
                throw error
            }
            return connection
        } catch {
            parent.close(promise: nil)
            if let failure = state.failure { throw failure }
            if error is SSHFailure || error is CancellationError { throw error }
            throw SSHFailure.connection(address.host, Self.describe(error))
        }
    }

    /// Reads what has arrived, up to `buffer.count` bytes, waiting for some
    /// if there is none. Zero is the end of the stream.
    func read(into buffer: UnsafeMutableRawBufferPointer, isCancelled: () -> Bool) throws -> Int {
        let (count, wantsMore) = try state.take(into: buffer, isCancelled: isCancelled)
        if wantsMore { channel.read() }
        return count
    }

    /// Sends all of `bytes`, waiting while the server's window is full.
    func write(_ bytes: UnsafeRawBufferPointer, isCancelled: () -> Bool) throws {
        var offset = 0
        while offset < bytes.count {
            try state.waitUntilWritable(channel: channel, isCancelled: isCancelled)
            let length = min(Self.writeChunk, bytes.count - offset)
            var buffer = channel.allocator.buffer(capacity: length)
            buffer.writeBytes(UnsafeRawBufferPointer(rebasing: bytes[offset..<offset + length]))
            let state = state
            channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer))).whenFailure { error in
                state.record(error)
            }
            offset += length
        }
    }

    /// What the server said went wrong, once its command has ended: its
    /// error output, and its exit status if that was not success.
    var remoteFailure: String? {
        state.remoteFailure
    }

    func close() {
        channel.close(promise: nil)
        parent.close(promise: nil)
    }

    static func describe(_ error: any Error) -> String {
        if let error = error as? ChannelError, case .connectTimeout = error {
            return "The connection timed out."
        }
        if error is NIOSSHError {
            return "The SSH connection failed (\(error))."
        }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

/// Failures of the connection itself, which the transport turns into a
/// ``RemoteError``.
enum SSHFailure: Error {
    case connection(String, String)
    case remote(RemoteError)
}

// MARK: Shared state

extension SSHConnection {
    /// What the event loop and the waiting thread share, under one lock.
    final class State: @unchecked Sendable {
        private let condition = NSCondition()
        private var inbound = ByteBuffer()
        private var errorOutput = Data()
        private var endOfInput = false
        private var closed = false
        private var exitStatus: Int?
        private var execAccepted: Bool?
        private var error: (any Error)?
        private var wantsRead = false
        private var writable = true
        /// Why the connection was refused, as the delegates saw it.
        private var _failure: SSHFailure?

        var failure: SSHFailure? {
            condition.lock()
            defer { condition.unlock() }
            return _failure
        }

        private func update(_ change: (State) -> Void) {
            condition.lock()
            change(self)
            condition.broadcast()
            condition.unlock()
        }

        func fail(_ failure: SSHFailure) {
            update { if $0._failure == nil { $0._failure = failure } }
        }

        func record(_ error: any Error) {
            update { if $0.error == nil { $0.error = error } }
        }

        func received(_ data: ByteBuffer, errorOutput isErrorOutput: Bool) {
            update { state in
                if isErrorOutput {
                    // Enough to explain a failure; a server can say a lot.
                    if state.errorOutput.count < 16 << 10 {
                        state.errorOutput.append(contentsOf: data.readableBytesView)
                    }
                } else {
                    var data = data
                    state.inbound.writeBuffer(&data)
                }
            }
        }

        /// Whether the channel should read again now, after a batch arrived.
        func shouldReadAgain() -> Bool {
            condition.lock()
            defer { condition.unlock() }
            if inbound.readableBytes < SSHConnection.readBufferLimit { return true }
            wantsRead = true
            return false
        }

        func execReplied(_ accepted: Bool) { update { $0.execAccepted = accepted } }
        func exited(_ status: Int) { update { $0.exitStatus = status } }
        func inputEnded() { update { $0.endOfInput = true } }
        func channelClosed() { update { $0.endOfInput = true; $0.closed = true } }
        func writabilityChanged(_ isWritable: Bool) { update { $0.writable = isWritable } }

        var remoteFailure: String? {
            condition.lock()
            defer { condition.unlock() }
            let text = String(decoding: errorOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
            if let exitStatus, exitStatus != 0 { return "The command on the server ended with status \(exitStatus)." }
            return nil
        }

        /// Waits on the condition until `ready` holds, in slices so that
        /// cancellation and the deadline are noticed.
        private func wait(
            until deadline: ContinuousClock.Instant, isCancelled: () -> Bool, _ ready: () -> Bool
        ) throws {
            // Called with the lock held.
            while !ready() {
                if isCancelled() { throw CancellationError() }
                if let _failure { throw _failure }
                if ContinuousClock.now >= deadline { throw SSHFailure.connection("", "The connection timed out.") }
                condition.wait(until: Date().addingTimeInterval(0.1))
            }
        }

        func wait<Value: Sendable>(
            for future: EventLoopFuture<Value>, until deadline: ContinuousClock.Instant, isCancelled: () -> Bool
        ) throws -> Value {
            let result = Outcome<Value>()
            future.whenComplete { outcome in
                self.update { _ in result.value = outcome }
            }
            condition.lock()
            defer { condition.unlock() }
            try wait(until: deadline, isCancelled: isCancelled) { result.value != nil }
            return try result.value!.get()
        }

        func waitForExecReply(until deadline: ContinuousClock.Instant, isCancelled: () -> Bool) throws {
            condition.lock()
            defer { condition.unlock() }
            try wait(until: deadline, isCancelled: isCancelled) { execAccepted != nil || closed || error != nil }
            if let error { throw error }
            guard execAccepted == true else {
                let reason = String(decoding: errorOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                throw SSHFailure.connection("", reason.isEmpty ? "The server would not run git." : reason)
            }
        }

        func take(into buffer: UnsafeMutableRawBufferPointer, isCancelled: () -> Bool) throws -> (Int, Bool) {
            condition.lock()
            defer { condition.unlock() }
            try wait(until: .now + SSHConnection.idleTimeout, isCancelled: isCancelled) {
                inbound.readableBytes > 0 || endOfInput || error != nil
            }
            if inbound.readableBytes == 0, let error { throw error }
            let count = min(buffer.count, inbound.readableBytes)
            if count > 0, let base = buffer.baseAddress {
                inbound.withUnsafeReadableBytes { bytes in
                    base.copyMemory(from: bytes.baseAddress!, byteCount: count)
                }
                inbound.moveReaderIndex(forwardBy: count)
                inbound.discardReadBytes()
            }
            let readAgain = wantsRead && inbound.readableBytes < SSHConnection.readBufferLimit / 2
            if readAgain { wantsRead = false }
            return (count, readAgain)
        }

        func waitUntilWritable(channel: any Channel, isCancelled: () -> Bool) throws {
            condition.lock()
            defer { condition.unlock() }
            try wait(until: .now + SSHConnection.idleTimeout, isCancelled: isCancelled) {
                writable || closed || error != nil
            }
            if let error { throw error }
            if closed { throw SSHFailure.connection("", "The server closed the connection.") }
        }
    }
}

/// A future's result, written and read under `State`'s lock.
private final class Outcome<Value: Sendable>: @unchecked Sendable {
    var value: Result<Value, any Error>?
}

// MARK: Handlers

/// Passes the git command's output to the shared state and reads more only
/// as the reader keeps up.
private final class GitChannelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let state: SSHConnection.State

    init(state: SSHConnection.State) {
        self.state = state
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = message.data else { return }
        state.received(buffer, errorOutput: message.type == .stdErr)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        if state.shouldReadAgain() {
            context.read()
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            state.execReplied(true)
        case is ChannelFailureEvent:
            state.execReplied(false)
        case let status as SSHChannelRequestEvent.ExitStatus:
            state.exited(status.exitStatus)
        case let event as ChannelEvent where event == .inputClosed:
            state.inputEnded()
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        state.writabilityChanged(context.channel.isWritable)
    }

    func channelInactive(context: ChannelHandlerContext) {
        state.channelClosed()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        state.record(error)
        context.close(promise: nil)
    }
}

/// Records why the connection failed, and closes it.
private final class ConnectionErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    private let state: SSHConnection.State

    init(state: SSHConnection.State) {
        self.state = state
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        state.record(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        state.channelClosed()
        context.fireChannelInactive()
    }
}

// MARK: Delegates

/// Checks the server's key with the validator; never trusts one silently.
private final class HostKeyCheck: NIOSSHClientServerAuthenticationDelegate, Sendable {
    private struct Refused: Error {}

    let address: SSHAddress
    let validator: (any SSHHostKeyValidator)?
    let state: SSHConnection.State

    init(address: SSHAddress, validator: (any SSHHostKeyValidator)?, state: SSHConnection.State) {
        self.address = address
        self.validator = validator
        self.state = state
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        guard let key = try? SSHPublicKey(openSSH: String(openSSHPublicKey: hostKey)) else {
            state.fail(.connection(address.host, "The server’s host key could not be read."))
            validationCompletePromise.fail(Refused())
            return
        }
        let hostKey = SSHHostKey(host: address.host, port: address.port, publicKey: key)
        switch validator?.trust(for: hostKey) ?? .unknown {
        case .trusted:
            validationCompletePromise.succeed()
        case .unknown:
            state.fail(.remote(.unknownHostKey(hostKey)))
            validationCompletePromise.fail(Refused())
        case .mismatch(let known):
            state.fail(.remote(.hostKeyChanged(hostKey, known: known)))
            validationCompletePromise.fail(Refused())
        }
    }
}

/// Offers each key in turn until the server accepts one.
private final class Login: NIOSSHClientUserAuthenticationDelegate, Sendable {
    private struct NoMoreKeys: Error {}

    let address: SSHAddress
    let keys: [SSHPrivateKey]
    let state: SSHConnection.State
    private let next = Mutex(0)

    init(address: SSHAddress, keys: [SSHPrivateKey], state: SSHConnection.State) {
        self.address = address
        self.keys = keys
        self.state = state
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        let host = address.host, username = address.loginName
        guard availableMethods.contains(.publicKey) else {
            state.fail(.remote(.sshKeysNotAccepted(host: host)))
            nextChallengePromise.fail(NoMoreKeys())
            return
        }
        let index = next.withLock { index in
            defer { index += 1 }
            return index
        }
        guard index < keys.count else {
            state.fail(.remote(keys.isEmpty
                ? .sshKeyRequired(host: host, username: username)
                : .sshKeysRejected(host: host, username: username)))
            nextChallengePromise.fail(NoMoreKeys())
            return
        }
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
            username: username, serviceName: "",
            offer: .privateKey(.init(privateKey: keys[index].nioKey))
        ))
    }
}

extension SSHPrivateKey {
    /// The key as the SSH library takes it. `init` checked the material.
    fileprivate var nioKey: NIOSSHPrivateKey {
        switch kind {
        case .ed25519: NIOSSHPrivateKey(ed25519Key: try! .init(rawRepresentation: rawRepresentation))
        case .ecdsaP256: NIOSSHPrivateKey(p256Key: try! .init(rawRepresentation: rawRepresentation))
        case .ecdsaP384: NIOSSHPrivateKey(p384Key: try! .init(rawRepresentation: rawRepresentation))
        case .ecdsaP521: NIOSSHPrivateKey(p521Key: try! .init(rawRepresentation: rawRepresentation))
        }
    }
}
