// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import CoreVideo
import Foundation
import LDTXCapture
import LDTXProgram
import OSLog

public final class WorkspaceCaptureSessionCoordinator: @unchecked Sendable {
  public let audioEngine: WorkspaceAudioEngine

  public struct AudioSubscription: Hashable, Sendable {
    fileprivate let id: UUID
    fileprivate let deviceID: String
  }

  private static let logger = Logger(
    subsystem: "tokyo.kaito.ldtx",
    category: "WorkspaceCaptureSessionCoordinator"
  )
  private static let reconnectQueue = DispatchQueue(
    label: "tokyo.kaito.ldtx.WorkspaceCaptureSessionCoordinator.reconnect")
  private static let reconnectDelays: [DispatchTimeInterval] = [
    .milliseconds(0), .milliseconds(250), .seconds(1), .seconds(2), .seconds(5), .seconds(10),
  ]
  private var tickHandlersByObserver: [UUID: @Sendable (UInt64) -> Void] = [:]
  private var capturesByCameraID: [String: WorkspaceCaptureSessionCapture] = [:]
  private var audioCapturesByDeviceID: [String: WorkspaceAudioCapture] = [:]
  // A retired capture remains addressable only while callbacks copied before
  // retirement can still be running.  This preserves unsubscribe's callback
  // fence even after a runtime failure removes the physical capture.
  private var retiredAudioCapturesByDeviceID: [String: [WorkspaceAudioCapture]] = [:]
  private var inputDeviceCaptureRequests: Set<WorkspaceCaptureSessionRequest> = []
  private var isStopping = false
  private var pendingStartCount = 0
  private var pendingStopCount = 0
  private var stopCompletionHandlers: [@Sendable () -> Void] = []
  private var tick: UInt64 = 0
  private let stateLock = NSRecursiveLock()
  private let captureServiceFactory: @Sendable () -> any CameraCaptureStreaming
  private let audioCaptureServiceFactory: @Sendable () -> any ProgramAudioCaptureStreaming

  public init(
    captureServiceFactory: @escaping @Sendable () -> any CameraCaptureStreaming = {
      CameraCaptureService()
    }
  ) {
    self.captureServiceFactory = captureServiceFactory
    let engine = WorkspaceAudioEngine()
    self.audioEngine = engine
    self.audioCaptureServiceFactory = { NativeAudioCapture(engine: engine) }
  }

  init(
    captureServiceFactory: @escaping @Sendable () -> any CameraCaptureStreaming,
    audioCaptureServiceFactory: @escaping @Sendable () -> any ProgramAudioCaptureStreaming
  ) {
    self.captureServiceFactory = captureServiceFactory
    self.audioEngine = WorkspaceAudioEngine(hardwareEnabled: false)
    self.audioCaptureServiceFactory = audioCaptureServiceFactory
  }

  @discardableResult
  public func subscribeAudio(
    deviceID: String,
    failureHandler: @escaping @Sendable (CaptureSessionRuntimeFailure) -> Void,
    sampleHandler: @escaping @Sendable (CMSampleBuffer) -> Void,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) -> AudioSubscription {
    let subscription = AudioSubscription(id: UUID(), deviceID: deviceID)
    enum SubscriptionAction {
      case rejected
      case completed
      case waiting(WorkspaceAudioCapture?)
    }
    let action: SubscriptionAction = stateLock.withLock {
      guard !isStopping else { return .rejected }
      let capture: WorkspaceAudioCapture
      if let existing = audioCapturesByDeviceID[deviceID] {
        capture = existing
      } else {
        capture = WorkspaceAudioCapture(
          deviceID: deviceID, service: audioCaptureServiceFactory())
        audioCapturesByDeviceID[deviceID] = capture
      }
      capture.subscribers[subscription.id] = WorkspaceAudioSubscriber(
        failureHandler: failureHandler, sampleHandler: sampleHandler)
      if capture.isStarted {
        return .completed
      }
      capture.startCompletions.append(completionHandler)
      guard !capture.isStarting else { return .waiting(nil) }
      capture.isStarting = true
      pendingStartCount += 1
      return .waiting(capture)
    }
    switch action {
    case .rejected:
      completionHandler(.failure(CancellationError()))
    case .completed:
      completionHandler(.success(()))
    case .waiting(let capture):
      if let capture { startAudioCapture(capture) }
    }
    return subscription
  }

