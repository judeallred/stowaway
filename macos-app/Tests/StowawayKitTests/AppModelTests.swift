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
      activeTransfers: [], recentTransfers: [], problems: problems,
      performance: Performance(
        lastBench: nil, recentTransferMbps: nil, recentTransferFilesPerSec: nil, hint: nil,
        atLeastInternal: false),
      attachedImages: 0, paused: paused, agentRunning: true, licenseReminder: false)
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

  @Test func iconStatesFollowPriority() {
    let model = AppModel(client: AgentClient(socketPath: "/nonexistent"))
    #expect(model.iconState == .error, "no agent yet")
    model.apply(.status(Self.status(paused: true)))
    #expect(model.iconState == .paused)
    model.apply(.status(Self.status(lowSpace: true)))
    #expect(model.iconState == .warning)
    model.apply(.engine(.transferProgress(Self.progress)))
    #expect(model.iconState == .transferring)
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

  @Test func transferringSymbolsAnimateUnlessReduceMotion() {
    let state = IconState.transferring
    #expect(
      state.symbolName(frame: 0, reduceMotion: false)
        != state.symbolName(frame: 1, reduceMotion: false))
    #expect(
      state.symbolName(frame: 0, reduceMotion: true)
        == state.symbolName(frame: 1, reduceMotion: true))
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
