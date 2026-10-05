import Foundation
import Testing

@testable import StowawayKit

/// The fixtures are produced by `stowaway ipc-samples` (`cargo xtask ipc-schema`), so these tests
/// fail if the Rust and Swift sides of the protocol drift apart.
struct ProtocolTests {
  struct Sample {
    let kind: String
    let message: Data
  }

  static func samples() throws -> [Sample] {
    let url = try #require(
      Bundle.module.url(forResource: "ipc-samples", withExtension: "json", subdirectory: "Fixtures")
    )
    let text = try String(contentsOf: url, encoding: .utf8)
    return try text.split(separator: "\n").map { line in
      let object = try #require(
        try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
      let kind = try #require(object["kind"] as? String)
      let message = try JSONSerialization.data(withJSONObject: try #require(object["message"]))
      return Sample(kind: kind, message: message)
    }
  }

  static let calls: [Call] = [
    .status, .subscribe, .refresh, .scan,
    .rootsAdd(path: "/Users/me/code", dryRun: true),
    .rootsRemove(path: "/Users/me/code", copy: false),
    .eject, .pause, .resume,
    .doctor(fix: false),
    .bench(quick: true),
    .setUsage(.work),
    .recordLicense(orderID: "ORD-1", licensee: "Acme"),
  ]

  @Test func swiftRequestsMatchRustRequests() throws {
    let requests = try Self.samples().filter { $0.kind == "request" }
    #expect(requests.count == Self.calls.count)
    for (index, (sample, call)) in zip(requests, Self.calls).enumerated() {
      let swiftLine = try StowawayJSON.requestLine(id: UInt64(index + 1), call: call)
      let swift = try JSONSerialization.jsonObject(with: swiftLine) as? NSDictionary
      let rust = try JSONSerialization.jsonObject(with: sample.message) as? NSDictionary
      #expect(swift == rust, "request \(index + 1): \(call)")
    }
  }

  @Test func statusResponseDecodes() throws {
    let response = try #require(try Self.samples().first { $0.kind == "response" })
    let header = try StowawayJSON.decoder.decode(ResponseHeader.self, from: response.message)
    #expect(header.ok)
    let status = try #require(
      try StowawayJSON.decoder.decode(ResponseBody<StatusReport>.self, from: response.message)
        .result)
    #expect(status.offloadedBytes == 182_400_000_000)
    #expect(status.drive.name == "FastSSD")
    #expect(status.entries.first?.status == .mounted)
    #expect(status.performance.lastBench?.connection.linkGbps == 40)
    #expect(status.problems.first?.severity == .warning)
    guard case .transferProgress(let progress) = status.activeTransfers.first else {
      Issue.record("expected an active transfer")
      return
    }
    #expect(progress.totalFiles == 81_000)
  }

  @Test func errorResponseCarriesMessage() throws {
    let responses = try Self.samples().filter { $0.kind == "response" }
    let failure = try #require(responses.last)
    let header = try StowawayJSON.decoder.decode(ResponseHeader.self, from: failure.message)
    #expect(!header.ok)
    #expect(header.error?.contains("can't eject") == true)
  }

  @Test func everyNotificationDecodes() throws {
    let notes = try Self.samples().filter { $0.kind == "notification" }
      .map { try StowawayJSON.decoder.decode(AgentNotification.self, from: $0.message) }
    #expect(notes.count == 5)
    for note in notes {
      if case .unknown(let name) = note { Issue.record("unknown notification \(name)") }
      if case .engine(.unknown(let name)) = note { Issue.record("unknown engine event \(name)") }
    }
    #expect(notes.contains(.engine(.driveChanged(connected: false))))
  }

  @Test func socketPathMatchesRust() {
    let short = AgentClient.defaultSocketPath(environment: [:], home: "/Users/me")
    #expect(short == "/Users/me/.stowaway/agent.sock")
    let custom = AgentClient.defaultSocketPath(
      environment: ["STOWAWAY_HOME": "/tmp/s"], home: "/Users/me")
    #expect(custom == "/tmp/s/agent.sock")
    let long = AgentClient.defaultSocketPath(
      environment: ["STOWAWAY_HOME": "/" + String(repeating: "x", count: 120)], home: "/")
    #expect(long.hasPrefix("/tmp/stowaway-") && long.hasSuffix(".sock"))
  }
}