  public func unsubscribeAudio(_ subscription: AudioSubscription) {
    stateLock.withLock {
      guard let capture = audioCapture(for: subscription) else { return }
      capture.subscribers[subscription.id] = nil
      capture.retiredSubscriptionIDs.remove(subscription.id)
    }
  }

  /// Removes a consumer and invokes `completionHandler` after any capture callback
  /// that had already copied its handler has finished invoking that handler.
  ///
  /// This is intentionally a consumer-level fence: it never stops the shared
  /// physical capture.
  public func unsubscribeAudio(
    _ subscription: AudioSubscription,
    completionHandler: @escaping @Sendable () -> Void
  ) {
    let completeImmediately = stateLock.withLock { () -> Bool in
      guard let capture = audioCapture(for: subscription) else {
        return true
      }
      capture.subscribers[subscription.id] = nil
      capture.retiredSubscriptionIDs.remove(subscription.id)
      guard capture.inFlightSampleDispatchCount > 0 else { return true }
      capture.sampleDispatchCompletions.append(completionHandler)
      return false
    }
    if completeImmediately { completionHandler() }
  }

  private func startAudioCapture(_ capture: WorkspaceAudioCapture) {
    capture.service.startAudioCapture(
      audioDeviceID: capture.deviceID,
      failureHandler: { [weak self, weak capture] failure in
        guard let self, let capture else { return }
        self.retireAudioCapture(capture, failure: failure)
      },
      handler: { [weak self, weak capture] sampleBuffer, kind in
        guard kind == .audio, let self, let capture else { return }
        let handlers = self.stateLock.withLock { () -> [@Sendable (CMSampleBuffer) -> Void]? in
          guard self.audioCapturesByDeviceID[capture.deviceID] === capture else { return nil }
          capture.inFlightSampleDispatchCount += 1
          return Array(capture.subscribers.values.map(\.sampleHandler))
        }
        // A callback copied by the capture service can arrive after this
        // capture has been retired. It was never accepted into the dispatch
        // fence, so it must not decrement the in-flight count.
        guard let handlers else { return }
        guard !handlers.isEmpty else {
          self.completeAudioSampleDispatch(for: capture)
          return
        }
        for handler in handlers {
          handler(sampleBuffer)
        }
        self.completeAudioSampleDispatch(for: capture)
      },
      completionHandler: { [weak self, capture] result in
        guard let self else { return }
        let outcome = self.stateLock.withLock {
          () -> (
            [WorkspaceAudioCapture.StartCompletion], wasCancelled: Bool, shouldStop: Bool
          ) in
          self.pendingStartCount -= 1
          capture.isStarting = false
          let startFailed: Bool
          if case .failure = result {
            startFailed = true
          } else {
            startFailed = false
          }
          let wasCancelled = self.isStopping || capture.mustStopAfterStart
          let shouldStop = wasCancelled || startFailed
          if case .success = result, !shouldStop { capture.isStarted = true }
          let completions = capture.startCompletions
          capture.startCompletions = []
          if startFailed, self.audioCapturesByDeviceID[capture.deviceID] === capture {
            self.audioCapturesByDeviceID[capture.deviceID] = nil
            capture.retiredSubscriptionIDs = Set(capture.subscribers.keys)
            capture.subscribers = [:]
            capture.isStarted = false
            if capture.inFlightSampleDispatchCount > 0 {
              self.retiredAudioCapturesByDeviceID[capture.deviceID, default: []].append(capture)
            } else {
              capture.retiredSubscriptionIDs = []
            }
          }
          if shouldStop { self.pendingStopCount += 1 }
          return (completions, wasCancelled, shouldStop)
        }
        // A runtime failure can arrive while AVCaptureSession is still
        // completing its start.  Do not subsequently tell the consumers that
        // this now-retired capture started successfully.
        let completionResult: Result<Void, any Error>
        if outcome.wasCancelled {
          completionResult = .failure(capture.startRuntimeFailure ?? CancellationError())
        } else {
          completionResult = result
        }
        for completion in outcome.0 {
          completion(completionResult)
        }
        if outcome.shouldStop {
          capture.service.stop { [weak self] in self?.completePendingStop() }
        }
        self.finishStopIfPossible()
      })
  }

