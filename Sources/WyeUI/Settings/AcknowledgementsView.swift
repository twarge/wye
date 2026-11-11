import SwiftUI

/// The software Wye is built from and the licences it comes under.
///
/// The texts are the ones `scripts/copy-third-party-licenses.sh` copies into
/// the app bundle from the libgit2 submodule and Vendor/ThirdPartyLicenses,
/// read back here rather than repeated in code, so what is shown is exactly
/// what ships.
struct AcknowledgementsButton: View {
    @State private var isPresented = false

    var body: some View {
        Button("Acknowledgements") { isPresented = true }
            .sheet(isPresented: $isPresented) {
                NavigationStack {
                    AcknowledgementsView()
                        .navigationTitle("Acknowledgements")
                        #if os(iOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { isPresented = false }
                            }
                        }
                }
                .sheetMinimumSize(width: 560, height: 520)
            }
    }
}

struct AcknowledgementsView: View {
    var body: some View {
        List {
            Section {
                Text("Wye is free software under the Apache License 2.0. It includes the following software, used unmodified.")
                    .foregroundStyle(.secondary)
            }
            ForEach(Acknowledgement.all) { item in
                Section {
                    Text(item.summary)
                    DisclosureGroup("License") {
                        Text(item.text)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } header: {
                    Text(item.name)
                }
            }
        }
    }
}

struct Acknowledgement: Identifiable {
    var name: String
    var summary: String
    /// The file under `ThirdPartyLicenses/` in the app's resources.
    var file: String
    /// Where this component's part of a shared file begins. The text runs from
    /// there to the next rule of dashes, which is how libgit2's COPYING
    /// separates its notices.
    var section: String?
    /// An Apache licence's NOTICE file, shown after the licence.
    var notice: String?

    var id: String { name }

    static let all = [
        Acknowledgement(
            name: "libgit2",
            summary: "The git engine, compiled into the app. Licensed under the GNU General Public License version 2 with a linking exception. The full file also carries the notices for the code libgit2 includes.",
            file: "libgit2/COPYING"
        ),
        Acknowledgement(
            name: "xdiff",
            summary: "The diff algorithm, part of libgit2 (LibXDiff by Davide Libenzi). Licensed under the GNU Lesser General Public License version 2.1.",
            file: "libgit2/COPYING",
            section: "GNU LESSER GENERAL PUBLIC LICENSE"
        ),
        Acknowledgement(
            name: "SHA-1 collision detection",
            summary: "Detects forged SHA-1 hashes, part of libgit2 (Marc Stevens and Dan Shumow). Licensed under the MIT License.",
            file: "libgit2/COPYING",
            section: "The bundled SHA1 collision detection code"
        ),
        Acknowledgement(
            name: "llhttp",
            summary: "The HTTP parser, part of libgit2 (Fedor Indutny). Licensed under the MIT License.",
            file: "llhttp/LICENSE-MIT"
        ),
        Acknowledgement(
            name: "SwiftNIO SSH",
            summary: "The SSH protocol, for SSH remotes (Apple Inc. and the SwiftNIO project authors). Licensed under the Apache License 2.0.",
            file: "swift-nio-ssh/LICENSE.txt"
        ),
        Acknowledgement(
            name: "SwiftNIO",
            summary: "The networking framework SSH runs on (Apple Inc. and the SwiftNIO project authors). Licensed under the Apache License 2.0.",
            file: "swift-nio/LICENSE.txt",
            notice: "swift-nio/NOTICE.txt"
        ),
        Acknowledgement(
            name: "SwiftNIO Transport Services",
            summary: "Connects SwiftNIO to Apple’s Network framework (Apple Inc. and the SwiftNIO project authors). Licensed under the Apache License 2.0.",
            file: "swift-nio-transport-services/LICENSE.txt"
        ),
        Acknowledgement(
            name: "Swift Crypto",
            summary: "The cryptography interface SSH uses, backed by Apple’s CryptoKit (Apple Inc. and the SwiftCrypto project authors). Licensed under the Apache License 2.0.",
            file: "swift-crypto/LICENSE.txt",
            notice: "swift-crypto/NOTICE.txt"
        ),
        Acknowledgement(
            name: "Swift Atomics",
            summary: "Atomic operations, used by SwiftNIO (Apple Inc. and the Swift project authors). Licensed under the Apache License 2.0 with the Runtime Library Exception.",
            file: "swift-atomics/LICENSE.txt"
        ),
        Acknowledgement(
            name: "Swift Collections",
            summary: "Data structures, used by SwiftNIO (Apple Inc. and the Swift project authors). Licensed under the Apache License 2.0 with the Runtime Library Exception.",
            file: "swift-collections/LICENSE.txt"
        )
    ]

    var text: String {
        guard let contents = Self.contents(of: file) else {
            return "The license text is missing from this build. It is in the Vendor folder of Wye's source."
        }
        if let notice, let noticeText = Self.contents(of: notice) {
            return contents.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + noticeText
        }
        guard let section, let start = contents.range(of: section) else {
            return contents
        }
        let rest = contents[start.lowerBound...]
        let end = rest.range(of: "\n-----")?.lowerBound ?? rest.endIndex
        return String(rest[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func contents(of file: String) -> String? {
        guard let url = Bundle.main.resourceURL?.appending(path: "ThirdPartyLicenses/\(file)") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
