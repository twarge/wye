import Foundation
import GitKit
import Observation

/// Something the user should know that does not stop them working: an
/// operation that failed, or what one left behind. Shown in a strip in the
/// window, never in an alert, so the window stays usable while it stands.
struct Notice: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// What was asked for did not happen.
        case failure
        /// It happened, with something left for the user to see to.
        case warning
        case information
        /// It happened, and there is a next step on offer. Goes by itself
        /// after a while.
        case success
    }

    /// What the user can do about it, as a button on the notice. The window
    /// showing the notice decides which of them it can carry out.
    enum Recovery: Hashable, Sendable {
        case pull
        case fetch
        case showWorkingCopy
        case manageRemotes
        /// The app's settings: identity, accounts and SSH keys.
        case settings
        case showActivity
        case open(URL, title: String)
        /// Drops the undo record that could not be applied, and those
        /// beyond it.
        case forgetUndo

        var title: String {
            switch self {
            case .pull: "Pull"
            case .fetch: "Fetch"
            case .showWorkingCopy: "Show Working Copy"
            case .manageRemotes: "Manage Remotes"
            case .settings: "Open Settings"
            case .showActivity: "Show Activity"
            case .open(_, let title): title
            case .forgetUndo: "Forget It"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    var title: String
    var message: String
    /// More than the message has room for: what the server said, mostly.
    var detail: String?
    var recoveries: [Recovery] = []
    /// The operation it is about, as the activity log names it. A later
    /// success of the same operation takes the notice away.
    var operation: String?
    /// How many times the same thing was said, when more than once.
    var count = 1

    init(
        _ kind: Kind = .information, title: String, message: String, detail: String? = nil,
        recoveries: [Recovery] = [], operation: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.message = message
        self.detail = detail
        self.recoveries = recoveries
        self.operation = operation
    }

    /// A failure, named after the operation that failed when it is known,
    /// with whatever the error suggests doing about it.
    init(_ error: any Error, during operation: String? = nil, detail: String? = nil) {
        self.init(
            .failure, title: NoticeText.failureTitle(for: operation), message: error.localizedDescription,
            detail: detail, recoveries: NoticeText.recoveries(for: error), operation: operation
        )
    }

    /// Whether two notices say the same thing, whenever they were made.
    func says(_ other: Notice) -> Bool {
        kind == other.kind && title == other.title && message == other.message
    }
}

/// The wording and recoveries of failures: pure, so it can be tested.
enum NoticeText {
    /// "Couldn’t Push" for "Push"; a plain title when the operation has no
    /// name of its own.
    static func failureTitle(for operation: String?) -> String {
        guard let operation, !operation.isEmpty, operation != "Operation" else { return "That Didn’t Work" }
        return "Couldn’t \(operation)"
    }

    static func recoveries(for error: any Error) -> [Notice.Recovery] {
        switch error {
        case let error as RemoteError:
            switch error {
            case .nonFastForward, .cannotFastForward: [.pull]
            case .remoteMoved: [.fetch]
            case .credentialsRequired, .credentialsRejected, .sshKeyRequired, .sshKeysRejected: [.settings]
            case .noRemotes, .remoteNotFound: [.manageRemotes]
            default: []
            }
        case let error as RepositoryError:
            switch error {
            case .identityNotConfigured: [.settings]
            case .nothingToCommit, .operationInProgress: [.showWorkingCopy]
            case .noWorkingDirectory: []
            }
        case let error as GitError where error.isBlockedByLocalChanges:
            [.showWorkingCopy]
        default:
            []
        }
    }
}

/// The notices standing in one window, most recent first. A value, so its
/// rules can be tested without a window.
struct NoticeQueue: Hashable, Sendable {
    private(set) var notices: [Notice] = []
    /// As many as stand at once; older ones make room.
    var capacity = 6

    /// Adds a notice at the front. One that says what a standing notice
    /// says takes its place and counts once more, so a failure repeated
    /// does not pile up.
    mutating func post(_ notice: Notice) {
        var notice = notice
        if let index = notices.firstIndex(where: { $0.says(notice) }) {
            notice.count = notices[index].count + 1
            notices.remove(at: index)
        }
        notices.insert(notice, at: 0)
        if notices.count > capacity {
            notices.removeLast(notices.count - capacity)
        }
    }

    mutating func dismiss(_ id: Notice.ID) {
        notices.removeAll { $0.id == id }
    }

    mutating func dismissAll() {
        notices.removeAll()
    }

    /// An operation succeeded: what was said about its earlier failures no
    /// longer holds.
    mutating func resolve(operation: String) {
        notices.removeAll { ($0.kind == .failure || $0.kind == .warning) && $0.operation == operation }
    }
}

/// One window's notices, for its strip to show.
@MainActor
@Observable
final class NoticeCenter {
    private(set) var queue = NoticeQueue()
    /// Counts the failures posted, so that whoever started something can
    /// tell afterwards whether it went wrong.
    private(set) var failuresPosted = 0

    var notices: [Notice] { queue.notices }

    func post(_ notice: Notice) {
        if notice.kind == .failure { failuresPosted += 1 }
        queue.post(notice)
    }

    func post(_ error: any Error, during operation: String? = nil) {
        // Cancelled by the user, who knows.
        guard !(error is CancellationError) else { return }
        post(Notice(error, during: operation))
    }

    func dismiss(_ id: Notice.ID) {
        queue.dismiss(id)
    }

    func dismissAll() {
        queue.dismissAll()
    }

    func resolve(operation: String) {
        queue.resolve(operation: operation)
    }
}