  private func retireAudioCapture(
    _ capture: WorkspaceAudioCapture,
    failure: CaptureSessionRuntimeFailure
  ) {
    let outcome = stateLock.withLock {
      () -> ([WorkspaceAudioSubscriber], shouldStopNow: Bool) in
      guard audioCapturesByDeviceID[capture.deviceID] === capture else { return ([], false) }
      audioCapturesByDeviceID[capture.deviceID] = nil
      let subscribers = Array(capture.subscribers.values)
      capture.retiredSubscriptionIDs = Set(capture.subscribers.keys)
      capture.subscribers = [:]
      capture.isStarted = false
      if capture.inFlightSampleDispatchCount > 0 {
        retiredAudioCapturesByDeviceID[capture.deviceID, default: []].append(capture)
      }
      if capture.isStarting {
        capture.mustStopAfterStart = true
        capture.startRuntimeFailure = failure
        return (subscribers, false)
      }
      pendingStopCount += 1
      return (subscribers, true)
    }
    for subscriber in outcome.0 {
      subscriber.failureHandler(failure)
    }
    if outcome.shouldStopNow {
      capture.service.stop { [weak self] in self?.completePendingStop() }
    }
  }

  private func completeAudioSampleDispatch(for capture: WorkspaceAudioCapture) {
    let completions = stateLock.withLock { () -> [@Sendable () -> Void] in
      capture.inFlightSampleDispatchCount -= 1
      guard capture.inFlightSampleDispatchCount == 0 else { return [] }
      let completions = capture.sampleDispatchCompletions
      capture.sampleDispatchCompletions = []
      removeRetiredAudioCaptureIfNeeded(capture)
      return completions
    }
    for completion in completions {
      completion()
    }
  }

  private func audioCapture(for subscription: AudioSubscription) -> WorkspaceAudioCapture? {
    if let capture = audioCapturesByDeviceID[subscription.deviceID],
      capture.subscribers[subscription.id] != nil
    {
      return capture
    }
    return retiredAudioCapturesByDeviceID[subscription.deviceID]?.first {
      $0.retiredSubscriptionIDs.contains(subscription.id)
    }
  }

  private func removeRetiredAudioCaptureIfNeeded(_ capture: WorkspaceAudioCapture) {
    guard var retired = retiredAudioCapturesByDeviceID[capture.deviceID] else { return }
    retired.removeAll { $0 === capture }
    if retired.isEmpty {
      retiredAudioCapturesByDeviceID[capture.deviceID] = nil
    } else {
      retiredAudioCapturesByDeviceID[capture.deviceID] = retired
    }
  }

  public func synchronizeInputDeviceCaptures(
    inputDevices: [ProgramInputDeviceRecord],
    availableCameraIDs: Set<String>,
    canvasWidth: Int,
    canvasHeight: Int,
    frameRate: Int,
    completionHandler: @escaping @Sendable (Set<String>) -> Void
  ) {
    guard stateLock.withLock({ !isStopping }) else {
      completionHandler(Set(inputDevices.compactMap(\.physicalDeviceID)))
      return
    }
    audioEngine.synchronizePhysicalInputs(
      Set(
        inputDevices.compactMap {
          $0.kind == .audio ? $0.physicalDeviceID : nil
        }))
    let nextRequests = Set<WorkspaceCaptureSessionRequest>(
      inputDevices.compactMap { inputDevice in
        guard inputDevice.kind == .video,
          let cameraID = inputDevice.physicalDeviceID,
          !cameraID.isEmpty,
          availableCameraIDs.contains(cameraID)
        else {
          return nil
        }
        return Self.inputDeviceCaptureRequest(
          for: cameraID,
          inputDevice: inputDevice,
          canvasWidth: canvasWidth,
          canvasHeight: canvasHeight,
          frameRate: frameRate
        )
      }
    )
    let cameraIDs = stateLock.withLock { () -> Set<String> in
      let previousRequests = inputDeviceCaptureRequests
      inputDeviceCaptureRequests = nextRequests
      return affectedCameraIDs(
        previousRequests: previousRequests,
        nextRequests: nextRequests
      )
    }
    synchronizeCaptures(
      for: Array(cameraIDs),
      failedCameraIDs: [],
      completionHandler: completionHandler
    )
  }

