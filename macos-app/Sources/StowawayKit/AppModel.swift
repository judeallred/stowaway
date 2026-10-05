import Foundation
public import Observation

/// What the menu bar icon shows (spec §8).
public enum IconState: Equatable, Sendable {
  case idle
  case transferring
  case disconnected
  case warning
  case error
  case paused

  /// The SF Symbol for this state. `frame` alternates while transferring.
  public func symbolName(frame: Int, reduceMotion: Bool) -> String {
    switch self {
    case .idle: "shippingbox"
    case .transferring:
      reduceMotion || frame.isMultiple(of: 2)
        ? "shippingbox.and.arrow.backward" : "shippingbox"
    case .disconnected: "externaldrive.badge.xmark"
    case .warning: "externaldrive.badge.exclamationmark"
    case .error: "exclamationmark.triangle"
    case .paused: "pause.circle"
    }
  }

  /// Spoken by VoiceOver.
  public var accessibilityLabel: String {
    switch self {
    case .idle: "Stowaway"
    case .transferring: "Stowaway, transferring"
    case .disconnected: "Stowaway, drive disconnected"
    case .warning: "Stowaway, needs attention"
    case .error: "Stowaway, problem"
    case .paused: "Stowaway, paused"
    }
  }
}

/// State behind the menu bar icon, popover and folders window.
@MainActor
@Observable
public final class AppModel {
  public private(set) var status: StatusReport?
  public private(set) var transfers: [String: TransferProgress] = [:]
  public private(set) var agentReachable = false
  public private(set) var animationFrame = 0
  public var lastError: String?
  public var busyMessage: String?

  public let client: AgentClient
  private var subscription: Task<Void, Never>?
  private var animation: Task<Void, Never>?

  public init(client: AgentClient = AgentClient()) {
    self.client = client
  }

  /// Connects to the agent and keeps reconnecting if it goes away.
  public func start() {
    guard subscription == nil else { return }
    subscription = Task { [weak self] in
      while !Task.isCancelled {
        await self?.listen()
        try? await Task.sleep(for: .seconds(3))
      }
    }
  }

  private func listen() async {
    do {
      let stream = try client.notifications()
      agentReachable = true
      for try await note in stream {
        apply(note)
      }
    } catch {
      // Fall through: the agent isn't running or went away.
    }
    agentReachable = false
    transfers = [:]
    updateAnimation()
  }

  /// Applies a pushed notification.
  public func apply(_ note: AgentNotification) {
    switch note {
    case .status(let report):
      agentReachable = true
      status = report
      var active: [String: TransferProgress] = [:]
      for case .transferProgress(let progress) in report.activeTransfers {
        active[progress.entryId] = progress
      }
      transfers = active
    case .engine(.transferProgress(let progress)):
      transfers[progress.entryId] = progress
    case .engine(.transferDone(let transfer)):
      transfers[transfer.entryId] = nil
    case .engine(.driveChanged(let connected)):
      status?.drive.connected = connected
      if !connected { transfers = [:] }
    case .engine, .unknown:
      break
    }
    updateAnimation()
  }

  /// Marks the agent unreachable (used by tests and when a request fails to connect).
  public func markAgentUnreachable() {
    agentReachable = false
    transfers = [:]
    updateAnimation()
  }

  private func updateAnimation() {
    if iconState == .transferring {
      guard animation == nil else { return }
      animation = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(450))
          self?.animationFrame += 1
        }
      }
    } else {
      animation?.cancel()
      animation = nil
      animationFrame = 0
    }
  }

  // MARK: Derived state

  public var iconState: IconState {
    guard agentReachable, let status else { return .error }
    if status.drive.full || status.problems.contains(where: { $0.severity == .error }) {
      return .error
    }
    if !status.drive.connected { return .disconnected }
    if !transfers.isEmpty { return .transferring }
    if status.drive.lowSpace || !status.problems.isEmpty { return .warning }
    if status.paused { return .paused }
    return .idle
  }

  public var driveName: String {
    status?.drive.name ?? "your drive"
  }

  /// The popover's headline (spec §8, item 1).
  public var headline: String {
    guard agentReachable, let status else { return "Stowaway isn't running" }
    if status.drive.connected {
      return "Stowaway is offloading \(Format.bytes(status.offloadedBytes))"
    }
    return "Drive disconnected — working locally"
  }

  /// Lines under the headline.
  public var subheadlines: [String] {
    guard agentReachable, let status else {
      return ["Start it to keep your dependencies on \(driveName)."]
    }
    if status.drive.connected { return [] }
    var lines = ["\(Format.bytes(status.offloadedBytes)) is waiting on \(driveName)."]
    if status.localBytes > 0 {
      lines.append(
        "\(Format.bytes(status.localBytes)) is being used locally until the drive comes back.")
    }
    return lines
  }

  /// Active transfers, largest first.
  public var activeTransfers: [TransferProgress] {
    transfers.values.sorted { $0.totalBytes > $1.totalBytes }
  }

  /// Fraction of the drive in use, for the free-space bar.
  public var driveUsedFraction: Double {
    guard let drive = status?.drive, drive.totalBytes > 0 else { return 0 }
    return 1 - Double(drive.availableBytes) / Double(drive.totalBytes)
  }

  /// One-line drive performance summary (spec §8.1).
  public var performanceLine: String? {
    guard let bench = status?.performance.lastBench else { return nil }
    var parts: [String] = []
    if let transport = bench.connection.transport {
      if let label = bench.connection.linkLabel {
        parts.append("\(transport) (\(label))")
      } else {
        parts.append(transport)
      }
    }
    parts.append("read \(Format.rate(megabytesPerSecond: bench.external.seqReadMbps))")
    parts.append("write \(Format.rate(megabytesPerSecond: bench.external.seqWriteMbps))")
    if bench.internal.smallFileOpsPerSec > 0 {
      let ratio = bench.external.smallFileOpsPerSec / bench.internal.smallFileOpsPerSec
      parts.append(String(format: "small files %.1f× internal", ratio))
    }
    return parts.joined(separator: " · ")
  }

  // MARK: Actions

  /// Runs a request, showing `message` while it's in flight and any error afterwards.
  public func perform(_ call: Call, message: String) async {
    busyMessage = message
    defer { busyMessage = nil }
    do {
      try await client.send(call)
      lastError = nil
    } catch AgentError.notRunning {
      markAgentUnreachable()
      lastError = AgentError.notRunning.errorDescription
    } catch {
      lastError = error.localizedDescription
    }
  }

  /// Previews adding a watched folder (spec §8, Configure Folders).
  public func previewRoot(_ path: String) async throws -> RootPreview? {
    try await client.call(.rootsAdd(path: path, dryRun: true), as: RootPreview.self)
  }
}
