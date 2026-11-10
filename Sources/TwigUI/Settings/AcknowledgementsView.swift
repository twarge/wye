import SwiftUI

/// The software Twig is built from and the licences it comes under.
///
/// The texts are the ones `scripts/copy-third-party-licenses.sh` copies into
/// the app bundle from the libgit2 submodule, read back here rather than
/// repeated in code, so what is shown is exactly what ships.
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
                Text("Twig is free software under the Apache License 2.0. It includes the following software, used unmodified.")
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
        )
    ]

    var text: String {
        guard let url = Bundle.main.resourceURL?.appending(path: "ThirdPartyLicenses/\(file)"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return "The license text is missing from this build. It is in the Vendor/libgit2 folder of Twig's source."
        }
        guard let section, let start = contents.range(of: section) else {
            return contents
        }
        let rest = contents[start.lowerBound...]
        let end = rest.range(of: "\n-----")?.lowerBound ?? rest.endIndex
        return String(rest[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