  /// Synchronizes capture hardware from concrete physical-device assignments.
  /// This V4-oriented entry point deliberately does not require a legacy
  /// Workspace input-device record.
  public func synchronizePhysicalInputCaptures(
    videoCameraIDs: Set<String>,
    audioDeviceIDs: Set<String>,
    availableCameraIDs: Set<String>,
    canvasWidth: Int,
    canvasHeight: Int,
    frameRate: Int,
    completionHandler: @escaping @Sendable (Set<String>) -> Void
  ) {
    guard stateLock.withLock({ !isStopping }) else {
      completionHandler(videoCameraIDs)
      return
    }
    audioEngine.synchronizePhysicalInputs(audioDeviceIDs)
    let nextRequests = Set(
      videoCameraIDs.compactMap { cameraID -> WorkspaceCaptureSessionRequest? in
        guard !cameraID.isEmpty, availableCameraIDs.contains(cameraID) else { return nil }
        return WorkspaceCaptureSessionRequest(
          cameraID: cameraID,
          width: canvasWidth,
          height: canvasHeight,
          frameRate: frameRate
        )
      }
    )
    let unavailableCameraIDs = videoCameraIDs.subtracting(availableCameraIDs)
    let cameraIDs = stateLock.withLock { () -> Set<String> in
      let previousRequests = inputDeviceCaptureRequests
      inputDeviceCaptureRequests = nextRequests
      return affectedCameraIDs(
        previousRequests: previousRequests,
        nextRequests: nextRequests
      )
    }
    synchronizeCaptures(
      for: Array(cameraIDs),
      failedCameraIDs: unavailableCameraIDs,
      completionHandler: completionHandler
    )
  }

  public func releaseInputDeviceCaptures(
    completionHandler: @escaping @Sendable () -> Void = {}
  ) {
    let cameraIDs = stateLock.withLock { () -> [String] in
      let previousRequests = inputDeviceCaptureRequests
      inputDeviceCaptureRequests = []
      return Array(Set(previousRequests.map(\.cameraID)))
    }
    synchronizeCaptures(
      for: cameraIDs,
      failedCameraIDs: []
    ) { _ in
      completionHandler()
    }
  }

  public func restartAllCaptureSessions(
    completionHandler: @escaping @Sendable (Set<String>) -> Void
  ) {
    guard stateLock.withLock({ !isStopping }) else {
      completionHandler([])
      return
    }
    let captures = stateLock.withLock {
      let captures = Array(capturesByCameraID.values)
      for capture in captures {
        capture.reconnectWorkItem?.cancel()
        capture.reconnectWorkItem = nil
      }
      return captures
    }
    restartCaptures(
      captures,
      failedCameraIDs: [],
      completionHandler: completionHandler
    )
  }

  private func restartCaptures(
    _ captures: [WorkspaceCaptureSessionCapture],
    failedCameraIDs: Set<String>,
    completionHandler: @escaping @Sendable (Set<String>) -> Void
  ) {
    guard let capture = captures.first else {
      completionHandler(failedCameraIDs)
      return
    }
    let remainingCaptures = Array(captures.dropFirst())
    let request = stateLock.withLock { capture.request }
    capture.captureService.stop { [weak self] in
      guard let self else {
        completionHandler(failedCameraIDs.union([request.cameraID]))
        return
      }
      self.stateLock.withLock {
        self.resetState(for: capture)
      }
      self.startCapture(request: request, capture: capture) { result in
        var nextFailures = failedCameraIDs
        if case .failure = result {
          nextFailures.insert(request.cameraID)
        }
        self.restartCaptures(
          remainingCaptures,
          failedCameraIDs: nextFailures,
          completionHandler: completionHandler
        )
      }
    }
  }

  public func latestPixelBuffer(forCameraID cameraID: String) -> CVPixelBuffer? {
    latestFrame(forCameraID: cameraID)?.pixelBuffer
  }

  public func latestVisionFrame(forCameraID cameraID: String) -> WorkspaceVisionFrame? {
    guard let frame = latestFrame(forCameraID: cameraID) else { return nil }
    return WorkspaceVisionFrame(
      pixelBuffer: frame.pixelBuffer,
      presentationTime: frame.sourcePresentationTime
    )
  }

  public func latestFrame(forCameraID cameraID: String) -> CapturedVideoFrame? {
    stateLock.withLock {
      guard let capture = capturesByCameraID[cameraID] else { return nil }
      return capture.latestFrame
    }
  }

  @discardableResult
  func addTickHandler(_ handler: @escaping @Sendable (UInt64) -> Void) -> UUID {
    stateLock.withLock {
      let observerID = UUID()
      tickHandlersByObserver[observerID] = handler
      handler(tick)
      return observerID
    }
  }

  func removeTickHandler(_ observerID: UUID) {
    _ = stateLock.withLock {
      tickHandlersByObserver.removeValue(forKey: observerID)
    }
  }

