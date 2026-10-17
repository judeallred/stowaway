public import Foundation

// Mirrors of the agent's JSON types (crates/stowaway/src/status.rs, engine.rs, ipc.rs).
// Field names arrive in snake_case and are converted by `StowawayJSON.decoder`.

public struct StatusReport: Decodable, Sendable, Equatable {
  public var version: String
  public var drive: DriveStatus
  public var offloadedBytes: UInt64
  public var localBytes: UInt64
  public var entries: [EntryReport]
  public var roots: [RootReport]
  /// Missing from agents older than the folders window's cache list.
  public var globals: [GlobalReport]?
  public var activeTransfers: [EngineEvent]
  public var plan: AdoptionPlan?
  public var recentTransfers: [Transfer]
  public var problems: [Problem]
  public var performance: Performance
  public var attachedImages: Int
  public var paused: Bool
  /// Missing from agents older than detaching.
  public var detached: Bool?
  /// Missing from agents older than the setting.
  public var transferPriority: TransferPriority?
  public var agentRunning: Bool
  public var licenseReminder: Bool
}

public struct DriveStatus: Decodable, Sendable, Equatable {
  public var name: String?
  public var connected: Bool
  public var mountPoint: String?
  public var totalBytes: UInt64
  public var availableBytes: UInt64
  public var lowSpace: Bool
  public var full: Bool
}

public enum EntryStatus: String, Decodable, Sendable {
  case mounted
  case local
  case pendingReconnect = "pending-reconnect"
  case error
}

public struct EntryReport: Decodable, Sendable, Equatable, Identifiable {
  public var id: String
  public var kind: String
  public var path: String
  public var status: EntryStatus
  public var usedBytes: UInt64
  public var imageBytes: UInt64
  public var note: String?
}

public struct RootReport: Decodable, Sendable, Equatable, Identifiable {
  public var path: String
  public var exists: Bool
  public var entries: Int
  public var offloadedBytes: UInt64
  public var id: String { path }
}

/// A machine-wide cache kind such as the pnpm store (spec §4.8).
public struct GlobalReport: Decodable, Sendable, Equatable, Identifiable {
  public var kind: String
  public var label: String
  public var description: String
  /// Its locations that exist on this Mac.
  public var paths: [String]
  public var detected: Bool
  public var enabled: Bool
  public var entries: Int
  public var offloadedBytes: UInt64
  /// Last measured size of locations not offloaded yet.
  public var pendingBytes: UInt64?
  public var id: String { kind }
}

public struct Transfer: Decodable, Sendable, Equatable {
  public var entryId: String
  public var op: String
  public var bytes: UInt64
  public var files: UInt64
  public var seconds: Double
  public var finishedAt: Int64
}

public struct TransferProgress: Decodable, Sendable, Equatable {
  public var entryId: String
  public var path: String
  public var op: String
  public var bytes: UInt64
  public var totalBytes: UInt64
  public var files: UInt64
  public var totalFiles: UInt64
  public var elapsedSeconds: Double
  /// Paused because other programs are keeping the internal disk busy.
  public var waitingForDisk: Bool?
  /// The raw step name; see `currentStep`.
  public var step: String?

  /// What the transfer is doing. Missing from older agents, which only reported copying; unknown
  /// steps from newer agents read as copying too.
  public var currentStep: TransferStep {
    step.flatMap(TransferStep.init(rawValue:)) ?? .copying
  }

  /// The current step in words, e.g. "Removing the local copy…".
  public var stepLabel: String {
    guard currentStep == .cleaning else { return currentStep.label }
    switch op {
    case "compact": return "Removing the old image…"
    case "release": return "Deleting the image from the drive…"
    default: return currentStep.label
    }
  }

  /// Bytes per second so far.
  public var bytesPerSecond: Double {
    elapsedSeconds > 0 ? Double(bytes) / elapsedSeconds : 0
  }

  /// Seconds remaining at the current rate, if it can be estimated.
  public var secondsRemaining: Double? {
    guard bytesPerSecond > 0, totalBytes >= bytes else { return nil }
    return Double(totalBytes - bytes) / bytesPerSecond
  }

