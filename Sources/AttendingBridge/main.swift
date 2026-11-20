import Foundation
import Darwin
import AttendingCore

private let maximumHookBytes = 1_048_576

private struct Options {
    let approvalWait: TimeInterval?

    init(arguments: [String]) {
        var result: TimeInterval?
        var index = 1
        var invalid = false
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--approval-wait" {
                if result != nil { invalid = true; break }
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                    guard let value = Double(arguments[index + 1]) else { invalid = true; break }
                    result = value
                    index += 1
                } else {
                    result = 60
                }
            } else if argument.hasPrefix("--approval-wait=") {
                if result != nil { invalid = true; break }
                guard let value = Double(argument.dropFirst("--approval-wait=".count)) else { invalid = true; break }
                result = value
            }
            index += 1
        }
        if let result, !(0.1...ApprovalWire.maximumLifetime).contains(result) { invalid = true }
        approvalWait = invalid ? nil : result
    }
}

private func recordLifecycle(_ raw: [String: Any]) {
    guard let session = raw["session_id"] as? String,
          let cwd = raw["cwd"] as? String,
          let hook = raw["hook_event_name"] as? String
    else { return }

    let kind: AgentEvent.Kind?
    switch hook {
    case "SessionStart": kind = .started
    case "UserPromptSubmit", "PreToolUse", "PostToolUse": kind = .working
    case "PermissionRequest": kind = .attention
    case "Notification": kind = raw["notification_type"] as? String == "permission_prompt" ? .attention : nil
    case "Stop": kind = .completed
    case "StopFailure": kind = .failed
    case "SessionEnd": kind = .ended
    default: kind = nil
    }
    guard let kind else { return }

    let event = AgentEvent(provider: .claudeCode, sessionID: session, projectPath: cwd, kind: kind)
    guard event.validate() else { return }
    do {
        try FileManager.default.createDirectory(
            at: AppPaths.events,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = AppPaths.events.appendingPathComponent(event.id.uuidString + ".json")
        try JSONEncoder().encode(event).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    } catch {
        // Observation failure must not affect the provider.
    }
}

/// Codex calls the bridge only for its PermissionRequest hook (its sessions are followed
/// through rollout files), so Codex runs skip lifecycle events and answer in Codex's format.
private let forCodex = CommandLine.arguments.contains("--codex")

private func makeApprovalEnvelope(_ raw: [String: Any], wait: TimeInterval) -> ApprovalEnvelope? {
    guard raw["hook_event_name"] as? String == "PermissionRequest",
          let session = raw["session_id"] as? String,
          let cwd = raw["cwd"] as? String,
          let toolName = raw["tool_name"] as? String,
          let input = raw["tool_input"] as? [String: Any],
          JSONSerialization.isValidJSONObject(input),
          let inputData = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
          inputData.count <= ApprovalWire.maximumToolInputBytes,
          let inputJSON = String(data: inputData, encoding: .utf8)
    else { return nil }

    let now = Date()
    let request = ApprovalRequest(
        provider: forCodex ? .codex : .claudeCode,
        sessionID: session,
        projectPath: cwd,
        toolName: toolName,
        toolInputJSON: inputJSON,
        command: input["command"] as? String,
        requestedAt: now,
        expiresAt: now.addingTimeInterval(wait)
    )
    guard request.validate(now: now) else { return nil }
    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    return ApprovalEnvelope(request: request, token: token)
}

private func connect(to socketURL: URL, timeout: TimeInterval) throws -> Int32 {
    let directory = socketURL.deletingLastPathComponent()
    var directoryInfo = stat()
    guard lstat(directory.path, &directoryInfo) == 0,
          (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
          directoryInfo.st_uid == geteuid(),
          directoryInfo.st_mode & 0o077 == 0
    else { throw ApprovalTransportError.invalidDirectory }

    var socketInfo = stat()
    guard lstat(socketURL.path, &socketInfo) == 0,
          (socketInfo.st_mode & S_IFMT) == S_IFSOCK,
          socketInfo.st_uid == geteuid()
    else { throw ApprovalTransportError.invalidDirectory }

    let pathBytes = Array(socketURL.path.utf8CString)
    var address = sockaddr_un()
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard pathBytes.count <= capacity else { throw ApprovalTransportError.socketPathTooLong }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
            pathBytes.withUnsafeBytes { source in
                if let base = source.baseAddress { memcpy(destination, base, pathBytes.count) }
            }
        }
    }

    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw ApprovalTransportError.systemCall("socket", errno) }
    do {
        try ApprovalWire.configure(descriptor, timeout: timeout)
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, length)
            }
        }
        guard result == 0 else { throw ApprovalTransportError.systemCall("connect", errno) }
        return descriptor
    } catch {
        Darwin.close(descriptor)
        throw error
    }
}

