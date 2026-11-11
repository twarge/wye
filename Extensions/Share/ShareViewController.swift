import SwiftUI
import TwigShared
import UIKit
import UniformTypeIdentifiers

/// "Clone in Twig" in the share sheet, for a link or text with a git
/// address in it. A share extension cannot open its app, so this leaves the
/// address for Twig, which shows its clone sheet with it the next time it
/// comes to the front.
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareView(model: model) { [weak self] in
            self?.finish()
        })
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)

        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        Task { await model.read(providers) }
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

@MainActor
@Observable
final class ShareModel {
    enum State {
        case reading
        /// An address to clone, not yet handed over.
        case found(String)
        /// Handed over; Twig picks it up when opened.
        case handedOver(String)
        case nothingFound
        case failed(String)
    }

    var state = State.reading

    func read(_ providers: [NSItemProvider]) async {
        var texts: [String] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                texts.append(url.absoluteString)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                texts.append(text)
            }
        }
        if let address = texts.lazy.compactMap(RemoteAddressFinder.firstAddress(in:)).first {
            state = .found(address)
        } else {
            state = .nothingFound
        }
    }

    func handOver(_ address: String) {
        do {
            try PendingClone.leave(address)
            state = .handedOver(address)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

struct ShareView: View {
    let model: ShareModel
    var done: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                switch model.state {
                case .reading:
                    ProgressView()
                case .found(let address):
                    Section {
                        Text(address)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                    } footer: {
                        Text("Twig shows its clone sheet with this address the next time you open it.")
                    }
                case .handedOver(let address):
                    Section {
                        Label("Open Twig to finish cloning.", systemImage: "checkmark.circle")
                        Text(address)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    }
                case .nothingFound:
                    Text("There is no git repository address in what was shared.")
                case .failed(let message):
                    Text(message)
                }
            }
            .navigationTitle("Clone in Twig")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if case .handedOver = model.state {
                        EmptyView()
                    } else {
                        Button("Cancel", role: .cancel, action: done)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    switch model.state {
                    case .found(let address):
                        Button("Clone") { model.handOver(address) }
                    case .handedOver:
                        Button("Done", action: done)
                    default:
                        EmptyView()
                    }
                }
            }
        }
    }
}