  /// Files per second so far.
  public var filesPerSecond: Double {
    elapsedSeconds > 0 ? Double(files) / elapsedSeconds : 0
  }
}

/// The steps of a transfer, in order (engine.rs `TransferStep`).
public enum TransferStep: String, Sendable, CaseIterable {
  case preparing
  case copying
  case flushing
  case verifying
  case cleaning
  case mounting
  case measuring

  /// Shown under the transfer while it's in this step.
  public var label: String {
    switch self {
    case .preparing: "Preparing…"
    case .copying: "Copying"
    case .flushing: "Writing to the drive…"
    case .verifying: "Checking nothing changed during the copy…"
    case .cleaning: "Removing the local copy…"
    case .mounting: "Mounting…"
    case .measuring: "Measuring…"
    }
  }
}

public enum EngineEvent: Decodable, Sendable, Equatable {
  case transferProgress(TransferProgress)
  case transferDone(Transfer)
  /// The transfer stopped without finishing.
  case transferAborted(entryId: String)
  case entriesChanged
  case driveChanged(connected: Bool)
  case unknown(String)

  private enum CodingKeys: String, CodingKey {
    case type
    case transfer
    case entryId
    case connected
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)
    switch type {
    case "transfer-progress":
      self = .transferProgress(try TransferProgress(from: decoder))
    case "transfer-done":
      self = .transferDone(try container.decode(Transfer.self, forKey: .transfer))
    case "transfer-aborted":
      self = .transferAborted(entryId: try container.decode(String.self, forKey: .entryId))
    case "entries-changed":
      self = .entriesChanged
    case "drive-changed":
      self = .driveChanged(connected: try container.decode(Bool.self, forKey: .connected))
    default:
      self = .unknown(type)
    }
  }
}

public enum PlanPhase: String, Decodable, Sendable {
  case measuring
  case adopting
}

/// The agent's current auto-adoption pass.
public struct AdoptionPlan: Decodable, Sendable, Equatable {
  public var phase: PlanPhase
  public var foldersDone: Int
  public var foldersTotal: Int
  public var plannedBytes: UInt64
  public var movedBytes: UInt64
}

public enum Severity: String, Decodable, Sendable {
  case error
  case warning
}

public struct Problem: Decodable, Sendable, Equatable, Identifiable {
  public var severity: Severity
  public var message: String
  public var hint: String?
  public var id: String { message }
}

public struct Performance: Decodable, Sendable, Equatable {
  public var lastBench: BenchReport?
  public var recentTransferMbps: Double?
  public var recentTransferFilesPerSec: Double?
  public var hint: String?
  /// Whether the drive's format is the best one for Stowaway; missing from older agents.
  public var formatNote: String?
  public var atLeastInternal: Bool
}

public struct BenchReport: Decodable, Sendable, Equatable {
  public var at: Int64
  public var connection: Connection
  public var `internal`: DiskResult
  public var external: DiskResult
  public var hint: String?
}

public struct Connection: Decodable, Sendable, Equatable {
  public var transport: String?
  public var linkLabel: String?
  public var linkGbps: Double?
  public var model: String?
  public var solidState: Bool?
}

public struct DiskResult: Decodable, Sendable, Equatable {
  public var seqWriteMbps: Double
  public var seqReadMbps: Double
  public var smallFileOpsPerSec: Double
  public var smallFileP50Ms: Double
  public var smallFileP99Ms: Double
  public var randomReadIops: Double
}

public struct RootPreview: Decodable, Sendable, Equatable {
  public var projects: Int
  public var offloadableBytes: UInt64
}

/// A message pushed to subscribers.
public enum AgentNotification: Decodable, Sendable, Equatable {
  case status(StatusReport)
  case engine(EngineEvent)
  case plan(AdoptionPlan?)
  case unknown(String)

  private enum CodingKeys: String, CodingKey {
    case event
    case data
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let event = try container.decode(String.self, forKey: .event)
    switch event {
    case "status": self = .status(try container.decode(StatusReport.self, forKey: .data))
    case "engine": self = .engine(try container.decode(EngineEvent.self, forKey: .data))
    case "plan": self = .plan(try container.decodeIfPresent(AdoptionPlan.self, forKey: .data))
    default: self = .unknown(event)
    }
  }
}