private func requestApproval(_ envelope: ApprovalEnvelope, wait: TimeInterval) -> ApprovalResponseEnvelope? {
    do {
        let descriptor = try connect(to: AppPaths.approvalSocket, timeout: wait)
        defer { Darwin.close(descriptor) }
        try ApprovalWire.send(envelope, to: descriptor)
        let response = try ApprovalWire.receive(ApprovalResponseEnvelope.self, from: descriptor)
        guard response.requestID == envelope.request.id,
              response.token == envelope.token,
              Date() < envelope.request.expiresAt
        else { return nil }
        return response
    } catch {
        return nil
    }
}

private func writeDecision(_ response: ApprovalResponseEnvelope, raw: [String: Any]) {
    let providerDecision: [String: Any]
    let toolName = raw["tool_name"] as? String
    if forCodex {
        // Codex rejects updatedInput and interrupt (they fail closed), so only the behavior goes back.
        switch response.decision {
        case .allowOnce: providerDecision = ["behavior": "allow"]
        case .deny: providerDecision = ["behavior": "deny", "message": "Denied in Attending."]
        case .askInProvider: return
        }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": providerDecision]]
        guard let data = try? JSONSerialization.data(withJSONObject: output) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        return
    }
    switch response.decision {
    case .allowOnce:
        var allow: [String: Any] = ["behavior": "allow"]
        // Questions and plan approvals need the input echoed back; a question also carries its answers.
        if let input = raw["tool_input"] as? [String: Any], toolName == "AskUserQuestion" || toolName == "ExitPlanMode" {
            var updated = input
            if toolName == "AskUserQuestion" {
                guard let answers = response.answers, !answers.isEmpty else { return }
                updated["answers"] = answers
            }
            allow["updatedInput"] = updated
        }
        providerDecision = allow
    case .deny:
        let message = toolName == "ExitPlanMode" ? "The user wants to keep planning. Ask what to change." : "Denied in Attending."
        providerDecision = ["behavior": "deny", "message": message, "interrupt": false]
    case .askInProvider:
        return
    }
    let output: [String: Any] = [
        "hookSpecificOutput": [
            "hookEventName": "PermissionRequest",
            "decision": providerDecision
        ]
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: output) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

/// Status-line mode: Claude Code pipes session JSON here on each refresh. Only the
/// plan rate-limit numbers are kept (usage.json) and a short status line is printed.
private func handleStatusLine(_ raw: [String: Any]) {
    func window(_ key: String) -> [String: Double]? {
        guard let limits = raw["rate_limits"] as? [String: Any], let value = limits[key] as? [String: Any],
              let used = (value["used_percentage"] as? NSNumber)?.doubleValue, used.isFinite else { return nil }
        var result = ["used": min(100, max(0, used))]
        if let reset = (value["resets_at"] as? NSNumber)?.doubleValue, reset.isFinite { result["resetsAt"] = reset }
        return result
    }
    let five = window("five_hour"), week = window("seven_day")
    if five != nil || week != nil {
        var record: [String: Any] = ["updatedAt": Date().timeIntervalSince1970]
        if let five { record["fiveHour"] = five }
        if let week { record["sevenDay"] = week }
        if let data = try? JSONSerialization.data(withJSONObject: record) {
            let url = AppPaths.directory.appendingPathComponent("usage.json")
            try? FileManager.default.createDirectory(at: AppPaths.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if (try? data.write(to: url, options: .atomic)) != nil {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
    }
    var parts: [String] = []
    if let model = (raw["model"] as? [String: Any])?["display_name"] as? String, model.count < 64 { parts.append(model) }
    if let five { parts.append("5h \(Int(five["used"]!.rounded()))%") }
    if let week { parts.append("week \(Int(week["used"]!.rounded()))%") }
    print(parts.joined(separator: " · "))
}

// Provider hooks write only sanitized lifecycle metadata. Approval details use a private,
// in-memory Unix socket only when --approval-wait is explicitly configured for PermissionRequest.
private let options = Options(arguments: CommandLine.arguments)
private let data = FileHandle.standardInput.readData(ofLength: maximumHookBytes + 1)
guard data.count <= maximumHookBytes,
      let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
else { exit(0) }

if CommandLine.arguments.contains("--statusline") { handleStatusLine(raw); exit(0) }
if !forCodex { recordLifecycle(raw) }
if let wait = options.approvalWait,
   data.count <= ApprovalWire.maximumMessageBytes,
   let envelope = makeApprovalEnvelope(raw, wait: wait),
   let response = requestApproval(envelope, wait: wait) {
    writeDecision(response, raw: raw)
}
