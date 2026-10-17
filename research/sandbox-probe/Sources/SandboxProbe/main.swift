import AppKit
import ServiceManagement
import SwiftUI

// `--headless` runs every probe and prints the report, so it can be driven from Terminal (the
// sandbox still applies: it comes from the code signature, not from how the app was started).
// `--register-agent` / `--unregister-agent` toggle the sandboxed launch agent.
let arguments = CommandLine.arguments
if arguments.contains("--headless") {
  let report = Report.markdown(ProbeRun.runAll())
  print(report)
  try? report.write(toFile: NSHomeDirectory() + "/report.md", atomically: true, encoding: .utf8)
  exit(0)
}
// `--exec <tool> [args…]` runs one command inside the sandbox, for poking at a single failure.
if let i = arguments.firstIndex(of: "--panel"), i + 1 < arguments.count {
  MainActor.assumeIsolated { Experiments.panel(arguments[i + 1]) }
}
if let i = arguments.firstIndex(of: "--lite-adopt"), i + 1 < arguments.count {
  Experiments.enterBookmarks()
  exit(Lite.adopt(arguments[i + 1]))
}
if let i = arguments.firstIndex(of: "--lite-watch"), i + 1 < arguments.count {
  Experiments.enterBookmarks()
  MainActor.assumeIsolated { Lite.watch(seconds: Double(arguments[i + 1]) ?? 60) }
}
if arguments.contains("--grant") {
  MainActor.assumeIsolated { Experiments.grant() }
}
if let i = arguments.firstIndex(of: "--da-mount"), i + 2 < arguments.count {
  Experiments.enterBookmarks()
  exit(Experiments.daMount(bsd: arguments[i + 1], path: arguments[i + 2]))
}
if let i = arguments.firstIndex(of: "--da-unmount"), i + 1 < arguments.count {
  exit(Experiments.daUnmount(bsd: arguments[i + 1]))
}
if let i = arguments.firstIndex(of: "--exec"), i + 1 < arguments.count {
  Experiments.enterBookmarks()
  let result = sh(arguments[i + 1], Array(arguments[(i + 2)...]))
  print(result.out, terminator: "")
  FileHandle.standardError.write(Data((result.err + (result.launchError ?? "")).utf8))
  exit(result.status)
}
if arguments.contains("--register-agent") || arguments.contains("--unregister-agent") {
  let agent = SMAppService.agent(plistName: ProbeRun.agentPlist)
  do {
    if arguments.contains("--register-agent") { try agent.register() } else { try agent.unregister() }
    print("ok: status \(agent.status.rawValue)")
    exit(0)
  } catch {
    print("failed: \(error)")
    exit(1)
  }
}
ProbeApp.main()

struct ProbeApp: App {
  @State private var model = ProbeModel()

  var body: some Scene {
    WindowGroup("Stowaway Sandbox Probe") {
      ProbeView(model: model).frame(minWidth: 860, minHeight: 560)
    }
  }
}

@MainActor @Observable
final class ProbeModel {
  var results: [ProbeResult] = []
  var running = false
  var paths: [Place: String] = [:]
  var message = ""

  init() { refreshPaths() }

  func refreshPaths() {
    for place in Place.allCases { paths[place] = Bookmarks.path(of: place) }
  }

  func choose(_ place: Place) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = false
    panel.prompt = "Choose"
    panel.message =
      place == .drive
      ? "Choose your external drive (the volume itself, under /Volumes)."
      : "Choose the folder that holds your projects, such as ~/code."
    if place == .drive { panel.directoryURL = URL(fileURLWithPath: "/Volumes") }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try Bookmarks.save(url, as: place)
      refreshPaths()
    } catch {
      message = "Couldn't save the bookmark: \(error.localizedDescription)"
    }
  }

  func run() {
    running = true
    Task.detached {
      let results = ProbeRun.runAll()
      await MainActor.run {
        self.results = results
        self.running = false
        let report = Report.markdown(results)
        try? report.write(toFile: NSHomeDirectory() + "/report.md", atomically: true, encoding: .utf8)
        self.message = "Report saved to \(NSHomeDirectory())/report.md"
      }
    }
  }

  func copyReport() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(Report.markdown(results), forType: .string)
    message = "Copied the report."
  }

  func toggleAgent() {
    let agent = SMAppService.agent(plistName: ProbeRun.agentPlist)
    do {
      if agent.status == .enabled { try agent.unregister() } else { try agent.register() }
      message = "Agent status: \(agent.status.rawValue)"
    } catch {
      message = "Agent: \(error.localizedDescription)"
    }
  }

  func toggleLoginItem() {
    do {
      if SMAppService.mainApp.status == .enabled {
        try SMAppService.mainApp.unregister()
      } else {
        try SMAppService.mainApp.register()
      }
      message = "Login item status: \(SMAppService.mainApp.status.rawValue)"
    } catch {
      message = "Login item: \(error.localizedDescription)"
    }
  }
}

struct ProbeView: View {
  @Bindable var model: ProbeModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Can Stowaway run inside the App Sandbox?").font(.title2.bold())
      Text(
        "Choose the folders a Mac App Store build would have to ask for, then run the probes. Each one exercises something Stowaway does today."
      )
      .foregroundStyle(.secondary)
      ForEach(Place.allCases, id: \.self) { place in
        HStack {
          Text(place.title).frame(width: 110, alignment: .leading)
          Text(model.paths[place] ?? "not chosen").foregroundStyle(model.paths[place] == nil ? .secondary : .primary)
            .lineLimit(1).truncationMode(.middle)
          Spacer()
          Button("Choose…") { model.choose(place) }
          if model.paths[place] != nil {
            Button("Forget") {
              Bookmarks.forget(place)
              model.refreshPaths()
            }
          }
        }
      }
      HStack {
        Button(model.running ? "Running…" : "Run probes") { model.run() }
          .keyboardShortcut(.defaultAction).disabled(model.running)
        Button("Copy report") { model.copyReport() }.disabled(model.results.isEmpty)
        Spacer()
        Button("Toggle launch agent") { model.toggleAgent() }
        Button("Toggle login item") { model.toggleLoginItem() }
      }
      if !model.message.isEmpty { Text(model.message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
      List {
        ForEach(groups, id: \.self) { group in
          Section(group) {
            ForEach(model.results.filter { $0.group == group }) { result in
              ResultRow(result: result)
            }
          }
        }
      }
    }
    .padding()
  }

  private var groups: [String] {
    var seen: [String] = []
    for r in model.results where !seen.contains(r.group) { seen.append(r.group) }
    return seen
  }
}

struct ResultRow: View {
  let result: ProbeResult

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Image(systemName: icon).foregroundStyle(color)
      VStack(alignment: .leading, spacing: 2) {
        Text(result.name).bold()
        if !result.need.isEmpty { Text(result.need).font(.caption).foregroundStyle(.secondary) }
        Text(result.detail).font(.caption.monospaced()).textSelection(.enabled)
      }
    }
  }

  private var icon: String {
    switch result.outcome {
    case .pass: "checkmark.circle.fill"
    case .fail: "xmark.octagon.fill"
    case .skip: "minus.circle"
    case .info: "info.circle"
    }
  }

  private var color: Color {
    switch result.outcome {
    case .pass: .green
    case .fail: .red
    case .skip: .secondary
    case .info: .blue
    }
  }
}
