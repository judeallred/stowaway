public import Foundation

/// Errors talking to the agent.
public enum AgentError: Error, LocalizedError, Equatable {
  case notRunning
  case closed
  case agent(String)

  public var errorDescription: String? {
    switch self {
    case .notRunning: "The Stowaway agent isn't running."
    case .closed: "The Stowaway agent closed the connection."
    case .agent(let message): message
    }
  }
}

/// Talks to the agent over its Unix socket (crates/stowaway/src/ipc.rs).
public struct AgentClient: Sendable {
  public let socketPath: String

  public init(socketPath: String = AgentClient.defaultSocketPath()) {
    self.socketPath = socketPath
  }

  /// Mirrors `Layout::socket_path` in Rust, including the fallback for long paths.
  public static func defaultSocketPath(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: String = NSHomeDirectory()
  ) -> String {
    let stateDir =
      environment["STOWAWAY_HOME"] ?? (home as NSString).appendingPathComponent(".stowaway")
    let preferred = (stateDir as NSString).appendingPathComponent("agent.sock")
    if preferred.utf8.count < 100 {
      return preferred
    }
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in stateDir.utf8 {
      hash = (hash ^ UInt64(byte)) &* 0x0100_0000_01b3
    }
    let attributes = try? FileManager.default.attributesOfItem(atPath: home)
    let uid = (attributes?[.ownerAccountID] as? NSNumber)?.intValue ?? 0
    return "/tmp/stowaway-\(uid)/\(String(format: "%016llx", hash)).sock"
  }

  /// Sends one request and decodes its result.
  public func call<T: Decodable & Sendable>(
    _ call: Call,
    as type: T.Type = T.self
  ) async throws -> T? {
    let handle = try connect()
    defer { try? handle.close() }
    try handle.write(contentsOf: StowawayJSON.requestLine(id: 1, call: call))
    for try await line in handle.bytes.lines {
      let data = Data(line.utf8)
      guard
        let header = try? StowawayJSON.decoder.decode(ResponseHeader.self, from: data),
        header.id == 1
      else { continue }
      guard header.ok else { throw AgentError.agent(header.error ?? "unknown error") }
      return try StowawayJSON.decoder.decode(ResponseBody<T>.self, from: data).result
    }
    throw AgentError.closed
  }

  /// Sends a request whose result doesn't matter.
  public func send(_ call: Call) async throws {
    _ = try await self.call(call, as: EmptyResult.self)
  }

  /// Subscribes to pushed notifications. The stream ends when the agent goes away.
  public func notifications() throws -> AsyncThrowingStream<AgentNotification, any Error> {
    let handle = try connect()
    try handle.write(contentsOf: StowawayJSON.requestLine(id: 1, call: .subscribe))
    return AsyncThrowingStream { continuation in
      let task = Task.detached {
        do {
          for try await line in handle.bytes.lines {
            let data = Data(line.utf8)
            if let note = try? StowawayJSON.decoder.decode(AgentNotification.self, from: data) {
              continuation.yield(note)
            }
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
        try? handle.close()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func connect() throws -> FileHandle {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw AgentError.notRunning }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
      close(fd)
      throw AgentError.notRunning
    }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.copyBytes(from: pathBytes)
      buffer[pathBytes.count] = 0
    }
    let length = socklen_t(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) }
    }
    guard result == 0 else {
      close(fd)
      throw AgentError.notRunning
    }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  }
}

private struct EmptyResult: Decodable, Sendable {}
