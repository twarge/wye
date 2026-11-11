import Clibgit2
import Foundation

/// libgit2's SSH transport, made in Swift: libgit2 speaks git's protocol
/// and this carries it over an ``SSHConnection``.
///
/// One instance serves one libgit2 transport, on the thread of the
/// operation using it. Its credentials and host-key checks come from the
/// operation's ``RemoteSession``, found through the remote callbacks'
/// payload, which every network operation in GitKit sets.
final class SSHTransport {
    private let session: RemoteSession?
    private var connection: SSHConnection?

    private init(session: RemoteSession?) {
        self.session = session
    }

    private var isCancelled: Bool {
        session?.isCancelled ?? Task.isCancelled
    }

    /// Registers the transport with libgit2. Called once, from
    /// ``GitEnvironment``'s initialization.
    static func register() {
        var callbacks = clibgit2_ssh_callbacks()
        callbacks.create = { payload in
            let transport = SSHTransport(session: RemoteSession.from(payload))
            return Unmanaged.passRetained(transport).toOpaque()
        }
        callbacks.action = { context, url, service in
            guard let context, let url else { return -1 }
            return SSHTransport.transport(context).action(url: String(cString: url), service: service)
        }
        callbacks.read = { context, buffer, size, bytesRead in
            guard let context, let buffer, let bytesRead else { return -1 }
            return SSHTransport.transport(context).read(UnsafeMutableRawBufferPointer(start: buffer, count: size), into: bytesRead)
        }
        callbacks.write = { context, buffer, length in
            guard let context, let buffer else { return -1 }
            return SSHTransport.transport(context).write(UnsafeRawBufferPointer(start: buffer, count: length))
        }
        callbacks.close = { context in
            guard let context else { return 0 }
            SSHTransport.transport(context).close()
            return 0
        }
        callbacks.free = { context in
            guard let context else { return }
            let transport = Unmanaged<SSHTransport>.fromOpaque(context).takeRetainedValue()
            transport.close()
        }
        let code = clibgit2_register_ssh_transport(&callbacks)
        precondition(code == 0, "The SSH transport could not be registered with libgit2.")
    }

    private static func transport(_ context: UnsafeMutableRawPointer) -> SSHTransport {
        Unmanaged<SSHTransport>.fromOpaque(context).takeUnretainedValue()
    }

    // MARK: Callbacks

    private func action(url: String, service: Int32) -> Int32 {
        switch UInt32(service) {
        case GIT_SERVICE_UPLOADPACK_LS.rawValue, GIT_SERVICE_RECEIVEPACK_LS.rawValue:
            close()
            let program = UInt32(service) == GIT_SERVICE_UPLOADPACK_LS.rawValue ? "git-upload-pack" : "git-receive-pack"
            do {
                connection = try connect(url: url, program: program)
                return 0
            } catch {
                return fail(error)
            }
        case GIT_SERVICE_UPLOADPACK.rawValue, GIT_SERVICE_RECEIVEPACK.rawValue:
            // Stateful: the command the listing started carries on.
            guard connection != nil else {
                return fail(SSHFailure.connection(hostName(url), "The connection was closed."))
            }
            return 0
        default:
            return fail(SSHFailure.connection(hostName(url), "libgit2 asked for an unknown service."))
        }
    }

    private func connect(url: String, program: String) throws -> SSHConnection {
        let address = try SSHAddress(url)
        session?.report(TransferProgress(phase: .connecting))
        let request = SSHKeyRequest(host: address.host, port: address.port, username: address.loginName)
        let provider = session?.credentials
        let keys = provider?.sshKeys(for: request) ?? []
        return try SSHConnection.open(
            address, command: address.command(program), keys: keys, validator: provider,
            isCancelled: { [weak self] in self?.isCancelled ?? true }
        )
    }

    private func read(_ buffer: UnsafeMutableRawBufferPointer, into bytesRead: UnsafeMutablePointer<Int>) -> Int32 {
        guard let connection else { return fail(SSHFailure.connection("", "The connection was closed.")) }
        do {
            let count = try connection.read(into: buffer, isCancelled: { isCancelled })
            if count == 0 {
                explainEnd(of: connection)
            }
            bytesRead.pointee = count
            return 0
        } catch {
            explainEnd(of: connection)
            return fail(error)
        }
    }

    private func write(_ bytes: UnsafeRawBufferPointer) -> Int32 {
        guard let connection else { return fail(SSHFailure.connection("", "The connection was closed.")) }
        do {
            try connection.write(bytes, isCancelled: { isCancelled })
            return 0
        } catch {
            explainEnd(of: connection)
            return fail(error)
        }
    }

    private func close() {
        connection?.close()
        connection = nil
    }

    // MARK: Errors

    /// When the server's command stops early, what it said is a better
    /// reason than libgit2's "early EOF". Kept only if the operation fails.
    private func explainEnd(of connection: SSHConnection) {
        guard let message = connection.remoteFailure, session?.failure == nil else { return }
        session?.failure = .remoteCommandFailed(host: connection.address.host, message: message)
    }

    /// Records the failure for the session and libgit2, and returns
    /// libgit2's error code.
    private func fail(_ error: any Error) -> Int32 {
        let remoteError: RemoteError? = switch error {
        case let error as RemoteError: error
        case SSHFailure.remote(let error): error
        case SSHFailure.connection(let host, let reason):
            .sshConnectionFailed(host: host.isEmpty ? (connection?.address.host ?? "the server") : host, reason: reason)
        default: nil
        }
        if let remoteError, !isCancelled, session?.failure == nil {
            session?.failure = remoteError
        }
        let message = remoteError?.errorDescription
            ?? (error is CancellationError ? "The operation was cancelled." : SSHConnection.describe(error))
        clibgit2_set_error(message)
        return error is CancellationError ? GIT_EUSER.rawValue : -1
    }

    private func hostName(_ url: String) -> String {
        (try? SSHAddress(url))?.host ?? ""
    }
}