  public func stopAndReset(completionHandler: @escaping @Sendable () -> Void = {}) {
    let captureServices = stateLock.withLock { () -> [any CameraCaptureStreaming] in
      isStopping = true
      stopCompletionHandlers.append(completionHandler)
      inputDeviceCaptureRequests = []
      let services = capturesByCameraID.values.map(\.captureService)
      for capture in capturesByCameraID.values {
        capture.reconnectWorkItem?.cancel()
      }
      capturesByCameraID = [:]
      pendingStopCount += services.count
      return services
    }
    let audioServices = stateLock.withLock { () -> [any ProgramAudioCaptureStreaming] in
      let captures = Array(audioCapturesByDeviceID.values)
      for capture in captures where capture.isStarting {
        capture.mustStopAfterStart = true
      }
      let services = captures.map(\.service)
      audioCapturesByDeviceID = [:]
      pendingStopCount += services.count + 1
      return services
    }
    audioEngine.stop { [weak self] in self?.completePendingStop() }
    for captureService in captureServices {
      captureService.stop { [weak self] in
        self?.completePendingStop()
      }
    }
    for captureService in audioServices {
      captureService.stop { [weak self] in self?.completePendingStop() }
    }
    finishStopIfPossible()
  }

  public func isFullyStopped() -> Bool {
    stateLock.withLock {
      !isStopping && pendingStartCount == 0 && pendingStopCount == 0
        && capturesByCameraID.isEmpty
        && audioCapturesByDeviceID.isEmpty
    }
  }

  private func completePendingStop() {
    stateLock.withLock {
      pendingStopCount -= 1
    }
    finishStopIfPossible()
  }

  private func finishStopIfPossible() {
    let handlers = stateLock.withLock { () -> [@Sendable () -> Void] in
      guard isStopping, pendingStartCount == 0, pendingStopCount == 0 else { return [] }
      isStopping = false
      let handlers = stopCompletionHandlers
      stopCompletionHandlers = []
      return handlers
    }
    for handler in handlers {
      handler()
    }
  }

  private static func inputDeviceCaptureRequest(
    for cameraID: String,
    inputDevice: ProgramInputDeviceRecord,
    canvasWidth: Int,
    canvasHeight: Int,
    frameRate: Int
  ) -> WorkspaceCaptureSessionRequest {
    WorkspaceCaptureSessionRequest(
      cameraID: cameraID,
      width: inputDevice.captureWidthOverride ?? canvasWidth,
      height: inputDevice.captureHeightOverride ?? canvasHeight,
      frameRate: inputDevice.captureFrameRateOverride ?? frameRate
    )
  }

  private func stopCapture(
    cameraID: String,
    completionHandler: @escaping @Sendable () -> Void
  ) {
    guard
      let capture = stateLock.withLock({
        let capture = capturesByCameraID.removeValue(forKey: cameraID)
        capture?.reconnectWorkItem?.cancel()
        return capture
      })
    else {
      completionHandler()
      return
    }
    capture.captureService.stop(completionHandler: completionHandler)
  }

  private func synchronizeCaptures(
    for cameraIDs: [String],
    failedCameraIDs: Set<String>,
    completionHandler: @escaping @Sendable (Set<String>) -> Void
  ) {
    guard let cameraID = cameraIDs.first else {
      completionHandler(failedCameraIDs)
      return
    }
    synchronizeCapture(cameraID: cameraID) { [weak self] result in
      guard let self else {
        completionHandler(failedCameraIDs.union([cameraID]))
        return
      }
      var nextFailures = failedCameraIDs
      if case .failure = result {
        nextFailures.insert(cameraID)
      }
      self.synchronizeCaptures(
        for: Array(cameraIDs.dropFirst()),
        failedCameraIDs: nextFailures,
        completionHandler: completionHandler
      )
    }
  }

  private func synchronizeCapture(
    cameraID: String,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) {
    guard let request = stateLock.withLock({ effectiveRequest(for: cameraID) }) else {
      stopCapture(cameraID: cameraID) {
        completionHandler(.success(()))
      }
      return
    }

    if let capture = stateLock.withLock({ capturesByCameraID[cameraID] }) {
      guard stateLock.withLock({ capture.request != request }) else {
        completionHandler(.success(()))
        return
      }
      capture.captureService.stop { [weak self] in
        guard let self else {
          completionHandler(.failure(CancellationError()))
          return
        }
        self.stateLock.withLock {
          capture.reconnectWorkItem?.cancel()
          capture.reconnectWorkItem = nil
          capture.reconnectAttempt = 0
          self.resetState(for: capture)
          capture.update(request: request)
        }
        self.startCapture(request: request, capture: capture) { result in
          if case .failure = result {
            self.stateLock.withLock {
              if self.capturesByCameraID[cameraID] === capture {
                self.capturesByCameraID.removeValue(forKey: cameraID)
              }
            }
          }
          completionHandler(result)
        }
      }
      return
    }

    let capture = WorkspaceCaptureSessionCapture(
      request: request,
      captureService: captureServiceFactory()
    )
    stateLock.withLock {
      capturesByCameraID[cameraID] = capture
    }
    startCapture(request: request, capture: capture) { [weak self] result in
      if case .failure = result {
        self?.stateLock.withLock {
          if self?.capturesByCameraID[cameraID] === capture {
            self?.capturesByCameraID.removeValue(forKey: cameraID)
          }
        }
      }
      completionHandler(result)
    }
  }

