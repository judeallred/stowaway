import AppKit
import StowawayKit
import SwiftUI

/// The popover shown from the menu bar icon (spec §8).
struct PopoverView: View {
  let model: AppModel
  @Environment(\.openWindow) private var openWindow

  private static let licenseURL = URL(
    string: "https://github.com/judeallred/stowaway/blob/main/LICENSE-COMMERCIAL.md")

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      if model.agentReachable, let status = model.status {
        DriveRow(model: model, drive: status.drive)
        if let title = model.planTitle {
          PlanSection(title: title, detail: model.planDetail, fraction: model.planFraction)
        }
        if !model.activeTransfers.isEmpty {
          ActivitySection(transfers: model.activeTransfers)
        }
        if model.showsTransferPriority, let priority = status.transferPriority {
          TransferPriorityPicker(model: model, priority: priority)
        }
        PerformanceRow(model: model, performance: status.performance)
        if !status.problems.isEmpty {
          ProblemsSection(problems: status.problems)
        }
        if status.licenseReminder, let url = Self.licenseURL {
          Link("Using this at work? Expense a license →", destination: url)
            .font(.caption)
        }
      }
      if let message = model.busyMessage {
        ProgressView(message).controlSize(.small)
      }
      if let error = model.lastError {
        Text(error).font(.caption).foregroundStyle(.red)
      }
      Divider()
      actions
    }
    .padding(14)
    .frame(width: 340)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(model.headline)
        .font(.headline)
      ForEach(model.subheadlines, id: \.self) { line in
        Text(line).font(.callout).foregroundStyle(.secondary)
      }
      if !model.agentReachable {
        Button("Start Stowaway") { startAgent() }
          .padding(.top, 4)
      }
    }
  }

  private var actions: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button("Configure Folders…") {
        NSApp.activate()
        openWindow(id: WindowID.folders)
      }
      if model.status?.drive.connected == true {
        Button("Eject Drive") {
          Task { await model.perform(.eject, message: "Ejecting…") }
        }
      }
      if let paused = model.status?.paused {
        Button(paused ? "Resume" : "Pause") {
          Task {
            await model.perform(
              paused ? .resume : .pause, message: paused ? "Resuming…" : "Pausing…")
          }
        }
      }
      Button("Open Log") { openLog() }
      Button("Report a Bug…") { reportBug() }
      Button("Quit Stowaway") {
        Task {
          if await model.quit() { NSApp.terminate(nil) }
        }
      }
      .disabled(model.busyMessage != nil)
    }
    .buttonStyle(.link)
  }

  private func startAgent() {
    do {
      try AgentLauncher.start()
      model.lastError = nil
    } catch {
      model.lastError = error.localizedDescription
    }
  }

  /// Opens a prefilled GitHub issue via `stowaway bug-report`, which works even when the agent
  /// isn't running.
  private func reportBug() {
    guard let cli = AgentLauncher.cliPath() else {
      model.lastError = AgentLauncher.LaunchError.cliNotFound.errorDescription
      return
    }
    let process = Process()
    process.executableURL = cli
    process.arguments = ["bug-report"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let model = model
    process.terminationHandler = { process in
      let failed = process.terminationStatus != 0
      Task { @MainActor in
        if failed {
          model.lastError =
            "Couldn't prepare the bug report. Try `stowaway bug-report` in Terminal."
        }
      }
    }
    do {
      try process.run()
    } catch {
      model.lastError = error.localizedDescription
    }
  }

  private func openLog() {
    let home =
      ProcessInfo.processInfo.environment["STOWAWAY_HOME"]
      ?? (NSHomeDirectory() as NSString).appendingPathComponent(".stowaway")
    NSWorkspace.shared.open(URL(fileURLWithPath: home).appendingPathComponent("stowaway-agent.log"))
  }
}

private struct DriveRow: View {
  let model: AppModel
  let drive: DriveStatus

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Image(systemName: drive.connected ? "externaldrive.fill" : "externaldrive.badge.xmark")
        Text(model.driveName).fontWeight(.medium)
        Spacer()
        Text(drive.connected ? "Connected" : "Disconnected")
          .foregroundStyle(drive.connected ? Color.secondary : Color.orange)
      }
      if drive.connected {
        ProgressView(value: model.driveUsedFraction)
          .tint(drive.full ? .red : drive.lowSpace ? .orange : .accentColor)
        Text("\(Format.bytes(drive.availableBytes)) free of \(Format.bytes(drive.totalBytes))")
          .font(.caption)
          .foregroundStyle(.secondary)
        if drive.full {
          Label("The drive is full. Installs and builds will fail.", systemImage: "xmark.octagon")
            .font(.caption).foregroundStyle(.red)
        } else if drive.lowSpace {
          Label("The drive is nearly full.", systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(.orange)
        }
      }
    }
  }
}

