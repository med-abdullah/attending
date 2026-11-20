import AppKit
import SwiftUI
import AttendingCore

/// One session: what it is, where it runs, and a way back to it. Codex sessions Attending
/// started also take instructions here.
struct SessionDetail: View {
    @ObservedObject var model: AppModel
    let session: AgentSession
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { model.selectedSessionID = nil; model.draft = "" } label: {
                Label("Agents", systemImage: "chevron.left").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
            }.buttonStyle(.plain)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            SessionRow(session: session, compact: false)
                            HStack(spacing: 8) {
                                Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                                Text(session.projectPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.middle)
                            }
                            HStack(spacing: 8) {
                                if let app = providerApp {
                                    PillButton(title: "Open \(app.name)", symbol: "arrow.up.forward.app", prominent: true) { app.open() }
                                }
                                PillButton(title: "Show folder", symbol: "folder") { NSWorkspace.shared.open(URL(fileURLWithPath: session.projectPath, isDirectory: true)) }
                            }
                        }
                    }
                    if model.canSendToSelected { instructions }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.scrollIndicators(.never)
        }
    }

    private var instructions: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Send an instruction")
                TextField("Ask Codex to…", text: $model.draft, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(2...5).focused($focused)
                    .padding(10).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.raised))
                    .onSubmit(model.sendDraft)
                HStack(spacing: 8) {
                    PillButton(title: "Send", symbol: "arrow.up", tint: Theme.done, prominent: true, action: model.sendDraft)
                        .disabled(model.codexBusy || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if model.codexTurns[session.externalID] != nil { PillButton(title: "Stop", symbol: "stop.fill", tint: Theme.failed, action: model.stopSelectedTurn) }
                    if model.codexBusy { ProgressView().controlSize(.small) }
                }
                if let response = model.responseText[session.externalID], !response.isEmpty {
                    Text(response).font(.system(size: 12)).foregroundStyle(Theme.secondary).textSelection(.enabled)
                }
                Text("Uses your Codex sign-in. Commands still follow Codex's sandbox and approval settings.")
                    .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
            }
        }
        .onAppear { focused = true }
    }

    /// The app the session lives in, when it's installed.
    private var providerApp: (name: String, open: () -> Void)? {
        let candidates: [(String, String)] = session.provider == .claudeCode
            ? [("com.anthropic.claudefordesktop", "Claude")]
            : [("com.openai.codex", "Codex"), ("com.openai.chat", "ChatGPT")]
        let running = NSWorkspace.shared.runningApplications
        if let (id, name) = candidates.first(where: { candidate in running.contains { $0.bundleIdentifier == candidate.0 } }) {
            return (name, { running.first { $0.bundleIdentifier == id }?.activate() })
        }
        if let (id, name) = candidates.first(where: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.0) != nil }),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return (name, { NSWorkspace.shared.openApplication(at: url, configuration: .init()) })
        }
        return nil
    }
}
struct ApprovalInbox: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Waiting for you")
            ForEach(model.claudeApprovals) { request in
                if let questions = ProviderQuestion.parse(toolName: request.toolName, inputJSON: request.toolInputJSON) {
                    QuestionCard(model: model, request: request, questions: questions)
                } else if request.toolName == "ExitPlanMode" {
                    approvalCard {
                        header(request, title: "Plan ready for review")
                        if let plan = (try? JSONSerialization.jsonObject(with: Data(request.toolInputJSON.utf8)) as? [String: Any])?["plan"] as? String {
                            ScrollView {
                                Text(plan).font(.system(size: 12)).foregroundStyle(Theme.secondary).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 220)
                            .padding(10).background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.raised))
                        }
                        HStack {
                            PillButton(title: "Approve plan", symbol: "checkmark", tint: Theme.done, prominent: true) { model.respondClaude(request, decision: .allowOnce) }
                            PillButton(title: "Keep planning", symbol: "pencil") { model.respondClaude(request, decision: .deny) }
                            Spacer()
                            answerInClaude(request)
                        }
                    }
                } else {
                    approvalCard {
                        header(request, title: request.provider == .codex && request.command != nil ? "Wants to run a command" : "Wants to use \(request.toolName)")
                        // Complete input remains inspectable; no truncation hidden behind Allow.
                        if request.provider == .codex, let command = request.command {
                            code(command)
                            DisclosureGroup("Complete request") { code(request.toolInputJSON) }.font(.system(size: 11))
                        } else {
                            code(request.toolInputJSON)
                        }
                        Text("This allows this one request. Check the full action and target first.").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                        HStack {
                            PillButton(title: "Deny", symbol: "xmark", tint: Theme.failed) { model.respondClaude(request, decision: .deny) }
                            PillButton(title: "Allow Once", symbol: "checkmark", tint: Theme.done, prominent: true) { model.respondClaude(request, decision: .allowOnce) }
                            if request.provider == .codex {
                                Spacer()
                                Button("Answer in Codex") { model.respondClaude(request, decision: .askInProvider) }
                                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary)
                            }
                        }
                    }
                }
            }
            ForEach(model.codexApprovals, id: \.id) { request in
                approvalCard {
                    Text("Codex permission request").font(.system(size: 14, weight: .semibold))
                    Text(request.cwd ?? "See requested action").font(.system(size: 10)).foregroundStyle(Theme.tertiary).textSelection(.enabled)
                    Text("Session \(request.threadID.prefix(12)) · Turn \(request.turnID.prefix(12))").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                    if let reason = request.reason { Text(reason).font(.system(size: 12)) }
                    DisclosureGroup("Complete request and scope") { code(request.contextJSON) }.font(.system(size: 11))
                    if let command = request.command { code(command) }
                    if let diff = request.diff { code(diff) }
                    if let explanation = request.unavailableReason { Text(explanation).font(.system(size: 11)).foregroundStyle(Theme.attention) }
                    HStack {
                        PillButton(title: "Deny", symbol: "xmark", tint: Theme.failed) { model.respondCodex(request, decision: .deny) }.disabled(!request.availableDecisions.contains(.deny))
                        if request.availableDecisions.contains(.cancel) { PillButton(title: "Cancel turn", symbol: nil) { model.respondCodex(request, decision: .cancel) } }
                        PillButton(title: "Allow Once", symbol: "checkmark", tint: Theme.done, prominent: true) { model.respondCodex(request, decision: .allowOnce) }.disabled(!request.canAllow)
                    }
                }
            }
        }
    }
    private func header(_ request: ApprovalRequest, title: String) -> some View {
        RequestHeader(model: model, request: request, title: title)
    }
    private func answerInClaude(_ request: ApprovalRequest) -> some View {
        Button("Answer in Claude") { model.respondClaude(request, decision: .askInProvider) }
            .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary)
    }
    private func approvalCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.attention.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.attention.opacity(0.35), lineWidth: 1))
    }
    private func code(_ text: String) -> some View {
        Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.5)))
    }
}

