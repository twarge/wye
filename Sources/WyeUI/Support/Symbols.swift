import SwiftUI

extension ImageResource {
    /// A branching diagram: a commit with a trunk and a branch curving off
    /// it. A custom symbol in the app's asset catalog, written by
    /// scripts/make-branch-symbol.swift.
    static let branch = ImageResource(name: "git.branch", bundle: .main)
}
