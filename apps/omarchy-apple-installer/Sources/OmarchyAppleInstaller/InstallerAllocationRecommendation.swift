import Foundation

public enum InstallerAllocationRecommendationError:
  Error, Equatable, Sendable
{
  case noEligibleCandidate
}

public struct InstallerAllocationRecommendation:
  Equatable, Sendable
{
  public static let balancedTargetBytes: UInt64 = 137_438_953_472

  /// Headroom withheld from a resize candidate's ceiling so an approved
  /// extent survives ordinary disk churn between planning and execution.
  ///
  /// `minimumContainerBytes` is derived from live container usage, and the
  /// layout digest does not cover it, so the engine recomputes a different
  /// ceiling at admission time than the one the person approved. Offering
  /// the exact ceiling therefore fails whenever anything is written to the
  /// volume in between -- including the installer's own multi-gigabyte
  /// payload staging -- and the engine can only refuse.
  public static let resizeDriftMarginFraction = 0.05

  /// A floor for the fraction above, so small disks keep a usable margin.
  public static let minimumResizeDriftMarginBytes: UInt64 = 2_147_483_648

  /// The ceiling a resize candidate can be approved at, and the safe ceiling
  /// offered by default. The margin is skipped when it would push the
  /// candidate below its own minimum install size, so a disk that barely
  /// fits stays installable.
  public static func resizeCeilings(
    lengthBytes: UInt64,
    minimumContainerBytes: UInt64,
    minimumInstallBytes: UInt64
  ) -> (absolute: UInt64, safe: UInt64) {
    guard lengthBytes > minimumContainerBytes else { return (0, 0) }
    let absolute = lengthBytes - minimumContainerBytes
    let margin = max(
      minimumResizeDriftMarginBytes,
      UInt64(Double(absolute) * resizeDriftMarginFraction)
    )
    guard absolute > margin, absolute - margin >= minimumInstallBytes else {
      return (absolute, absolute)
    }
    return (absolute, absolute - margin)
  }

  public let candidate: ValidatedEngineCandidate
  public let minimumBytes: UInt64
  /// The default ceiling: the absolute ceiling less the drift margin.
  public let maximumBytes: UInt64
  /// The ceiling the engine would accept right now, offered only behind an
  /// explicit opt-in because disk churn can invalidate it before execution.
  public let absoluteMaximumBytes: UInt64
  public let requestedLengthBytes: UInt64

  public init(
    inventory: ValidatedEngineInventory,
    targetBytes: UInt64 = Self.balancedTargetBytes
  ) throws {
    let unit = PinnedAsahiPlanRequest.allocationUnitBytes
    let ranked = inventory.candidates.compactMap { candidate -> Ranked? in
      let maximum: UInt64
      let absoluteMaximum: UInt64
      if candidate.kind == "free" {
        // A free extent is fixed on the partition map: nothing recomputes it
        // between planning and execution, so it needs no margin.
        maximum = candidate.lengthBytes
        absoluteMaximum = candidate.lengthBytes
      } else if candidate.kind == "resize",
        candidate.lengthBytes > candidate.minimumContainerBytes
      {
        let ceilings = Self.resizeCeilings(
          lengthBytes: candidate.lengthBytes,
          minimumContainerBytes: candidate.minimumContainerBytes,
          minimumInstallBytes: candidate.minimumInstallBytes
        )
        maximum = ceilings.safe
        absoluteMaximum = ceilings.absolute
      } else {
        return nil
      }

      let minimum = Self.alignUp(
        candidate.minimumInstallBytes,
        unit: unit
      )
      let alignedMaximum = maximum - (maximum % unit)
      guard minimum <= alignedMaximum else {
        return nil
      }
      return Ranked(
        candidate: candidate,
        minimum: minimum,
        maximum: alignedMaximum,
        absoluteMaximum: absoluteMaximum - (absoluteMaximum % unit)
      )
    }.sorted { left, right in
      if left.candidate.kind != right.candidate.kind {
        return left.candidate.kind == "free"
      }
      if left.maximum != right.maximum {
        return left.maximum > right.maximum
      }
      return left.candidate.sourceIdentifier
        < right.candidate.sourceIdentifier
    }

    guard let selected = ranked.first else {
      throw InstallerAllocationRecommendationError.noEligibleCandidate
    }
    let alignedTarget = targetBytes - (targetBytes % unit)
    candidate = selected.candidate
    minimumBytes = selected.minimum
    maximumBytes = selected.maximum
    absoluteMaximumBytes = max(selected.absoluteMaximum, selected.maximum)
    requestedLengthBytes = min(
      selected.maximum,
      max(selected.minimum, alignedTarget)
    )
  }

  private static func alignUp(
    _ value: UInt64,
    unit: UInt64
  ) -> UInt64 {
    let remainder = value % unit
    guard remainder != 0 else {
      return value
    }
    let adjustment = unit - remainder
    let (result, overflow) = value.addingReportingOverflow(adjustment)
    return overflow ? UInt64.max : result
  }

  private struct Ranked {
    let candidate: ValidatedEngineCandidate
    let minimum: UInt64
    let maximum: UInt64
    let absoluteMaximum: UInt64
  }
}
