import SwiftUI

extension View {
    /// Shows a window's notices in a strip at its top, over the content and
    /// out of its way: nothing waits for them to be dismissed. `model` is
    /// the repository the window shows, for the recoveries that act on one.
    /// `also` is a second set shown above them: the window's own, where the
    /// strip is a repository's.
    func noticeStrip(_ center: NoticeCenter, model: RepositoryModel? = nil, also: NoticeCenter? = nil) -> some View {
        modifier(NoticeStripModifier(center: center, model: model, also: also))
    }

    /// A repository's notices at the bottom of a sheet over its window,
    /// which hides the window's own strip.
    func sheetNotices(_ model: RepositoryModel) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            NoticeStrip(center: model.notices, model: model, isFloating: false)
                .padding(.horizontal, 12)
                .padding(.vertical, model.notices.notices.isEmpty ? 0 : 8)
        }
    }

    /// Shows one notice at the bottom of a sheet or a settings pane while
    /// `notice` is set, where an alert used to stop everything.
    func notice(for notice: Binding<Notice?>) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            if let standing = notice.wrappedValue {
                NoticeCard(notice: standing, model: nil, isFloating: false) {
                    withMotion { notice.wrappedValue = nil }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onAppear { standing.announce() }
            }
        }
    }
}

struct NoticeStripModifier: ViewModifier {
    var center: NoticeCenter
    var model: RepositoryModel?
    var also: NoticeCenter?
    /// For a place that carries the strip only in some layouts.
    var isShown = true

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if isShown {
                VStack(spacing: 6) {
                    if let also {
                        NoticeStrip(center: also, model: nil)
                    }
                    NoticeStrip(center: center, model: model)
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }
        }
    }
}

/// A notice as a row of the form it is about, where a settings section
/// used to raise an alert. Nothing while there is none.
struct NoticeRow: View {
    @Binding var notice: Notice?

    var body: some View {
        if let notice {
            NoticeCard(notice: notice, model: nil, isFloating: false) {
                withMotion { self.notice = nil }
            }
            .onAppear { notice.announce() }
        }
    }
}

/// The notices of one window: the latest in full, and the rest behind a
/// count until asked for.
private struct NoticeStrip: View {
    var center: NoticeCenter
    var model: RepositoryModel?
    var isFloating = true

    @State private var showsAll = false

    var body: some View {
        let notices = center.notices
        VStack(spacing: 6) {
            ForEach(showsAll ? notices : Array(notices.prefix(1))) { notice in
                NoticeCard(notice: notice, model: model, isFloating: isFloating) {
                    center.dismiss(notice.id)
                }
                .transition(.move(edge: isFloating ? .top : .bottom).combined(with: .opacity))
                .task(id: notice.id) {
                    notice.announce()
                    // Good news does not need dismissing.
                    guard notice.kind == .success else { return }
                    try? await Task.sleep(for: .seconds(12))
                    guard !Task.isCancelled else { return }
                    center.dismiss(notice.id)
                }
            }
            if notices.count > 1 {
                HStack(spacing: 12) {
                    Button(showsAll ? "Show Latest Only" : "\(notices.count - 1) More") {
                        withMotion { showsAll.toggle() }
                    }
                    Button("Dismiss All") { center.dismissAll() }
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
        }
        .animation(Platform.reducesMotion ? nil : .snappy, value: notices.map(\.id))
        .onChange(of: notices.count) {
            if notices.count < 2 { showsAll = false }
        }
    }
}

private extension Notice {
    /// Says the notice to VoiceOver as it appears, since nothing takes focus.
    func announce() {
        AccessibilityNotification.Announcement("\(title). \(message)").post()
    }

    var symbol: String {
        switch kind {
        case .failure: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .information: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        }
    }

    var tint: Color {
        switch kind {
        case .failure: .red
        case .warning: .orange
        case .information: .accentColor
        case .success: .green
        }
    }
}

/// One notice: what happened, what can be done about it, and a way to
/// send it off.
private struct NoticeCard: View {
    var notice: Notice
    var model: RepositoryModel?
    /// Over the window's content, on glass; or part of a sheet's layout.
    var isFloating: Bool
    var dismiss: () -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.openWindow) private var openWindow
    @Environment(WindowActions.self) private var actions: WindowActions?
    @State private var showsDetail = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: notice.symbol)
                .foregroundStyle(notice.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(notice.title)
                        .font(.headline)
                    if notice.count > 1 {
                        Text("×\(notice.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("\(notice.count) times")
                    }
                }
                Text(notice.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if showsDetail, let detail = notice.detail {
                    ScrollView {
                        Text(detail)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                }
                if !buttons.isEmpty || notice.detail != nil {
                    HStack(spacing: 8) {
                        ForEach(buttons, id: \.self) { recovery in
                            Button(recovery.title) {
                                perform(recovery)
                            }
                        }
                        if notice.detail != nil {
                            Button(showsDetail ? "Hide Details" : "Show Details") {
                                withMotion { showsDetail.toggle() }
                            }
                        }
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Dismiss")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(NoticeSurface(tint: notice.tint, isFloating: isFloating))
        .accessibilityElement(children: .contain)
    }

    /// The recoveries this place can carry out: those that act on a
    /// repository need one.
    private var buttons: [Notice.Recovery] {
        notice.recoveries.filter { recovery in
            switch recovery {
            case .pull, .fetch, .showWorkingCopy, .manageRemotes, .forgetUndo: model != nil
            case .settings, .showActivity, .open: true
            }
        }
    }

    private func perform(_ recovery: Notice.Recovery) {
        switch recovery {
        case .pull:
            Task { await model?.pull() }
        case .fetch:
            Task { await model?.fetch() }
        case .showWorkingCopy:
            model?.selection = .workingCopy
        case .manageRemotes:
            model?.remotes.isManagingRemotes = true
        case .forgetUndo:
            if let refusal = model?.undoStack.refusal {
                model?.undoStack.forget(refusal.record)
                model?.undoStack.refusal = nil
            }
        case .settings:
            SettingsFocus.shared.show()
        case .showActivity:
            if Platform.hasAuxiliaryWindows {
                openWindow(id: WyeScene.activityWindowID)
            } else {
                actions?.isShowingActivity = true
            }
        case .open(let url, _):
            openURL(url)
        }
        // Acted on: it has said what it had to. A link stays, to go back to.
        if case .open = recovery { return }
        dismiss()
    }
}

private struct NoticeSurface: ViewModifier {
    var tint: Color
    var isFloating: Bool

    func body(content: Content) -> some View {
        if isFloating {
            content
                .glassEffect(.regular.tint(tint.opacity(0.12)), in: .rect(cornerRadius: 16))
        } else {
            content
                .background(tint.opacity(0.1), in: .rect(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.25))
                }
        }
    }
}
