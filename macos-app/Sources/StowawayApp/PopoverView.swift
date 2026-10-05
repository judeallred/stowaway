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
        if !model.activeTransfers.isEmpty {
          ActivitySection(transfers: model.activeTransfers)
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
      Button("Quit Menu Bar App") { NSApp.terminate(nil) }
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

  private func openLog() {
    let home =
      ProcessInfo.processInfo.environment["STOWAWAY_HOME"]
      ?? (NSHomeDirectory() as NSString).appendingPathComponent(".stowaway")
    NSWorkspace.shared.open(URL(fileURLWithPath: home).appendingPathComponent("agent.log"))
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

private struct ActivitySection: View {
  let transfers: [TransferProgress]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let first = transfers.first {
        VStack(alignment: .leading, spacing: 2) {
          Text("Moving \(Format.shortPath(first.path))")
            .font(.callout)
          ProgressView(value: Double(first.bytes), total: Double(max(first.totalBytes, 1)))
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

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(problems) { problem in
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
    }
  }
}
