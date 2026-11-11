import Foundation
import Testing

/// The licence texts the app ships for its Swift packages, kept in
/// Vendor/ThirdPartyLicenses, against the packages themselves.
@Suite struct ThirdPartyLicenseTests {
    static let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let copies = root.appending(path: "Vendor/ThirdPartyLicenses")
    /// Resolved for the packages above, but not linked into the app: swift-system
    /// serves only SwiftNIO's file system module, swift-asn1 only Swift Crypto's extras.
    static let notLinked: Set<String> = ["swift-system", "swift-asn1"]

    @Test func everyResolvedPackageHasItsLicence() throws {
        let resolved = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.root.appending(path: "Package.resolved")))
        let pins = ((resolved as? [String: Any])?["pins"] as? [[String: Any]]) ?? []
        let identities = Set(pins.compactMap { $0["identity"] as? String })
        let copied = Set(try Self.visible(in: Self.copies))
        #expect(copied == identities.subtracting(Self.notLinked))
    }

    /// Wherever SwiftPM has checked a package out, its files match the copies.
    @Test func theCopiesMatchThePackages() throws {
        let build = Self.root.appending(path: ".build")
        let checkouts = ((try? FileManager.default.contentsOfDirectory(atPath: build.path)) ?? [])
            .flatMap { [build.appending(path: "\($0)/checkouts"), build.appending(path: "\($0)/SourcePackages/checkouts")] }
            + [build.appending(path: "checkouts")]
        for package in try Self.visible(in: Self.copies) {
            for file in try Self.visible(in: Self.copies.appending(path: package)) {
                let copy = try Data(contentsOf: Self.copies.appending(path: "\(package)/\(file)"))
                for checkout in checkouts {
                    let original = checkout.appending(path: "\(package)/\(file)")
                    guard let data = try? Data(contentsOf: original) else { continue }
                    #expect(data == copy, "\(original.path) differs from Vendor/ThirdPartyLicenses")
                }
            }
        }
    }

    private static func visible(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") }
    }
}
