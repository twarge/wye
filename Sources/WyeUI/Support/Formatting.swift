import Foundation
import GitKit

extension Signature {
    /// Up to two initials, for the round badge that stands in for a portrait.
    var initials: String {
        let words = name.split(whereSeparator: \.isWhitespace)
        let letters = [words.first, words.count > 1 ? words.last : nil].compactMap { $0?.first }
        return String(letters).uppercased()
    }

    /// `Name <email>`, as git writes it.
    var nameAndEmail: String {
        email.isEmpty ? name : "\(name) <\(email)>"
    }
}

extension String {
    /// The last path component and the folder before it, for a row that shows
    /// the file name first.
    var splitPath: (name: String, folder: String) {
        guard let slash = lastIndex(of: "/") else { return (self, "") }
        return (String(self[index(after: slash)...]), String(self[..<slash]))
    }
}