/// Which session is asking, and how long the notch can still answer before Claude asks itself.
struct RequestHeader: View {
    @ObservedObject var model: AppModel
    let request: ApprovalRequest
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, Int(request.expiresAt.timeIntervalSince(context.date)))
                    Text("\(left)s").font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
                        .foregroundStyle(left <= 10 ? Theme.attention : Theme.tertiary)
                        .help("After this, \(request.provider.title) asks in its own window")
                }
            }
            Text("\(request.provider.title) · \(model.state.sessions.first { $0.id == request.provider.rawValue + ":" + request.sessionID }?.title ?? SessionNaming.folderTitle(request.projectPath))")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
        }
    }
}

/// Claude's multiple-choice questions (AskUserQuestion), answered from the notch.
struct QuestionCard: View {
    @ObservedObject var model: AppModel
    let request: ApprovalRequest
    let questions: [ProviderQuestion]
    @State private var picked: [String: Set<String>] = [:]
    @State private var other: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RequestHeader(model: model, request: request, title: questions.count == 1 ? "Claude has a question" : "Claude has \(questions.count) questions")
            ForEach(questions) { question in
                VStack(alignment: .leading, spacing: 6) {
                    if let header = question.header, !header.isEmpty { SectionLabel(text: header) }
                    Text(question.text).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    ForEach(question.options, id: \.self) { option in optionRow(option, in: question) }
                    TextField(question.multiSelect ? "Something else (optional)" : "Or type your own answer", text: Binding(get: { other[question.text] ?? "" }, set: { other[question.text] = $0; if !$0.isEmpty && !question.multiSelect { picked[question.text] = [] } }))
                        .textFieldStyle(.plain).font(.system(size: 12))
                        .padding(.horizontal, 10).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.raised))
                }
            }
            HStack {
                PillButton(title: "Send", symbol: "arrow.up", tint: Theme.done, prominent: true) { model.respondClaude(request, decision: .allowOnce, answers: answers) }
                    .disabled(answers.count < questions.count)
                Spacer()
                Button("Answer in Claude") { model.respondClaude(request, decision: .askInProvider) }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.tertiary)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.attention.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.attention.opacity(0.35), lineWidth: 1))
    }

    private func optionRow(_ option: ProviderQuestion.Option, in question: ProviderQuestion) -> some View {
        let selected = picked[question.text, default: []].contains(option.label)
        return Button {
            var set = picked[question.text, default: []]
            if question.multiSelect { if selected { set.remove(option.label) } else { set.insert(option.label) } }
            else { set = selected ? [] : [option.label]; other[question.text] = nil }
            picked[question.text] = set
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: question.multiSelect ? (selected ? "checkmark.square.fill" : "square") : (selected ? "largecircle.fill.circle" : "circle"))
                    .font(.system(size: 14)).foregroundStyle(selected ? Theme.done : Theme.tertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.primary)
                    if let detail = option.detail { Text(detail).font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Theme.done.opacity(0.12) : Theme.raised))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    /// Question text to the chosen labels (in the order offered), plus any typed answer.
    private var answers: [String: String] {
        var result: [String: String] = [:]
        for question in questions {
            var parts = question.options.map(\.label).filter { picked[question.text, default: []].contains($0) }
            if let typed = other[question.text]?.trimmingCharacters(in: .whitespacesAndNewlines), !typed.isEmpty { parts.append(typed) }
            if !parts.isEmpty { result[question.text] = parts.joined(separator: ", ") }
        }
        return result
    }
}