private struct PlanSection: View {
  let title: String
  let detail: String?
  let fraction: Double?

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.callout)
      if let fraction {
        ProgressView(value: fraction)
      } else {
        ProgressView().progressViewStyle(.linear)
      }
      if let detail {
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
    }
  }
}

private struct ActivitySection: View {
  let transfers: [TransferProgress]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let first = transfers.first {
        VStack(alignment: .leading, spacing: 2) {
          Text("Moving \(Format.shortPath(first.path))")
            .font(.callout)
          if first.currentStep == .copying {
            ProgressView(value: Double(first.bytes), total: Double(max(first.totalBytes, 1)))
          } else {
            ProgressView().progressViewStyle(.linear)
          }
          Text(detail(first)).font(.caption).foregroundStyle(.secondary)
        }
      }
      if transfers.count > 1 {
        Text("and \(transfers.count - 1) more queued")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func detail(_ transfer: TransferProgress) -> String {
    switch transfer.currentStep {
    case .copying: break
    case .preparing: return transfer.stepLabel
    default: return "\(Format.bytes(transfer.bytes)) copied · \(transfer.stepLabel)"
    }
    if transfer.waitingForDisk == true {
      return
        "\(Format.bytes(transfer.bytes)) of \(Format.bytes(transfer.totalBytes)) · paused while your disk is busy"
    }
    var parts = [
      "\(Format.bytes(transfer.bytes)) of \(Format.bytes(transfer.totalBytes))",
      Format.rate(bytesPerSecond: transfer.bytesPerSecond),
      "\(Format.count(transfer.filesPerSecond)) files/s",
    ]
    if let remaining = transfer.secondsRemaining {
      parts.append(Format.remaining(remaining))
    }
    return parts.joined(separator: " · ")
  }
}

private struct TransferPriorityPicker: View {
  let model: AppModel
  let priority: TransferPriority

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Picker(
        "Offload transfer priority",
        selection: Binding(
          get: { priority },
          set: { newValue in Task { await model.setTransferPriority(newValue) } })
      ) {
        Text("Background").tag(TransferPriority.background)
        Text("Normal").tag(TransferPriority.normal)
      }
      .pickerStyle(.radioGroup)
      .horizontalRadioGroupLayout()
      .font(.caption)
      Text(
        priority == .background
          ? "Transfers pause while other apps keep your disk busy."
          : "Transfers run at full speed, even while your disk is busy."
      )
      .font(.caption2).foregroundStyle(.secondary)
    }
  }
}

private struct PerformanceRow: View {
  let model: AppModel
  let performance: Performance

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text("Drive performance").font(.caption).fontWeight(.medium)
        Spacer()
        Button("Run speed test") {
          Task { await model.perform(.bench(quick: false), message: "Running speed test…") }
        }
        .buttonStyle(.link)
        .font(.caption)
        .disabled(model.status?.drive.connected != true)
      }
      Text(model.performanceLine ?? "No speed test yet.")
        .font(.caption).foregroundStyle(.secondary)
      if let rate = performance.recentTransferMbps {
        Text("Recent transfers: \(Format.rate(megabytesPerSecond: rate))")
          .font(.caption).foregroundStyle(.secondary)
      }
      if let hint = performance.hint {
        Text(hint).font(.caption).foregroundStyle(.orange)
      } else if performance.atLeastInternal {
        Text("Faster than or equal to internal.").font(.caption).foregroundStyle(.secondary)
      }
      if let note = performance.formatNote {
        Text(note).font(.caption).foregroundStyle(.secondary)
      }
      if let bench = performance.lastBench {
        let tested = Date(timeIntervalSince1970: TimeInterval(bench.at))
        Text("Tested \(tested.formatted(.relative(presentation: .named)))")
          .font(.caption2).foregroundStyle(.tertiary)
      }
    }
  }
}

private struct ProblemsSection: View {
  let problems: [Problem]

  /// Problems shown before the rest are summed up in one line.
  private static let shownLimit = 5

  /// Errors first, so a real error is never cut off behind warnings.
  private var ordered: [Problem] {
    problems.filter { $0.severity == .error } + problems.filter { $0.severity != .error }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(ordered.prefix(Self.shownLimit)) { problem in
        VStack(alignment: .leading, spacing: 1) {
          Label(
            problem.message,
            systemImage: problem.severity == .error
              ? "xmark.octagon" : "exclamationmark.triangle"
          )
          .font(.caption)
          .foregroundStyle(problem.severity == .error ? .red : .orange)
          if let hint = problem.hint {
            Text(hint).font(.caption2).foregroundStyle(.secondary).padding(.leading, 20)
          }
        }
      }
      if problems.count > Self.shownLimit {
        Text("\(problems.count - Self.shownLimit) more…")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.leading, 20)
      }
    }
  }
}
