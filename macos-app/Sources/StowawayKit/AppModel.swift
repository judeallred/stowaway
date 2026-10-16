import Foundation
public import Observation

/// What the menu bar icon shows (spec §8).
public enum IconState: Equatable, Sendable {
  case idle
  /// Adding up folder sizes before adopting.
  case measuring
  /// Moving folders onto the drive.
  case adopting
  /// Bringing local changes and the drive back in step after a reconnect.
  case syncing
  /// Rebuilding bloated images.
  case compacting
  /// Returning folders to plain local folders.
  case releasing
  case disconnected
  case warning
  case error
  case paused
  /// Every folder is a plain local folder until the user attaches again.
  case detached

  /// The small SF Symbol overlapping the logo's corner, or nil for the plain logo. Icons never
  /// animate.
  public var badgeSymbolName: String? {
    switch self {
    case .idle: nil
    case .measuring: "magnifyingglass"
    case .adopting: "arrow.down"
    case .syncing: "arrow.triangle.2.circlepath"
    case .compacting: "arrow.down.right.and.arrow.up.left"
    case .releasing: "arrow.uturn.backward"
    case .disconnected: "xmark.circle.fill"
    case .warning: "exclamationmark.circle.fill"
    case .error: "exclamationmark.triangle.fill"
    case .paused: "pause.circle.fill"
    case .detached: "minus.circle.fill"
    }
  }

  /// Spoken by VoiceOver.
  public var accessibilityLabel: String {
    switch self {
    case .idle: "Stowaway"
    case .measuring: "Stowaway, measuring folders"
    case .adopting: "Stowaway, moving folders to the drive"
    case .syncing: "Stowaway, syncing with the drive"
    case .compacting: "Stowaway, compacting images"
    case .releasing: "Stowaway, releasing folders"
    case .disconnected: "Stowaway, drive disconnected"
    case .warning: "Stowaway, needs attention"
    case .error: "Stowaway, problem"
    case .paused: "Stowaway, paused"
    case .detached: "Stowaway, detached"
    }
  }

  /// The state for a transfer's `op`.
  static func forTransfer(op: String) -> Self {
    switch op {
    case "reconnect", "merge": .syncing
    case "compact": .compacting
    case "release": .releasing
    default: .adopting
    }
  }
}

/// State behind the menu bar icon, popover and folders window.
@MainActor
@Observable
public final class AppModel {
  public private(set) var status: StatusReport?
  public private(set) var transfers: [String: TransferProgress] = [:]
  public private(set) var plan: AdoptionPlan?
  public private(set) var agentReachable = false
  public var lastError: String?
  public var busyMessage: String?

