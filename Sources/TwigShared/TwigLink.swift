import Foundation

/// A `twig://` link: how the widget, the share extension, Services and
/// Shortcuts ask the app to do something. The app handles each in
/// `onOpenURL`.
///
/// - `twig://open?repository=<id>` opens a repository from the list.
/// - `twig://clone?url=<address>` shows the clone sheet with the address
///   filled in.
public enum TwigLink: Hashable, Sendable {
    /// A repository in the list, by its bookmark id.
    case openRepository(UUID)
    /// The clone sheet, with this remote address in it.
    case clone(String)

    public static let scheme = "twig"

    /// Reads a link, or returns `nil` for any URL that is not one of
    /// Twig's (a folder dropped on the app, say).
    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // `twig://open?…` has the action as its host; `twig:open?…` as its path.
        let action = (components.host ?? components.path).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        func value(_ name: String) -> String? {
            components.queryItems?.first { $0.name.lowercased() == name }?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        switch action {
        case "open":
            guard let id = value("repository").flatMap(UUID.init(uuidString:)) else { return nil }
            self = .openRepository(id)
        case "clone":
            guard let address = value("url"), !address.isEmpty else { return nil }
            self = .clone(address)
        default:
            return nil
        }
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        let (action, name, value) = switch self {
        case .openRepository(let id): ("open", "repository", id.uuidString)
        case .clone(let address): ("clone", "url", address)
        }
        components.host = action
        // `queryItems` would leave `&` and `=` in an address as they are,
        // which would split it on the way back.
        components.percentEncodedQuery = name + "=" + (value.addingPercentEncoding(withAllowedCharacters: Self.valueCharacters) ?? value)
        return components.url!
    }

    private static let valueCharacters = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#"))
}