  private func effectiveRequest(for cameraID: String) -> WorkspaceCaptureSessionRequest? {
    let retainedRequests = inputDeviceCaptureRequests.filter { $0.cameraID == cameraID }
    guard !retainedRequests.isEmpty else {
      return nil
    }
    return Self.mergedRequest(
      for: cameraID,
      requests: retainedRequests
    )
  }

  private func affectedCameraIDs(
    previousRequests: Set<WorkspaceCaptureSessionRequest>,
    nextRequests: Set<WorkspaceCaptureSessionRequest>
  ) -> Set<String> {
    Set(previousRequests.symmetricDifference(nextRequests).map(\.cameraID))
  }

  private static func mergedRequest(
    for cameraID: String,
    requests: Set<WorkspaceCaptureSessionRequest>
  ) -> WorkspaceCaptureSessionRequest {
    let baseRequest =
      requests.max { lhs, rhs in
        if lhs.pixelCount == rhs.pixelCount {
          return lhs.frameRate < rhs.frameRate
        }
        return lhs.pixelCount < rhs.pixelCount
      } ?? WorkspaceCaptureSessionRequest(cameraID: cameraID, width: 1, height: 1, frameRate: 1)
    return WorkspaceCaptureSessionRequest(
      cameraID: cameraID,
      width: baseRequest.width,
      height: baseRequest.height,
      frameRate: requests.map(\.frameRate).max() ?? baseRequest.frameRate
    )
  }

  private func startCapture(
    request: WorkspaceCaptureSessionRequest,
    capture: WorkspaceCaptureSessionCapture,
    completionHandler: @escaping @Sendable (Result<Void, any Error>) -> Void
  ) {
    guard
      stateLock.withLock({ () -> Bool in
        guard !isStopping else { return false }
        pendingStartCount += 1
        return true
      })
    else {
      capture.captureService.stop {
        completionHandler(.failure(CancellationError()))
      }
      return
    }
    capture.captureService.startCameraCapture(
      cameraID: request.cameraID,
      targetWidth: request.width,
      targetHeight: request.height,
      frameRate: request.frameRate,
      failureHandler: { [weak self, weak capture] failure in
        guard let self, let capture else { return }
        self.handleRuntimeFailure(for: capture, failure: failure)
      },
      configurationHandler: nil,
      handler: { [weak self] sampleBuffer, kind in
        guard kind == .video else {
          return
        }
        guard let coordinator = self else {
          return
        }

        coordinator.stateLock.withLock {
          coordinator.append(sampleBuffer, for: request)
        }
      },
      completionHandler: { [weak self] result in
        guard let self else {
          completionHandler(.failure(CancellationError()))
          return
        }
        let mustStop = self.stateLock.withLock { () -> Bool in
          self.pendingStartCount -= 1
          if self.isStopping {
            self.pendingStopCount += 1
            return true
          }
          return false
        }
        guard mustStop else {
          completionHandler(result)
          return
        }
        capture.captureService.stop {
          self.completePendingStop()
          completionHandler(.failure(CancellationError()))
        }
      }
    )
  }

  private func resetState(for capture: WorkspaceCaptureSessionCapture) {
    capture.latestFrame = nil
    capture.latestFrameSequence = 0
    capture.captureSessionID = UUID()
  }

  private func invalidateLatestFrame(
    for capture: WorkspaceCaptureSessionCapture,
    failure: CaptureSessionRuntimeFailure
  ) {
    let didInvalidate = stateLock.withLock { () -> Bool in
      guard capturesByCameraID[capture.request.cameraID] === capture else { return false }
      capture.latestFrame = nil
      return true
    }
    guard didInvalidate else { return }
    Self.logger.error(
      "Invalidated captured video after runtime failure cameraID=\(capture.request.cameraID, privacy: .public) failure=\(String(describing: failure), privacy: .public)"
    )
  }

