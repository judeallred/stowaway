import Foundation

/// Pages on the Stowaway website, which is authored separately from the app.
enum Links {
  static let website = page("")
  static let support = page("support")
  static let privacyPolicy = page("privacy")
  /// Apple's standard license agreement, which App Store apps use unless they provide their own.
  static let termsOfUse = url("https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")
  static let issues = url("https://github.com/judeallred/stowaway/issues/new")

  private static func page(_ path: String) -> URL {
    url("https://brooklynspaceport.com/stowaway/" + path)
  }

  private static func url(_ string: String) -> URL {
    guard let url = URL(string: string) else { preconditionFailure("bad URL literal \(string)") }
    return url
  }
}
