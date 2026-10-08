import Foundation
import Testing

@testable import StowawayKit

@MainActor
struct AppModelTests {
  static func status(
    connected: Bool = true,
    lowSpace: Bool = false,
    paused: Bool = false,
    offloaded: UInt64 = 182_400_000_000,
    local: UInt64 = 0,
    problems: [Problem] = []
  ) -> StatusReport {
    StatusReport(
      version: "0.1.0",
      drive: DriveStatus(
        name: "FastSSD", connected: connected, mountPoint: "/Volumes/FastSSD",
        totalBytes: 2_000_000_000_000, availableBytes: 500_000_000_000,
        lowSpace: lowSpace, full: false),
      offloadedBytes: offloaded, localBytes: local, entries: [], roots: [],
      activeTransfers: [], plan: nil, recentTransfers: [], problems: problems,
      performance: Performance(
        lastBench: nil, recentTransferMbps: nil, recentTransferFilesPerSec: nil, hint: nil,
        atLeastInternal: false),
      attachedImages: 0, paused: paused, transferPriority: .background, agentRunning: true,
      licenseReminder: false)
  }

  static let progress = TransferProgress(
    entryId: "e1", path: "/Users/me/code/app/node_modules", op: "adopt",
    bytes: 1_200_000_000, totalBytes: 3_400_000_000, files: 30_000, totalFiles: 81_000,
    elapsedSeconds: 3)

  @Test func headlineWhenConnected() {
    let model = AppModel(client: AgentClient(socketPath: "/nonexistent"))
    model.apply(.status(Self.status()))
    #expect(model.headline == "Stowaway is offloading 182.4 GB")
    #expect(model.subheadlines.isEmpty)
    #expect(model.iconState == .idle)
  }