  private func handleRuntimeFailure(
    for capture: WorkspaceCaptureSessionCapture,
    failure: CaptureSessionRuntimeFailure
  ) {
    invalidateLatestFrame(for: capture, failure: failure)
    scheduleReconnect(for: capture)
  }

  private func scheduleReconnect(for capture: WorkspaceCaptureSessionCapture) {
    let scheduled = stateLock.withLock { () -> (DispatchWorkItem, DispatchTimeInterval)? in
      guard !isStopping,
        capturesByCameraID[capture.request.cameraID] === capture,
        capture.reconnectWorkItem == nil
      else { return nil }
      let delay = Self.reconnectDelays[
        min(
          capture.reconnectAttempt, Self.reconnectDelays.count - 1)]
      capture.reconnectAttempt += 1
      let workItem = DispatchWorkItem { [weak self, weak capture] in
        guard let self, let capture else { return }
        self.reconnect(capture)
      }
      capture.reconnectWorkItem = workItem
      return (workItem, delay)
    }
    guard let (workItem, delay) = scheduled else { return }
    Self.reconnectQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
  }

  private func reconnect(_ capture: WorkspaceCaptureSessionCapture) {
    let request = stateLock.withLock { () -> WorkspaceCaptureSessionRequest? in
      guard !isStopping, capturesByCameraID[capture.request.cameraID] === capture else {
        return nil
      }
      guard let workItem = capture.reconnectWorkItem, !workItem.isCancelled else {
        capture.reconnectWorkItem = nil
        return nil
      }
      capture.reconnectWorkItem = nil
      return capture.request
    }
    guard let request else { return }
    capture.captureService.stop { [weak self, weak capture] in
      guard let self, let capture else { return }
      let shouldRestart = self.stateLock.withLock { () -> Bool in
        guard !self.isStopping,
          self.capturesByCameraID[request.cameraID] === capture,
          capture.request == request
        else { return false }
        self.resetState(for: capture)
        return true
      }
      guard shouldRestart else { return }
      self.startCapture(request: request, capture: capture) { [weak self, weak capture] result in
        guard let self, let capture else { return }
        switch result {
        case .success:
          Self.logger.notice(
            "Restarted capture after runtime failure cameraID=\(request.cameraID, privacy: .public)"
          )
        case .failure(let error):
          Self.logger.error(
            "Capture restart failed cameraID=\(request.cameraID, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
          )
          self.scheduleReconnect(for: capture)
        }
      }
    }
  }

  private func append(_ sampleBuffer: CMSampleBuffer, for request: WorkspaceCaptureSessionRequest) {
    guard let capture = capturesByCameraID[request.cameraID], capture.request == request else {
      return
    }
    capture.receivedSampleCount += 1
    guard let frame = makeFrame(sampleBuffer, capture: capture) else {
      capture.rejectedSampleCount += 1
      if capture.rejectedSampleCount == 1 || capture.rejectedSampleCount.isMultiple(of: 120) {
        let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        let width = imageBuffer.map(CVPixelBufferGetWidth) ?? 0
        let height = imageBuffer.map(CVPixelBufferGetHeight) ?? 0
        let pixelFormat = imageBuffer.map(CVPixelBufferGetPixelFormatType) ?? 0
        let hasIOSurface = imageBuffer.flatMap(CVPixelBufferGetIOSurface) != nil
        let presentationTime = sampleBuffer.presentationTimeStamp
        Self.logger.error(
          "Rejected captured video sample cameraID=\(request.cameraID, privacy: .public) receivedSampleCount=\(capture.receivedSampleCount, privacy: .public) rejectedSampleCount=\(capture.rejectedSampleCount, privacy: .public) actualWidth=\(width, privacy: .public) actualHeight=\(height, privacy: .public) requestedWidth=\(request.width, privacy: .public) requestedHeight=\(request.height, privacy: .public) pixelFormat=\(pixelFormat, privacy: .public) hasIOSurface=\(hasIOSurface, privacy: .public) ptsValue=\(presentationTime.value, privacy: .public) ptsTimescale=\(presentationTime.timescale, privacy: .public) ptsFlags=\(presentationTime.flags.rawValue, privacy: .public)"
        )
      }
      return
    }
    capture.reconnectWorkItem?.cancel()
    capture.reconnectWorkItem = nil
    capture.reconnectAttempt = 0
    if capture.acceptedSampleCount == 0 {
      let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
      let width = imageBuffer.map(CVPixelBufferGetWidth) ?? 0
      let height = imageBuffer.map(CVPixelBufferGetHeight) ?? 0
      let pixelFormat = imageBuffer.map(CVPixelBufferGetPixelFormatType) ?? 0
      Self.logger.notice(
        "Accepted first captured video sample cameraID=\(request.cameraID, privacy: .public) width=\(width, privacy: .public) height=\(height, privacy: .public) pixelFormat=\(pixelFormat, privacy: .public)"
      )
    }
    capture.acceptedSampleCount += 1
    setLatestFrame(frame, for: capture)
  }