  public let client: AgentClient
  private var subscription: Task<Void, Never>?

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
    plan = nil
  }

  /// Applies a pushed notification.
  public func apply(_ note: AgentNotification) {
    switch note {
    case .status(let report):
      agentReachable = true
      status = report
      plan = report.plan
      var active: [String: TransferProgress] = [:]
      for case .transferProgress(let progress) in report.activeTransfers {
        active[progress.entryId] = progress
      }
      transfers = active
    case .engine(.transferProgress(let progress)):
      transfers[progress.entryId] = progress
    case .engine(.transferDone(let transfer)):
      transfers[transfer.entryId] = nil
    case .engine(.transferAborted(let entryId)):
      transfers[entryId] = nil
    case .engine(.driveChanged(let connected)):
      status?.drive.connected = connected
      if !connected { transfers = [:] }
    case .plan(let newPlan):
      plan = newPlan
    case .engine, .unknown:
      break
    }
  }

  /// Marks the agent unreachable (used by tests and when a request fails to connect).
  public func markAgentUnreachable() {
    agentReachable = false
    transfers = [:]
    plan = nil
  }

  // MARK: Derived state

  public var iconState: IconState {
    guard agentReachable, let status else { return .error }
    if status.drive.full || status.problems.contains(where: { $0.severity == .error }) {
      return .error
    }
    if status.detached == true { return .detached }
    if !status.drive.connected { return .disconnected }
    if let transfer = activeTransfers.first { return .forTransfer(op: transfer.op) }
    switch plan?.phase {
    case .adopting: return .adopting
    case .measuring: return .measuring
    case nil: break
    }
    if status.drive.lowSpace || !status.problems.isEmpty { return .warning }
    if status.paused { return .paused }
    return .idle
  }

  public var driveName: String {
    status?.drive.name ?? "your drive"
  }

  /// The popover's headline (spec §8, item 1).
  public var headline: String {
    guard agentReachable else { return "Stowaway isn't running" }
    guard let status else { return "Connecting to Stowaway…" }
    if status.detached == true { return "Detached — using local folders" }
    if status.drive.connected {
      return "Stowaway is offloading \(Format.bytes(status.offloadedBytes))"
    }
    return "Drive disconnected — working locally"
  }

  /// Lines under the headline.
  public var subheadlines: [String] {
    guard agentReachable else {
      return ["Start it to keep your dependencies on \(driveName)."]
    }
    guard let status else { return [] }
    if status.detached == true {
      return [
        "\(Format.bytes(status.offloadedBytes)) stays on \(driveName). Attach to use it again."
      ]
    }
    if status.drive.connected { return [] }
    var lines = ["\(Format.bytes(status.offloadedBytes)) is waiting on \(driveName)."]
    if status.localBytes > 0 {
      lines.append(
        "\(Format.bytes(status.localBytes)) is being used locally until the drive comes back.")
    }
    return lines
  }

  /// What the auto-adoption pass is doing, e.g. "Measuring folders: 12 of 66 checked".
  public var planTitle: String? {
    guard let plan else { return nil }
    switch plan.phase {
    case .measuring where plan.foldersTotal == 0:
      return "Looking for folders to offload…"
    case .measuring:
      return "Measuring folders: \(plan.foldersDone) of \(plan.foldersTotal) checked"
    case .adopting:
      return
        "Offloading \(Format.bytes(plan.plannedBytes)): \(plan.foldersDone) of \(plan.foldersTotal) folders"
    }
  }

  /// The line under `planTitle`.
  public var planDetail: String? {
    guard let plan else { return nil }
    switch plan.phase {
    case .measuring where plan.foldersTotal == 0: return nil
    case .measuring: return "\(Format.bytes(plan.plannedBytes)) to offload so far"
    case .adopting: return "\(Format.bytes(planMovedBytes)) moved"
    }
  }

  /// Progress through the pass, or nil while there's nothing to measure it against yet.
  public var planFraction: Double? {
    guard let plan else { return nil }
    switch plan.phase {
    case .measuring:
      guard plan.foldersTotal > 0 else { return nil }
      return Double(plan.foldersDone) / Double(plan.foldersTotal)
    case .adopting:
      if plan.plannedBytes > 0 {
        return min(1, Double(planMovedBytes) / Double(plan.plannedBytes))
      }
      guard plan.foldersTotal > 0 else { return nil }
      return Double(plan.foldersDone) / Double(plan.foldersTotal)
    }
  }

  /// Bytes moved in this pass, including the copy in progress.
  private var planMovedBytes: UInt64 {
    let current = transfers.values.filter { $0.op == "adopt" }.reduce(0) { $0 + $1.bytes }
    return (plan?.movedBytes ?? 0) + current
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

  /// Asks the agent to detach every image and stop, so folders use their local contents until
  /// Stowaway starts again. Returns whether the app can quit: true once the agent has stopped
  /// (or wasn't running), false if it refused, e.g. because files on the drive are open.
  public func quit() async -> Bool {
    busyMessage = "Detaching folders from \(driveName)…"
    defer { busyMessage = nil }
    do {
      try await client.send(.quit)
      return true
    } catch AgentError.notRunning, AgentError.closed {
      return true
    } catch {
      lastError = error.localizedDescription
      return false
    }
  }

  /// Whether the offload transfer priority toggle is shown: only while folders are being moved.
  public var showsTransferPriority: Bool {
    guard status?.transferPriority != nil else { return false }
    return plan?.phase == .adopting || !transfers.isEmpty
  }

  /// Sets the offload transfer priority. The toggle flips right away, and flips back if the agent
  /// rejects the change.
  public func setTransferPriority(_ priority: TransferPriority) async {
    let previous = status?.transferPriority
    guard previous != priority else { return }
    status?.transferPriority = priority
    do {
      try await client.send(.setTransferPriority(priority))
      lastError = nil
    } catch {
      status?.transferPriority = previous
      lastError = error.localizedDescription
    }
  }

  /// Global caches found on this Mac, and supported ones that weren't.
  public var detectedGlobals: [GlobalReport] {
    (status?.globals ?? []).filter(\.detected)
  }

  public var undetectedGlobals: [GlobalReport] {
    (status?.globals ?? []).filter { !$0.detected }
  }

  /// Turns offloading of a global cache on or off. The checkbox flips right away, and flips back
  /// if the agent rejects the change. Turning off a cache with folders on the drive releases them,
  /// copying them back with `copy`.
  public func setGlobalEnabled(_ global: GlobalReport, enabled: Bool, copy: Bool = false) async {
    guard let index = status?.globals?.firstIndex(where: { $0.kind == global.kind }) else {
      return
    }
    let previous = status?.globals?[index].enabled
    status?.globals?[index].enabled = enabled
    let releasing = !enabled && global.entries > 0
    if releasing {
      busyMessage =
        copy ? "Copying \(global.label) back to this Mac…" : "Releasing \(global.label)…"
    }
    defer { if releasing { busyMessage = nil } }
    do {
      try await client.send(.setKindEnabled(kind: global.kind, enabled: enabled, copy: copy))
      lastError = nil
    } catch {
      if let previous, status?.globals?.indices.contains(index) == true {
        status?.globals?[index].enabled = previous
      }
      if case AgentError.notRunning = error { markAgentUnreachable() }
      lastError = error.localizedDescription
    }
  }

  /// Previews adding a watched folder (spec §8, Configure Folders).
  public func previewRoot(_ path: String) async throws -> RootPreview? {
    try await client.call(.rootsAdd(path: path, dryRun: true), as: RootPreview.self)
  }
}