  @Test func headlineWhenDisconnected() {
    let model = AppModel(client: AgentClient(socketPath: "/nonexistent"))
    model.apply(.status(Self.status(connected: false, local: 3_100_000_000)))
    #expect(model.headline == "Drive disconnected — working locally")
    #expect(
      model.subheadlines == [
        "182.4 GB is waiting on FastSSD.",
        "3.1 GB is being used locally until the drive comes back.",
      ])
    #expect(model.iconState == .disconnected)
  }

  @Test func planShowsEachPhase() {
    let model = AppModel(client: AgentClient(socketPath: "/nonexistent"))
    model.apply(.status(Self.status(offloaded: 0)))
    #expect(model.planTitle == nil)
    model.apply(
      .plan(
        AdoptionPlan(
          phase: .measuring, foldersDone: 0, foldersTotal: 0, plannedBytes: 0, movedBytes: 0)))
    #expect(model.planTitle == "Looking for folders to offload…")
    #expect(model.planFraction == nil)
    #expect(model.iconState == .measuring)
    #expect(!model.showsTransferPriority, "nothing is moving while measuring")
    model.apply(
      .plan(
        AdoptionPlan(
          phase: .measuring, foldersDone: 12, foldersTotal: 66, plannedBytes: 41_200_000_000,
          movedBytes: 0)))
    #expect(model.planTitle == "Measuring folders: 12 of 66 checked")
    #expect(model.planDetail == "41.2 GB to offload so far")
    model.apply(
      .plan(
        AdoptionPlan(
          phase: .adopting, foldersDone: 3, foldersTotal: 56, plannedBytes: 100_000_000_000,
          movedBytes: 10_000_000_000)))
    model.apply(.engine(.transferProgress(Self.progress)))
    #expect(model.planTitle == "Offloading 100.0 GB: 3 of 56 folders")
    #expect(model.planDetail == "11.2 GB moved")
    #expect(model.planFraction == 0.112)
    #expect(model.iconState == .adopting)
    #expect(model.showsTransferPriority)
    model.apply(.plan(nil))
    #expect(model.planTitle == nil)
  }

  @Test func transfersShowTheirStepAndDisappearWhenAborted() {
    let model = AppModel(client: AgentClient(socketPath: "/nonexistent"))
    model.apply(.status(Self.status()))
    var flushing = Self.progress
    flushing.step = "flushing"
    model.apply(.engine(.transferProgress(flushing)))
    #expect(model.activeTransfers.first?.stepLabel == "Writing to the drive…")
    var compacting = flushing
    compacting.op = "compact"
    compacting.step = "cleaning"
    #expect(compacting.stepLabel == "Removing the old image…")
    model.apply(.engine(.transferAborted(entryId: flushing.entryId)))
    #expect(model.activeTransfers.isEmpty)
  }

  static func global(_ kind: String, detected: Bool, enabled: Bool = true) -> GlobalReport {
    GlobalReport(
      kind: kind, label: kind, description: "", paths: detected ? ["/Users/me/\(kind)"] : [],
      detected: detected, enabled: enabled, entries: 0, offloadedBytes: 0, pendingBytes: nil)
  }

  @Test func globalsSplitByDetection() {
    let model = AppModel(client: AgentClient(socketPath: "/nonexistent"))
    var status = Self.status()
    status.globals = [
      Self.global("pnpm-store", detected: true), Self.global("go", detected: false),
    ]
    model.apply(.status(status))
    #expect(model.detectedGlobals.map(\.kind) == ["pnpm-store"])
    #expect(model.undetectedGlobals.map(\.kind) == ["go"])
  }

  @Test func globalToggleRevertsWhenTheAgentIsUnreachable() async {
    let model = AppModel(client: AgentClient(socketPath: "/nonexistent"))
    var status = Self.status()
    status.globals = [Self.global("pnpm-store", detected: true)]
    model.apply(.status(status))
    await model.setGlobalEnabled(Self.global("pnpm-store", detected: true), enabled: false)
    #expect(model.status?.globals?.first?.enabled == true)
    #expect(model.lastError != nil)
  }

  @Test func transferPriorityRevertsWhenTheAgentIsUnreachable() async {
    let model = AppModel(client: AgentClient(socketPath: "/nonexistent"))
    model.apply(.status(Self.status()))
    await model.setTransferPriority(.normal)
    #expect(model.status?.transferPriority == .background)
    #expect(model.lastError != nil)
  }

  @Test func quittingWithoutAnAgentStillQuits() async {
    let model = AppModel(client: AgentClient(socketPath: "/nonexistent"))
    #expect(await model.quit())
    #expect(model.busyMessage == nil)
    #expect(model.lastError == nil)
  }

  @Test func iconStatesFollowPriority() {
    let model = AppModel(client: AgentClient(socketPath: "/nonexistent"))
    #expect(model.iconState == .error, "no agent yet")
    model.apply(.status(Self.status(paused: true)))
    #expect(model.iconState == .paused)
    model.apply(.status(Self.status(lowSpace: true)))
    #expect(model.iconState == .warning)
    model.apply(.engine(.transferProgress(Self.progress)))
    #expect(model.iconState == .adopting)
    model.apply(
      .engine(
        .transferDone(
          Transfer(
            entryId: "e1", op: "adopt", bytes: 1, files: 1, seconds: 1, finishedAt: 0))))
    #expect(model.iconState == .warning)
    model.apply(
      .status(
        Self.status(problems: [Problem(severity: .error, message: "broken", hint: nil)])))
    #expect(model.iconState == .error)
    model.markAgentUnreachable()
    #expect(model.headline == "Stowaway isn't running")
  }

  @Test func eachTransferKindHasItsOwnIcon() {
    #expect(IconState.forTransfer(op: "adopt") == .adopting)
    #expect(IconState.forTransfer(op: "reconnect") == .syncing)
    #expect(IconState.forTransfer(op: "merge") == .syncing)
    #expect(IconState.forTransfer(op: "compact") == .compacting)
    #expect(IconState.forTransfer(op: "release") == .releasing)
    let states: [IconState] = [
      .idle, .measuring, .adopting, .syncing, .compacting, .releasing, .disconnected, .warning,
      .error, .paused,
    ]
    let badges = states.map(\.badgeSymbolName)
    #expect(badges.first == .some(nil))
    #expect(Set(badges.dropFirst().compactMap(\.self)).count == states.count - 1)
  }

  @Test func progressEstimates() throws {
    let progress = Self.progress
    #expect(progress.bytesPerSecond == 400_000_000)
    let remaining = try #require(progress.secondsRemaining)
    #expect(abs(remaining - 5.5) < 0.001)
    #expect(Format.rate(bytesPerSecond: progress.bytesPerSecond) == "400 MB/s")
    #expect(Format.remaining(remaining) == "about 6 s left")
  }

  @Test func formatting() {
    #expect(Format.bytes(999) == "999 bytes")
    #expect(Format.bytes(182_400_000_000) == "182.4 GB")
    #expect(Format.rate(megabytesPerSecond: 2600) == "2.6 GB/s")
    #expect(Format.shortPath("/Users/me/code/app/node_modules") == "app/node_modules")
    #expect(Format.abbreviatedPath("/Users/me/code", home: "/Users/me") == "~/code")
    #expect(Format.count(8200) == "8,200")
  }
}
