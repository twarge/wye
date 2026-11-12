import SwiftUI
import TipKit

/// The few things in Wye that nothing on screen gives away, each said once
/// where it applies and never again once it has been done.
enum WyeTips {
    /// Sets tips up, a day apart at most so they never pile up. Call once,
    /// as the app starts. Not while testing: there is no one to tell.
    @MainActor
    static func configure() {
        guard NSClassFromString("XCTestCase") == nil else { return }
        try? Tips.configure([.displayFrequency(.daily)])
    }
}

/// On the history: commits can be dragged.
struct DragCommitTip: Tip {
    /// Donated when something is dropped on the sidebar: the tip has no
    /// more to say to someone who already does it.
    static let dropped = Tips.Event(id: "sidebar.dropped")

    var title: Text { Text("Drag Commits to Use Them") }
    var message: Text? {
        Text("Drop a commit on a branch to cherry-pick it, on Branches or Tags to name it, or outside Wye to get it as a patch file.")
    }
    var image: Image? { Image(systemName: "hand.draw") }

    var rules: [Rule] {
        #Rule(Self.dropped) { $0.donations.count == 0 }
    }
    var options: [any TipOption] { [Tips.MaxDisplayCount(3)] }
}

/// On the repository list's picker: there is a Review.
struct ReviewTip: Tip {
    static let reviewed = Tips.Event(id: "library.reviewed")

    var title: Text { Text("Review Everything at Once") }
    var message: Text? {
        Text("Review lists what is not committed or pushed in every repository, so nothing is left only on this device.")
    }
    var image: Image? { Image(systemName: "tray.full") }

    var rules: [Rule] {
        #Rule(Self.reviewed) { $0.donations.count == 0 }
    }
    var options: [any TipOption] { [Tips.MaxDisplayCount(2)] }
}

/// On a diff in the working copy: single lines can be staged.
struct StageLinesTip: Tip {
    static let selected = Tips.Event(id: "diff.lineSelected")

    var title: Text { Text("Stage Line by Line") }
    var message: Text? {
        Text("Select changed lines in a diff, then stage or discard only those from the menu of any of them.")
    }
    var image: Image? { Image(systemName: "text.line.first.and.arrowtriangle.forward") }

    var rules: [Rule] {
        #Rule(Self.selected) { $0.donations.count == 0 }
    }
    var options: [any TipOption] { [Tips.MaxDisplayCount(3)] }
}