/// Personal or work use (spec §13.6).
public enum Usage: String, Encodable, Sendable {
  case personal
  case work
}

/// Offload transfer priority: whether transfers yield to other disk activity.
public enum TransferPriority: String, Codable, Sendable, CaseIterable {
  /// Pause transfers while other programs keep the internal disk busy.
  case background
  /// Transfer at normal priority, never pausing.
  case normal
}

/// A request to the agent.
public enum Call: Sendable, Equatable {
  case status
  case subscribe
  case refresh
  case scan
  case rootsAdd(path: String, dryRun: Bool)
  case rootsRemove(path: String, copy: Bool)
  case eject
  case quit
  case detach
  case attach
  case pause
  case resume
  case setTransferPriority(TransferPriority)
  /// Turning a kind off releases its folders, copying them back with `copy`.
  case setKindEnabled(kind: String, enabled: Bool, copy: Bool)
  case doctor(fix: Bool)
  case bench(quick: Bool)
  case setUsage(Usage)
  case recordLicense(orderID: String, licensee: String?)
}

struct Request: Encodable {
  var id: UInt64
  var call: Call

  private enum CodingKeys: String, CodingKey {
    case id
    case method
    case params
  }

  private struct RootParams: Encodable {
    var path: String
    var dryRun: Bool?
    var copy: Bool?
  }

  private struct KindParams: Encodable {
    var kind: String
    var enabled: Bool
    var copy: Bool
  }

  private struct LicenseParams: Encodable {
    var orderId: String
    var licensee: String?

    private enum CodingKeys: String, CodingKey {
      case orderId
      case licensee
    }

    func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(orderId, forKey: .orderId)
      try container.encode(licensee, forKey: .licensee)
    }
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    switch call {
    case .status: try container.encode("status", forKey: .method)
    case .subscribe: try container.encode("subscribe", forKey: .method)
    case .refresh: try container.encode("refresh", forKey: .method)
    case .scan: try container.encode("scan", forKey: .method)
    case .eject: try container.encode("eject", forKey: .method)
    case .quit: try container.encode("quit", forKey: .method)
    case .detach: try container.encode("detach", forKey: .method)
    case .attach: try container.encode("attach", forKey: .method)
    case .pause: try container.encode("pause", forKey: .method)
    case .resume: try container.encode("resume", forKey: .method)
    case .setTransferPriority(let priority):
      try container.encode("set-transfer-priority", forKey: .method)
      try container.encode(["priority": priority], forKey: .params)
    case .setKindEnabled(let kind, let enabled, let copy):
      try container.encode("set-kind-enabled", forKey: .method)
      try container.encode(KindParams(kind: kind, enabled: enabled, copy: copy), forKey: .params)
    case .rootsAdd(let path, let dryRun):
      try container.encode("roots-add", forKey: .method)
      try container.encode(RootParams(path: path, dryRun: dryRun), forKey: .params)
    case .rootsRemove(let path, let copy):
      try container.encode("roots-remove", forKey: .method)
      try container.encode(RootParams(path: path, copy: copy), forKey: .params)
    case .doctor(let fix):
      try container.encode("doctor", forKey: .method)
      try container.encode(["fix": fix], forKey: .params)
    case .bench(let quick):
      try container.encode("bench", forKey: .method)
      try container.encode(["quick": quick], forKey: .params)
    case .setUsage(let usage):
      try container.encode("set-usage", forKey: .method)
      try container.encode(["usage": usage], forKey: .params)
    case .recordLicense(let orderID, let licensee):
      try container.encode("record-license", forKey: .method)
      try container.encode(LicenseParams(orderId: orderID, licensee: licensee), forKey: .params)
    }
  }
}

/// The agent's reply, without its typed result.
struct ResponseHeader: Decodable {
  var id: UInt64
  var ok: Bool
  var error: String?
}

struct ResponseBody<T: Decodable>: Decodable {
  var result: T?
}

public enum StowawayJSON {
  public static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }

  public static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  /// Encodes a request as one line of the wire protocol.
  public static func requestLine(id: UInt64, call: Call) throws -> Data {
    var data = try encoder.encode(Request(id: id, call: call))
    data.append(0x0A)
    return data
  }
}
