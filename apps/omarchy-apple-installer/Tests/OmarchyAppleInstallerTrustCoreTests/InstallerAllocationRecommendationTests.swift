import XCTest

@testable import OmarchyAppleInstallerTrustCore

final class InstallerAllocationRecommendationTests: XCTestCase {
  private let gib: UInt64 = 1_073_741_824

  func testResizeCeilingWithholdsADriftMargin() throws {
    let resize = candidate(
      kind: "resize",
      source: "disk0s2",
      length: 600 * gib,
      minimumInstall: 64 * gib,
      minimumContainer: 200 * gib
    )

    let recommendation = try InstallerAllocationRecommendation(
      inventory: inventory([resize])
    )

    // 400 GiB of headroom, 5% of it withheld.
    XCTAssertEqual(recommendation.absoluteMaximumBytes, 400 * gib)
    XCTAssertEqual(recommendation.maximumBytes, 380 * gib)
  }

  func testFreeExtentKeepsItsFullCeiling() throws {
    let free = candidate(
      kind: "free",
      source: "disk0s3",
      length: 300 * gib,
      minimumInstall: 64 * gib
    )

    let recommendation = try InstallerAllocationRecommendation(
      inventory: inventory([free])
    )

    // A free extent is fixed on the partition map, so nothing is withheld.
    XCTAssertEqual(recommendation.maximumBytes, 300 * gib)
    XCTAssertEqual(
      recommendation.absoluteMaximumBytes,
      recommendation.maximumBytes
    )
  }

  func testMarginIsSkippedWhenItWouldMakeADiskUninstallable() throws {
    // Headroom only just clears the minimum install: withholding the margin
    // here would turn a working disk into "no eligible candidate".
    let resize = candidate(
      kind: "resize",
      source: "disk0s2",
      length: 266 * gib,
      minimumInstall: 64 * gib,
      minimumContainer: 200 * gib
    )

    let recommendation = try InstallerAllocationRecommendation(
      inventory: inventory([resize])
    )

    XCTAssertEqual(recommendation.maximumBytes, 66 * gib)
    XCTAssertEqual(recommendation.absoluteMaximumBytes, 66 * gib)
  }

  /// The layout this reproduces is the one that refused four installs on an
  /// M2 Max: a 494.4 GB container whose live minimum left 383.1 GB of
  /// headroom, approved at the ceiling and recomputed lower at admission.
  func testObservedM2MaxLayoutKeepsHeadroom() throws {
    let resize = candidate(
      kind: "resize",
      source: "disk0s2",
      length: 494_384_795_648,
      minimumInstall: 76_562_825_216,
      minimumContainer: 111_240_282_112
    )

    let recommendation = try InstallerAllocationRecommendation(
      inventory: inventory([resize])
    )

    // 383_144_513_536 of headroom, aligned down to the 1 MiB unit.
    XCTAssertEqual(recommendation.absoluteMaximumBytes, 383_144_427_520)
    XCTAssertLessThan(
      recommendation.maximumBytes,
      recommendation.absoluteMaximumBytes
    )
    XCTAssertGreaterThan(
      recommendation.absoluteMaximumBytes - recommendation.maximumBytes,
      19_000_000_000
    )
  }

  func testPrefersFreeExtentAndBalancedTarget() throws {
    let resize = candidate(
      kind: "resize",
      source: "disk0s2",
      length: 600 * gib,
      minimumInstall: 64 * gib,
      minimumContainer: 200 * gib
    )
    let free = candidate(
      kind: "free",
      source: "disk0s3",
      length: 300 * gib,
      minimumInstall: 64 * gib
    )

    let recommendation = try InstallerAllocationRecommendation(
      inventory: inventory([resize, free])
    )

    XCTAssertEqual(recommendation.candidate, free)
    XCTAssertEqual(recommendation.requestedLengthBytes, 128 * gib)
  }

  func testClampsToAlignedMaximumWithoutViolatingMinimum() throws {
    let unit = PinnedAsahiPlanRequest.allocationUnitBytes
    let free = candidate(
      kind: "free",
      source: "disk0s3",
      length: 90 * gib + 333,
      minimumInstall: 64 * gib + 1
    )

    let recommendation = try InstallerAllocationRecommendation(
      inventory: inventory([free])
    )

    XCTAssertEqual(recommendation.requestedLengthBytes % unit, 0)
    XCTAssertLessThanOrEqual(
      recommendation.requestedLengthBytes,
      free.lengthBytes
    )
    XCTAssertGreaterThanOrEqual(
      recommendation.requestedLengthBytes,
      free.minimumInstallBytes
    )
  }

  func testFailsClosedWhenNoCandidateCanMeetMinimum() {
    let free = candidate(
      kind: "free",
      source: "disk0s3",
      length: 32 * gib,
      minimumInstall: 64 * gib
    )

    XCTAssertThrowsError(
      try InstallerAllocationRecommendation(inventory: inventory([free]))
    ) {
      XCTAssertEqual(
        $0 as? InstallerAllocationRecommendationError,
        .noEligibleCandidate
      )
    }
  }

  func testReplaceOnlyInventoryFailsClosed() {
    let replace = candidate(
      kind: "replace",
      source: "disk0s3",
      length: 300 * gib,
      minimumInstall: 64 * gib,
      identityDigest: "sha256:" + String(repeating: "9", count: 64)
    )

    XCTAssertThrowsError(
      try InstallerAllocationRecommendation(inventory: inventory([replace]))
    ) {
      XCTAssertEqual(
        $0 as? InstallerAllocationRecommendationError,
        .noEligibleCandidate
      )
    }
  }

  func testReplaceCandidateIsNeverAutoSelected() throws {
    let replace = candidate(
      kind: "replace",
      source: "disk0s2",
      length: 600 * gib,
      minimumInstall: 64 * gib,
      identityDigest: "sha256:" + String(repeating: "9", count: 64)
    )
    let free = candidate(
      kind: "free",
      source: "disk0s3",
      length: 300 * gib,
      minimumInstall: 64 * gib
    )

    let recommendation = try InstallerAllocationRecommendation(
      inventory: inventory([replace, free])
    )

    XCTAssertEqual(recommendation.candidate, free)
  }

  private func inventory(
    _ candidates: [ValidatedEngineCandidate]
  ) -> ValidatedEngineInventory {
    ValidatedEngineInventory(
      layoutDigest: "sha256:" + String(repeating: "a", count: 64),
      systemStoreIdentifier: "disk0",
      candidates: candidates
    )
  }

  private func candidate(
    kind: String,
    source: String,
    length: UInt64,
    minimumInstall: UInt64,
    minimumContainer: UInt64 = 0,
    identityDigest: String? = nil
  ) -> ValidatedEngineCandidate {
    ValidatedEngineCandidate(
      kind: kind,
      sourceIdentifier: source,
      offsetBytes: 0,
      lengthBytes: length,
      minimumInstallBytes: minimumInstall,
      minimumContainerBytes: minimumContainer,
      identityDigest: identityDigest
    )
  }
}
