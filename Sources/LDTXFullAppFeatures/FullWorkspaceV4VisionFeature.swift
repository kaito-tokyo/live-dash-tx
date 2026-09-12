// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreImage
import Foundation
import LDTXAppCore
import LDTXTaskQueue
import LDTXVision
import LDTXWorkspace
import Observation

/// Runs V4 OCR Visions directly from V4 protobuf definitions.
@MainActor
@Observable
public final class FullWorkspaceV4VisionFeature: WorkspaceV4VisionFeatureProviding {
  public private(set) var resultsByVisionInternalID: [UInt64: String] = [:]

  @ObservationIgnored private let ocrService = VisionOCRService()
  @ObservationIgnored private var timers: [DispatchSourceTimer] = []
  @ObservationIgnored private var analysisTasks: [UInt64: Task<Void, Never>] = [:]
  @ObservationIgnored private var analysisTaskGenerations: [UInt64: UUID] = [:]

  public init() {}

  public func synchronize(
    visions: [Ldtx_Workspace_V4_VisionWrapper],
    context: WorkspaceV4VisionFeatureContext
  ) {
    stop()
    let ocrVisions = visions.compactMap { wrapper -> Ldtx_Workspace_V4_OcrVision? in
      guard case .ocrVision(let vision)? = wrapper.definition else { return nil }
      return vision
    }
    let validIDs = Set(ocrVisions.map(\.internalID))
    resultsByVisionInternalID = resultsByVisionInternalID.filter { validIDs.contains($0.key) }
    for vision in ocrVisions {
      for trigger in vision.triggers {
        guard case .intervalTrigger(let interval)? = trigger.definition,
          interval.intervalSeconds > 0
        else { continue }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
          deadline: .now() + interval.intervalSeconds,
          repeating: interval.intervalSeconds
        )
        timer.setEventHandler { [weak self] in self?.submit(vision.internalID, context: context) }
        timer.resume()
        timers.append(timer)
      }
    }
  }

  public func stop() {
    for timer in timers { timer.cancel() }
    timers = []
    for task in analysisTasks.values { task.cancel() }
    analysisTasks = [:]
    analysisTaskGenerations = [:]
  }

  public func submit(visionInternalID: UInt64, context: WorkspaceV4VisionFeatureContext) {
    submit(visionInternalID, context: context)
  }

  private func submit(_ internalID: UInt64, context: WorkspaceV4VisionFeatureContext) {
    guard analysisTasks[internalID] == nil,
      let vision = context.vision(internalID)
    else { return }
    let generation = UUID()
    analysisTaskGenerations[internalID] = generation
    analysisTasks[internalID] = Task { [weak self, ocrService] in
      guard let self else { return }
      defer {
        if self.analysisTaskGenerations[internalID] == generation {
          self.analysisTasks[internalID] = nil
          self.analysisTaskGenerations[internalID] = nil
        }
      }
      do {
        let frame = try context.frameForVision(vision)
        let result = try await ocrService.recognizeText(
          in: frame.image,
          configuration: Self.ocrConfiguration(for: vision),
          stopToken: .neverStopped
        )
        guard !Task.isCancelled, context.vision(internalID) == vision else { return }
        self.resultsByVisionInternalID[internalID] = result.output
        context.reportResult(internalID, result.output)
        context.archiveResult?(internalID, frame.image, result.output)
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        context.reportFailure(internalID, error)
      }
    }
  }

  static func ocrConfiguration(for vision: Ldtx_Workspace_V4_OcrVision) -> VisionOCRConfiguration {
    VisionOCRConfiguration(
      prefersAccurateRecognition: vision.accurate,
      recognitionLanguages: vision.recognitionLanguages,
      usesLanguageCorrection: vision.usesLanguageCorrection,
      customWords: vision.customWords,
      minimumTextHeight: vision.hasMinimumTextHeight ? vision.minimumTextHeight : nil
    )
  }
}
