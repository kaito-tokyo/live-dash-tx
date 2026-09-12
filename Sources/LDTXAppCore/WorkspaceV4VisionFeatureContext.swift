// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import Foundation
import LDTXWorkspace

/// Supplies one V4 Vision feature with live V4 Workspace input frames.
@MainActor
public struct WorkspaceV4VisionFeatureContext {
  public var vision: (UInt64) -> Ldtx_Workspace_V4_OcrVision?
  public var frameForVision: (Ldtx_Workspace_V4_OcrVision) throws -> WorkspaceVisionAnalysisFrame
  public var reportResult: (UInt64, String) -> Void
  public var reportFailure: (UInt64, Error) -> Void
  public var archiveResult: ((UInt64, CIImage, String) -> Void)?
  public var recordingTimelineMilliseconds: (() -> UInt64?)?

  public init(
    vision: @escaping (UInt64) -> Ldtx_Workspace_V4_OcrVision?,
    frameForVision: @escaping (Ldtx_Workspace_V4_OcrVision) throws -> WorkspaceVisionAnalysisFrame,
    reportResult: @escaping (UInt64, String) -> Void,
    reportFailure: @escaping (UInt64, Error) -> Void,
    archiveResult: ((UInt64, CIImage, String) -> Void)? = nil,
    recordingTimelineMilliseconds: (() -> UInt64?)? = nil
  ) {
    self.vision = vision
    self.frameForVision = frameForVision
    self.reportResult = reportResult
    self.reportFailure = reportFailure
    self.archiveResult = archiveResult
    self.recordingTimelineMilliseconds = recordingTimelineMilliseconds
  }
}

/// The image submitted to a V4 Vision analysis.
public struct WorkspaceVisionAnalysisFrame: @unchecked Sendable {
  public let image: CIImage

  public init(image: CIImage) {
    self.image = image
  }
}

/// Failures raised while resolving a V4 Vision input frame.
public enum WorkspaceVisionFeatureError: Error, Equatable, Sendable {
  case referencedInputDeviceMissing
  case inputDeviceHasNoPhysicalCamera
  case frameUnavailable
}