  func reconnectAttemptForTesting(cameraID: String) -> Int? {
    stateLock.withLock { capturesByCameraID[cameraID]?.reconnectAttempt }
  }

  private func makeFrame(
    _ sampleBuffer: CMSampleBuffer,
    capture: WorkspaceCaptureSessionCapture
  ) -> CapturedVideoFrame? {
    guard let sourcePixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
      return nil
    }
    return CapturedVideoFrame(
      pixelBuffer: sourcePixelBuffer,
      sourcePresentationTime: sampleBuffer.presentationTimeStamp,
      captureSessionID: capture.captureSessionID,
      sequenceNumber: capture.latestFrameSequence &+ 1
    )
  }

  private func setLatestFrame(
    _ frame: CapturedVideoFrame,
    for capture: WorkspaceCaptureSessionCapture
  ) {
    capture.latestFrame = frame
    capture.latestFrameSequence = frame.sequenceNumber
    tick &+= 1
    for handler in tickHandlersByObserver.values {
      handler(tick)
    }
  }

}

private struct WorkspaceAudioSubscriber: @unchecked Sendable {
  var failureHandler: @Sendable (CaptureSessionRuntimeFailure) -> Void
  var sampleHandler: @Sendable (CMSampleBuffer) -> Void
}

private final class WorkspaceAudioCapture: @unchecked Sendable {
  typealias StartCompletion = @Sendable (Result<Void, any Error>) -> Void

  let deviceID: String
  let service: any ProgramAudioCaptureStreaming
  var subscribers: [UUID: WorkspaceAudioSubscriber] = [:]
  var startCompletions: [StartCompletion] = []
  var isStarting = false
  var isStarted = false
  var mustStopAfterStart = false
  var startRuntimeFailure: CaptureSessionRuntimeFailure?
  var retiredSubscriptionIDs: Set<UUID> = []
  var inFlightSampleDispatchCount = 0
  var sampleDispatchCompletions: [@Sendable () -> Void] = []

  init(deviceID: String, service: any ProgramAudioCaptureStreaming) {
    self.deviceID = deviceID
    self.service = service
  }
}

public struct WorkspaceVisionFrame: @unchecked Sendable {
  public let pixelBuffer: CVPixelBuffer
  public let presentationTime: CMTime

  public init(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
    self.pixelBuffer = pixelBuffer
    self.presentationTime = presentationTime
  }
}

/// Mutable capture state. Access is serialized by its owning coordinator's
/// `stateLock`; the instance is never exposed outside that owner.
private final class WorkspaceCaptureSessionCapture: @unchecked Sendable {
  var request: WorkspaceCaptureSessionRequest
  let captureService: any CameraCaptureStreaming
  var latestFrame: CapturedVideoFrame?
  var captureSessionID = UUID()
  var latestFrameSequence: UInt64 = 0
  var receivedSampleCount = 0
  var acceptedSampleCount = 0
  var rejectedSampleCount = 0
  var reconnectAttempt = 0
  var reconnectWorkItem: DispatchWorkItem?

  init(
    request: WorkspaceCaptureSessionRequest,
    captureService: any CameraCaptureStreaming
  ) {
    self.request = request
    self.captureService = captureService
  }

  func update(request: WorkspaceCaptureSessionRequest) {
    self.request = request
  }
}

struct WorkspaceCaptureSessionRequest: Hashable, Sendable {
  var cameraID: String
  var width: Int
  var height: Int
  var frameRate: Int

  init(cameraID: String, width: Int, height: Int, frameRate: Int) {
    self.cameraID = cameraID
    self.width = max(width, 1)
    self.height = max(height, 1)
    self.frameRate = max(frameRate, 1)
  }

  var pixelCount: Int {
    width * height
  }
}

public struct CapturedVideoFrame: @unchecked Sendable {
  public let pixelBuffer: CVPixelBuffer
  public let sourcePresentationTime: CMTime
  let captureSessionID: UUID
  let sequenceNumber: UInt64
}
