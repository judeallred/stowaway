import Foundation

/// Creates a small sample workspace (a web project with node_modules and a Rust project with
/// build files) so people can try Stowaway, and App Review can test it, without touching real
/// projects. The contents are generated filler shaped like the real thing; nothing in it runs.
public enum SampleProject {
  public static let folderName = "Stowaway Sample"

  /// Writes the sample into `parent` and returns its folder. Fails if it already exists.
  @discardableResult
  public static func create(in parent: URL) throws -> URL {
    let root = parent.appendingPathComponent(folderName)
    let fm = FileManager.default
    guard !fm.fileExists(atPath: root.path) else {
      throw StowawayError("\(root.path) already exists")
    }
    try fm.createDirectory(at: root, withIntermediateDirectories: false)
    try write(
      root.appendingPathComponent("README.txt"),
      """
      A sample created by Stowaway, for trying it out. It's safe to stow, bring back or delete
      anything in here, or to delete this whole folder.
      """)

    // A web project: package.json and a node_modules folder with a few dozen packages.
    let web = root.appendingPathComponent("web-app")
    let packages = (1...40).map { "sample-package-\($0)" } + ["@sample/ui", "@sample/icons"]
    let dependencies = packages.map { "\"\($0)\": \"1.0.0\"" }.joined(separator: ", ")
    try write(
      web.appendingPathComponent("package.json"),
      "{ \"name\": \"web-app\", \"private\": true, \"dependencies\": { \(dependencies) } }\n")
    try write(web.appendingPathComponent("index.js"), "console.log('hello from the sample')\n")
    for (i, name) in packages.enumerated() {
      let package = web.appendingPathComponent("node_modules").appendingPathComponent(name)
      try write(
        package.appendingPathComponent("package.json"),
        "{ \"name\": \"\(name)\", \"version\": \"1.0.0\", \"main\": \"index.js\" }\n")
      try write(
        package.appendingPathComponent("index.js"), "module.exports = require('./lib/main')\n")
      for file in 0..<12 {
        try write(
          package.appendingPathComponent("lib/module-\(file).js"),
          filler(bytes: 24_000 + (i * 997 + file * 131) % 9_000))
      }
    }

    // A Rust project: Cargo.toml and a target folder with build files.
    let rust = root.appendingPathComponent("rust-tool")
    try write(
      rust.appendingPathComponent("Cargo.toml"),
      "[package]\nname = \"rust-tool\"\nversion = \"0.1.0\"\nedition = \"2021\"\n")
    try write(
      rust.appendingPathComponent("src/main.rs"),
      "fn main() { println!(\"hello from the sample\"); }\n")
    let target = rust.appendingPathComponent("target")
    try write(
      target.appendingPathComponent("CACHEDIR.TAG"), "Signature: 8a477f597d28d172789f06886806bc55\n"
    )
    for part in ["deps", "incremental", "build"] {
      for file in 0..<10 {
        try write(
          target.appendingPathComponent("debug/\(part)/sample-\(file).rlib"), filler(bytes: 300_000)
        )
      }
    }
    return root
  }

  private static func write(_ url: URL, _ text: String) throws {
    try write(url, Data(text.utf8))
  }

  private static func write(_ url: URL, _ data: Data) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
  }

  /// Lines of random text, which compress poorly, so the sizes shown are real.
  private static func filler(bytes: Int) -> Data {
    let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789".utf8)
    var generator = SystemRandomNumberGenerator()
    var out = [UInt8](repeating: 0, count: bytes)
    for i in out.indices {
      out[i] = i % 80 == 79 ? 0x0A : alphabet[Int(generator.next() % UInt64(alphabet.count))]
    }
    return Data(out)
  }
}
