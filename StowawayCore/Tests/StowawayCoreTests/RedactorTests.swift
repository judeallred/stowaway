import XCTest

@testable import StowawayCore

final class RedactorTests: XCTestCase {
  private let redactor = Redactor(known: [
    "/Users/someone", "/Volumes/My Drive", "My Drive",
    "/Users/someone/code/secret app/node_modules",
  ])

  func testKnownPathsWithSpacesKeepOnlyTheKindFolder() {
    XCTAssertEqual(
      redactor.redact("Couldn't stow /Users/someone/code/secret app/node_modules: no space."),
      "Couldn't stow [REDACTED]/node_modules: no space.")
  }

  func testUnknownPathsAreRedacted() {
    XCTAssertEqual(
      redactor.redact("copying /tmp/x/report.pdf: Permission denied"),
      "copying [REDACTED]: Permission denied")
    XCTAssertEqual(
      redactor.redact("refusing an unexpected path on the drive: store/acme/target."),
      "refusing an unexpected path on the drive: [REDACTED]/target.")
    XCTAssertEqual(redactor.redact("can't read ~/notes"), "can't read [REDACTED]")
  }

  func testTheDriveNameIsRedacted() {
    XCTAssertEqual(
      redactor.redact("Copying to /Volumes/My Drive/stowaway failed; My Drive is full."),
      "Copying to [REDACTED] failed; [REDACTED] is full.")
  }

  func testQuotedNamesAreRedacted() {
    XCTAssertEqual(
      redactor.redact("The file “taxes 2026.xlsx” couldn’t be opened."),
      "The file “[REDACTED]” couldn’t be opened.")
    XCTAssertEqual(redactor.redact(#"folder "alchemist" is busy"#), #"folder "[REDACTED]" is busy"#)
  }

  func testOrdinaryTextIsKept() {
    let text = "The drive isn't connected. Stowing this would take you past the free 10 GB."
    XCTAssertEqual(redactor.redact(text), text)
  }

  func testRedactingTwiceChangesNothing() {
    let once = redactor.redact("Couldn't stow /Users/someone/code/secret app/node_modules.")
    XCTAssertEqual(redactor.redact(once), once)
  }
}
