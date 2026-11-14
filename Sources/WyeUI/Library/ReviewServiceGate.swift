import Foundation

/// What keeps the repository list polite to hosting services, whatever it
/// asks them: a few requests at a time however many repositories are
/// listed, and a service that failed left alone for a while. Nothing the
/// list asks is needed to show it, so nothing is said of a failure: what
/// the service last answered, if anything, stands.
@MainActor
final class ReviewServiceGate {
    /// How many more requests may start now, and the ones waiting to.
    private var free: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// Until when a question, by its own key, or everything an account
    /// asks, by the account's id, is left alone after a failure.
    private var heldOff: [String: Date] = [:]
    /// See `accountsChanged(to:)`.
    private var accountChangesSeen: Int?
    private let now: @Sendable () -> Date

    init(concurrentRequests: Int, now: @escaping @Sendable () -> Date = { .now }) {
        free = max(1, concurrentRequests)
        self.now = now
    }

    // MARK: A few at a time

    /// Waits for one of the few requests allowed at once.
    func enter() async {
        if free > 0 {
            free -= 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Lets the next request waiting start.
    func leave() {
        if waiting.isEmpty {
            free += 1
        } else {
            waiting.removeFirst().resume()
        }
    }

    // MARK: Failures

    /// Whether a question, or the account that asks it, is being left alone.
    func isHeldOff(_ question: String, account: UUID) -> Bool {
        let date = now()
        return [question, account.uuidString].contains { key in
            heldOff[key].map { $0 > date } ?? false
        }
    }

    /// Leaves a question alone for a while after it failed, and everything
    /// its account asks where the failure is the account's or the
    /// network's: the next repository would only fail the same way.
    func holdOff(_ question: String, account: UUID, after error: any Error) {
        let date = now()
        let account = account.uuidString
        switch error as? HostingError {
        case .offline:
            heldOff[account] = date.addingTimeInterval(30)
        case .rateLimited(_, let reset):
            heldOff[account] = date.addingTimeInterval(max(60, reset.map { $0.timeIntervalSince(date) } ?? 5 * 60))
        case .unauthorized, .noAccount:
            heldOff[account] = date.addingTimeInterval(15 * 60)
        case .forbidden, .notFound, .unsupported, .rejected:
            // This repository's alone: the account may not see it, or its service has no such list.
            heldOff[question] = date.addingTimeInterval(15 * 60)
        default:
            heldOff[question] = date.addingTimeInterval(2 * 60)
        }
    }

    /// Takes how many times the accounts have changed, as
    /// `AccountChangeCounter` counts them. When that is more than it was,
    /// the services that failed are asked again: an account was added, or
    /// signed in again, and may be let in now.
    func accountsChanged(to count: Int) {
        if let seen = accountChangesSeen, seen != count { heldOff = [:] }
        accountChangesSeen = count
    }
}
