// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreMedia
import CoreVideo
import Foundation
import LDTXInternalProtocols
import LDTXProgram
import LDTXProgramRendering
import LDTXVideoComposition
import LDTXVideoRendering
import OSLog
import os

#if canImport(Metal)
  import Metal
#endif

public struct ProgramFrame: @unchecked Sendable {
  public let frameID: UInt64
  public let pixelBuffer: CVPixelBuffer
  public var presentationTime: CMTime?
  public let isPreparingRenderResources: Bool
  let videoPipelineID: UUID

  public init(
    frameID: UInt64,
    pixelBuffer: CVPixelBuffer,
    presentationTime: CMTime?,
    isPreparingRenderResources: Bool = false,
    videoPipelineID: UUID = UUID()
  ) {
    self.frameID = frameID
    self.pixelBuffer = pixelBuffer
    self.presentationTime = presentationTime
    self.isPreparingRenderResources = isPreparingRenderResources
    self.videoPipelineID = videoPipelineID
  }
}

public enum ProgramFrameDeliveryPolicy: Sendable {
  case latestFrame
}

public final class ProgramFrameSubscription: @unchecked Sendable {
  fileprivate let id: UUID
  fileprivate let mailbox: ProgramFrameMailbox
  private let cancellationLock = NSLock()
  private weak var runtime: ProgramRuntime?

  init(id: UUID, mailbox: ProgramFrameMailbox, runtime: ProgramRuntime) {
    self.id = id
    self.mailbox = mailbox
    self.runtime = runtime
  }

  public func cancel() {
    mailbox.close()
    let runtime = cancellationLock.withLock { () -> ProgramRuntime? in
      defer { self.runtime = nil }
      return self.runtime
    }
    runtime?.removeFrameSubscription(self)
  }

  public func cancelAndDrain() async {
    cancel()
    await mailbox.drain()
  }

  deinit {
    cancel()
  }
}

final class ProgramFrameDeliveryExecutor: @unchecked Sendable {
  let queue: DispatchQueue

  init(label: String = "tokyo.kaito.ldtx.ProgramRuntime.frame-consumer") {
    queue = DispatchQueue(label: label, qos: .userInitiated)
  }
}

final class ProgramFrameMailbox: @unchecked Sendable {
  private struct State {
    var isOpen = true
    var isScheduled = false
    var pendingFrame: ProgramFrame?
    var drainWaiters: [CheckedContinuation<Void, Never>] = []
  }

  private let lock = NSLock()
  private var state = State()
  private let executor: ProgramFrameDeliveryExecutor
  private let handler: (ProgramFrame) -> Void

  init(
    executor: ProgramFrameDeliveryExecutor,
    handler: @escaping (ProgramFrame) -> Void
  ) {
    self.executor = executor
    self.handler = handler
  }

  func submit(_ frame: ProgramFrame) {
    let shouldSchedule = lock.withLock { () -> Bool in
      guard state.isOpen else { return false }
      state.pendingFrame = frame
      guard !state.isScheduled else { return false }
      state.isScheduled = true
      return true
    }
    guard shouldSchedule else { return }
    executor.queue.async { [self] in deliverOneFrame() }
  }

  func close() {
    let waiters = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
      state.isOpen = false
      state.pendingFrame = nil
      guard !state.isScheduled else { return [] }
      let waiters = state.drainWaiters
      state.drainWaiters.removeAll()
      return waiters
    }
    for waiter in waiters { waiter.resume() }
  }

  func drain() async {
    await withCheckedContinuation { continuation in
      let shouldResume = lock.withLock { () -> Bool in
        guard state.isScheduled else { return true }
        state.drainWaiters.append(continuation)
        return false
      }
      if shouldResume { continuation.resume() }
    }
  }

  private func deliverOneFrame() {
    let frame = lock.withLock { () -> ProgramFrame? in
      guard state.isOpen else { return nil }
      let frame = state.pendingFrame
      state.pendingFrame = nil
      return frame
    }
    if let frame { handler(frame) }

    let completion = lock.withLock {
      () -> (reschedule: Bool, waiters: [CheckedContinuation<Void, Never>]) in
      if state.isOpen, state.pendingFrame != nil {
        return (true, [])
      }
      state.isScheduled = false
      let waiters = state.drainWaiters
      state.drainWaiters.removeAll()
      return (false, waiters)
    }
    if completion.reschedule {
      executor.queue.async { [self] in deliverOneFrame() }
    }
    for waiter in completion.waiters { waiter.resume() }
  }
}

#if canImport(Metal)
  extension ProgramFrame {
    public func makeCVMetalTexture(
      using textureCache: CVMetalTextureCache,
      pixelFormat: MTLPixelFormat,
      planeIndex: Int
    ) -> CVMetalTexture? {
      let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
      let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
      var cvMetalTexture: CVMetalTexture?
      let status = CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault,
        textureCache,
        pixelBuffer,
        nil,
        pixelFormat,
        width,
        height,
        planeIndex,
        &cvMetalTexture
      )
      guard status == kCVReturnSuccess,
        let cvMetalTexture
      else {
        return nil
      }
      return cvMetalTexture
    }

    public func makeTexture(
      using textureCache: CVMetalTextureCache,
      pixelFormat: MTLPixelFormat,
      planeIndex: Int
    ) -> MTLTexture? {
      guard
        let cvMetalTexture = makeCVMetalTexture(
          using: textureCache,
          pixelFormat: pixelFormat,
          planeIndex: planeIndex
        )
      else {
        return nil
      }
      return CVMetalTextureGetTexture(cvMetalTexture)
    }
  }
#endif

public final class ProgramRuntime: @unchecked Sendable {
  public typealias FrameHandler = (ProgramFrame) -> Void
  private let lock = NSLock()
  public let programState: ProgramRuntimeState
  public let programDestinationState: ProgramDestinationState
  public let programPreferencesState: ProgramPreferencesState
  private let renderer: ActiveProgramRenderer
  private let scheduler: any ProgramRuntimeScheduling
  private let renderQueue = DispatchQueue(
    label: "tokyo.kaito.ldtx.ProgramRuntime.render", qos: .userInitiated)
  private var renderTimer: DispatchSourceTimer?
  private var framePacer = ProgramFramePacer()
  private var latestPublishedFrame: ProgramFrame?
  private var frameMailboxesByID: [UUID: ProgramFrameMailbox] = [:]
  private var previewConsumerCount = 0
  private var outputConsumerCount = 0
  private var sessionID = 0
  private var nextProducedFrameID: UInt64 = 0

  public init(
    captureSessionCoordinator: WorkspaceCaptureSessionCoordinator,
    backgroundRemovalPreprocessorFactory: BackgroundRemovalPreprocessorFactory? = nil,
    programPreferencesState: ProgramPreferencesState = ProgramPreferencesState(),
    lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry,
    clockCurrentTimeProvider: any ClockCurrentTimeProviding = SystemClockCurrentTimeProvider(),
    scheduler: any ProgramRuntimeScheduling = SystemProgramRuntimeScheduler()
  ) {
    programState = ProgramRuntimeState()
    programDestinationState = ProgramDestinationState()
    self.programPreferencesState = programPreferencesState
    renderer = ActiveProgramRenderer(
      captureSessionCoordinator: captureSessionCoordinator,
      backgroundRemovalPreprocessorFactory: backgroundRemovalPreprocessorFactory,
      programPreferencesState: programPreferencesState,
      lowFrequencyUpdateRegistry: lowFrequencyUpdateRegistry,
      clockCurrentTimeProvider: clockCurrentTimeProvider
    )
    self.scheduler = scheduler
  }

  public func updateProgram(_ configuration: ProgramRuntimeConfiguration) {
    let previousConfiguration = programState.read { $0 }
    if let previousConfiguration,
      previousConfiguration.hasEquivalentInputPipeline(to: configuration)
    {
      programDestinationState.replace(with: configuration.composite)
      lock.withLock {
        ensureRenderLoopLocked()
      }
      return
    }

    let previousSize = previousConfiguration.map { ($0.outputWidth, $0.outputHeight) }
    programState.replace(with: configuration)
    programDestinationState.replace(with: configuration.composite)
    lock.withLock {
      let shouldClearFrame =
        previousSize?.0 != configuration.outputWidth
        || previousSize?.1 != configuration.outputHeight
      if shouldClearFrame {
        latestPublishedFrame = nil
      }
      ensureRenderLoopLocked()
    }
  }

  public func clearProgram() {
    programState.clear()
    lock.withLock { latestPublishedFrame = nil }
  }

  public func updateProgramPreferences(_ preferences: ProgramPreferences) {
    programPreferencesState.replace(with: preferences)
  }

  /// Updates only the canvas placement values used by the compositor.
  ///
  /// This intentionally leaves `programState` unchanged, so a live
  /// Destination adjustment never causes the Metal input pipeline to be
  /// rebuilt or resynchronized.
  public func updateDestinations(from composite: CompositeProgramDefinition) {
    programDestinationState.replace(with: composite)
  }

  public func startPreview() {
    lock.withLock {
      previewConsumerCount += 1
      ensureRenderLoopLocked()
    }
  }

  public func stopPreview() {
    let sessionToEnd = lock.withLock { () -> Int? in
      previewConsumerCount = max(previewConsumerCount - 1, 0)
      return stopRenderLoopIfIdleLocked()
    }
    if let sessionToEnd {
      renderQueue.async { [renderer] in
        renderer.endSession(sessionToEnd)
      }
    }
  }

  public func beginOutput() {
    lock.withLock {
      outputConsumerCount += 1
      ensureRenderLoopLocked()
    }
  }

  public func endOutput() {
    let sessionToEnd = lock.withLock { () -> Int? in
      outputConsumerCount = max(outputConsumerCount - 1, 0)
      return stopRenderLoopIfIdleLocked()
    }
    if let sessionToEnd {
      renderQueue.async { [renderer] in
        renderer.endSession(sessionToEnd)
      }
    }
  }

  public func latestFrame() -> ProgramFrame? {
    lock.withLock {
      latestPublishedFrame
    }
  }

  @discardableResult
  public func subscribeFrames(
    replayLatestFrame: Bool = true,
    policy: ProgramFrameDeliveryPolicy = .latestFrame,
    _ handler: @escaping FrameHandler
  ) -> ProgramFrameSubscription {
    subscribeFrames(
      replayLatestFrame: replayLatestFrame,
      policy: policy,
      executor: ProgramFrameDeliveryExecutor(),
      handler
    )
  }

  func subscribeFrames(
    replayLatestFrame: Bool,
    policy _: ProgramFrameDeliveryPolicy,
    executor: ProgramFrameDeliveryExecutor,
    _ handler: @escaping FrameHandler
  ) -> ProgramFrameSubscription {
    let subscriptionID = UUID()
    let mailbox = ProgramFrameMailbox(executor: executor, handler: handler)
    let latestFrame = lock.withLock { () -> ProgramFrame? in
      frameMailboxesByID[subscriptionID] = mailbox
      ensureRenderLoopLocked()
      return latestPublishedFrame
    }
    if replayLatestFrame, let latestFrame { mailbox.submit(latestFrame) }
    return ProgramFrameSubscription(id: subscriptionID, mailbox: mailbox, runtime: self)
  }

  fileprivate func removeFrameSubscription(_ subscription: ProgramFrameSubscription) {
    let sessionToEnd = lock.withLock { () -> Int? in
      frameMailboxesByID.removeValue(forKey: subscription.id)?.close()
      return stopRenderLoopIfIdleLocked()
    }
    if let sessionToEnd {
      renderQueue.async { [renderer] in
        renderer.endSession(sessionToEnd)
      }
    }
  }

  private func shouldRenderLocked() -> Bool {
    previewConsumerCount > 0 || outputConsumerCount > 0 || !frameMailboxesByID.isEmpty
  }

  private func ensureRenderLoopLocked() {
    guard renderTimer == nil, shouldRenderLocked() else {
      return
    }
    sessionID += 1
    let currentSessionID = sessionID
    let timer = DispatchSource.makeTimerSource(queue: renderQueue)
    timer.setEventHandler { [weak self] in
      self?.renderTick(sessionID: currentSessionID)
    }
    renderTimer = timer
    renderQueue.async { [weak self, renderer] in
      self?.framePacer = ProgramFramePacer()
      renderer.beginSession(currentSessionID)
      timer.schedule(deadline: .now())
      timer.resume()
    }
  }

  private func stopRenderLoopIfIdleLocked() -> Int? {
    guard !shouldRenderLocked() else {
      return nil
    }
    let sessionToEnd = sessionID
    renderTimer?.setEventHandler {}
    renderTimer?.cancel()
    renderTimer = nil
    return sessionToEnd == 0 ? nil : sessionToEnd
  }

  private func nextFrameIDValue() -> UInt64 {
    lock.withLock {
      nextProducedFrameID &+= 1
      return nextProducedFrameID
    }
  }

  private func renderTick(sessionID: Int) {
    dispatchPrecondition(condition: .onQueue(renderQueue))
    guard
      let timer = lock.withLock({ () -> DispatchSourceTimer? in
        guard self.sessionID == sessionID else { return nil }
        return renderTimer
      })
    else {
      renderer.endSession(sessionID)
      return
    }
    guard var configuration = programState.read({ $0 }) else {
      timer.schedule(deadline: .now() + .milliseconds(100))
      return
    }
    let delayNanoseconds = framePacer.delayBeforeNextFrame(
      nowNanoseconds: scheduler.nowNanoseconds,
      frameRate: configuration.frameRate
    )
    if delayNanoseconds > 0 {
      timer.schedule(deadline: .now() + .nanoseconds(Int(clamping: delayNanoseconds)))
      return
    }
    configuration.timeSeconds = Float(scheduler.uptimeSeconds)
    configuration.composite = programDestinationState.applying(to: configuration.composite)
    do {
      let frame = try renderer.render(
        configuration: configuration,
        destinationForStep: { [destinationState = programDestinationState] step in
          destinationState.destination(forStepNamed: step.name)
        },
        sessionID: sessionID,
        frameID: nextFrameIDValue()
      )
      publish(frame)
    } catch {
      if error is CancellationError {
        return
      }
      logProgramRuntimeRenderFailed(error, configuration: configuration)
    }
    timer.schedule(deadline: .now())
  }

  private func publish(_ frame: ProgramFrame) {
    let mailboxes = lock.withLock { () -> [ProgramFrameMailbox] in
      latestPublishedFrame = frame
      return Array(frameMailboxesByID.values)
    }
    if frame.frameID == 1 || frame.frameID.isMultiple(of: 120) {
      programRuntimeLogger.notice(
        "Published program frame frameID=\(frame.frameID, privacy: .public) hasPTS=\(frame.presentationTime != nil, privacy: .public) handlerCount=\(mailboxes.count, privacy: .public)"
      )
    }
    for mailbox in mailboxes { mailbox.submit(frame) }
  }
}

func compositeApplyingVideoLayerMutes(
  _ composite: CompositeProgramDefinition,
  preferences: ProgramPreferences,
  programName: String
) -> CompositeProgramDefinition {
  var result = composite
  result.steps.removeAll { step in
    guard
      preferences.isVideoLayerMuted(
        componentName: step.name,
        programName: programName
      )
    else { return false }
    if case .inputCameraDevice = step.component {
      return false
    }
    return true
  }
  return result
}

/// Mutable rendering state confined to the owning runtime's render queue.
final class ActiveProgramRenderer: @unchecked Sendable {
  typealias ClockOverlayRegistryFactory = (
    MTLDevice,
    LowFrequencyUpdateRegistry,
    any ClockCurrentTimeProviding
  ) throws -> ClockOverlayRuntimeRegistry

  private struct ClockOverlayInitializationConfiguration: Equatable {
    struct Step: Equatable {
      var name: String
      var scalarBitPatterns: [UInt32]
      var showsSeconds: Bool
      var uses24HourTime: Bool
      var showsDate: Bool
      var usesSystemTimeZone: Bool
      var utcOffsetMinutes: Int32
      var background: String
      var outlineDescriptions: [String]

      init(name: String, component: ClockComponent) {
        self.name = name
        scalarBitPatterns = [
          component.destinationX.bitPattern,
          component.destinationY.bitPattern,
          component.destinationWidth.bitPattern,
          component.destinationHeight.bitPattern,
          component.foregroundRed.bitPattern,
          component.foregroundGreen.bitPattern,
          component.foregroundBlue.bitPattern,
          component.foregroundAlpha.bitPattern,
          component.backgroundRed.bitPattern,
          component.backgroundGreen.bitPattern,
          component.backgroundBlue.bitPattern,
          component.backgroundAlpha.bitPattern,
        ]
        showsSeconds = component.showsSeconds
        uses24HourTime = component.uses24HourTime
        showsDate = component.showsDate
        usesSystemTimeZone = component.usesSystemTimeZone
        utcOffsetMinutes = component.utcOffsetMinutes
        background = component.background
        outlineDescriptions = component.outlines.map { "\($0.thickness.bitPattern):\($0.color)" }
      }
    }

    var steps: [Step]
    var outputWidth: Int
    var outputHeight: Int
  }

  private let programPreferencesState: ProgramPreferencesState
  private var activeSessionID: Int?
  private var compositor: VideoCompositor?
  private let captureSessionCoordinator: WorkspaceCaptureSessionCoordinator
  private let lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry
  private let clockCurrentTimeProvider: any ClockCurrentTimeProviding
  private let clockOverlayRegistryFactory: ClockOverlayRegistryFactory
  private var clockOverlayRegistry: ClockOverlayRuntimeRegistry?
  private var failedClockOverlayInitializationConfiguration:
    ClockOverlayInitializationConfiguration?
  #if canImport(Metal)
    private let metalDevice: MTLDevice?
    private let inputTextureCache: CVMetalTextureCache?
    private let inputPreprocessingPipeline: VideoInputPreprocessingPipeline?
  #endif
  private var activeWidth: Int?
  private var activeHeight: Int?
  private var reusableCameraIDsByInputKey: [String: String] = [:]
  private var reusableSourcesByInputKey: [String: MetalVideoSource] = [:]
  private var reusableComponentCommands: [MetalVideoComponentCommand] = []
  private var videoPTSSelector = ProgramVideoPTSSelector()
  private var activeVideoPTSMasterCameraID: String?
  private var missingMasterPTSFrameCount: UInt64 = 0

  init(
    captureSessionCoordinator: WorkspaceCaptureSessionCoordinator,
    backgroundRemovalPreprocessorFactory: BackgroundRemovalPreprocessorFactory? = nil,
    programPreferencesState: ProgramPreferencesState = ProgramPreferencesState(),
    lowFrequencyUpdateRegistry: LowFrequencyUpdateRegistry,
    clockCurrentTimeProvider: any ClockCurrentTimeProviding = SystemClockCurrentTimeProvider(),
    clockOverlayRegistryFactory: @escaping ClockOverlayRegistryFactory = {
      try ClockOverlayRuntimeRegistry(
        device: $0,
        updateRegistry: $1,
        currentTimeProvider: $2
      )
    }
  ) {
    self.captureSessionCoordinator = captureSessionCoordinator
    self.programPreferencesState = programPreferencesState
    self.lowFrequencyUpdateRegistry = lowFrequencyUpdateRegistry
    self.clockCurrentTimeProvider = clockCurrentTimeProvider
    self.clockOverlayRegistryFactory = clockOverlayRegistryFactory
    #if canImport(Metal)
      metalDevice = MTLCreateSystemDefaultDevice()
      if let metalDevice {
        var textureCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, metalDevice, nil, &textureCache)
        inputTextureCache = textureCache
        inputPreprocessingPipeline = textureCache.map {
          VideoInputPreprocessingPipeline(
            device: metalDevice,
            textureCache: $0,
            backgroundRemovalPreprocessorFactory: backgroundRemovalPreprocessorFactory
          )
        }
      } else {
        inputTextureCache = nil
        inputPreprocessingPipeline = nil
      }
    #endif
  }

  func updateProgramPreferences(_ preferences: ProgramPreferences) {
    programPreferencesState.replace(with: preferences)
  }

  var videoPipelineIDForTesting: UUID? {
    #if canImport(Metal)
      inputPreprocessingPipeline?.id
    #else
      nil
    #endif
  }

  func beginSession(_ sessionID: Int) {
    activeSessionID = sessionID
    videoPTSSelector.reset()
    activeVideoPTSMasterCameraID = nil
    missingMasterPTSFrameCount = 0
    #if canImport(Metal)
      inputPreprocessingPipeline?.reset()
    #endif
  }

  func endSession(_ sessionID: Int) {
    if activeSessionID == sessionID {
      activeSessionID = nil
      clockOverlayRegistry?.deactivateAll()
      failedClockOverlayInitializationConfiguration = nil
    }
  }

  func render(
    configuration: ProgramRuntimeConfiguration,
    destinationForStep: (CompositeProgramStep) -> InputDeviceDestination? = { _ in nil },
    sessionID: Int,
    frameID: UInt64
  ) throws -> ProgramFrame {
    guard activeSessionID == sessionID else {
      throw CancellationError()
    }

    let outputWidth = max(configuration.outputWidth, 1)
    let outputHeight = max(configuration.outputHeight, 1)
    let canvasWidth = max(configuration.canvasWidth, 1)
    let canvasHeight = max(configuration.canvasHeight, 1)
    let preferences = programPreferencesState.read { $0 }
    let renderComposite = compositeApplyingVideoLayerMutes(
      configuration.composite,
      preferences: preferences,
      programName: configuration.videoLayerProgramName
    )
    do {
      // Clock relevance follows the active Program definition even when
      // unrelated frame-resource preparation fails. In particular, a
      // removed Clock must release its low-frequency registration before
      // pixel-buffer or compositor allocation can throw.
      synchronizeClockOverlays(
        composite: renderComposite,
        outputWidth: outputWidth,
        outputHeight: outputHeight
      )
      try prepareSize(width: outputWidth, height: outputHeight)
      let compositor = try makeCompositor(width: outputWidth, height: outputHeight)
      let (presentationTime, isPreparingRenderResources, videoPipelineID) = refreshSources(
        configuration: configuration,
        preferences: preferences
      )
      reusableComponentCommands.removeAll(keepingCapacity: true)
      renderComposite.appendComponentCommands(
        to: &reusableComponentCommands,
        worldWidth: canvasWidth,
        worldHeight: canvasHeight,
        outputWidth: outputWidth,
        outputHeight: outputHeight,
        sourceForInputKey: { key in
          self.reusableSourcesByInputKey[key]
        },
        colorRangeForInputKey: { key in
          configuration.cameraInputColorOverrides[key] ?? .unspecified
        },
        destinationForStep: destinationForStep,
        retainedTextureForStep: { [clockOverlayRegistry] step in
          clockOverlayRegistry?.retainedTexture(forStepNamed: step.name)
        },
        timeSeconds: configuration.timeSeconds
      )
      let outputPixelBuffer = try compositor.renderCommands(reusableComponentCommands)
      return ProgramFrame(
        frameID: frameID,
        pixelBuffer: outputPixelBuffer,
        presentationTime: presentationTime,
        isPreparingRenderResources: isPreparingRenderResources,
        videoPipelineID: videoPipelineID
      )
    } catch {
      if !(error is CancellationError) {
        logProgramRuntimeRendererFailed(error, configuration: configuration)
      }
      throw error
    }
  }

  private func prepareSize(width: Int, height: Int) throws {
    if activeWidth == width && activeHeight == height {
      return
    }

    compositor = nil
    activeWidth = width
    activeHeight = height
  }

  private func makeCompositor(width: Int, height: Int) throws -> VideoCompositor {
    if let compositor {
      return compositor
    }
    let compositor = try VideoCompositor(
      configuration: VideoCompositorConfiguration(
        width: width,
        height: height
      ), device: metalDevice)
    self.compositor = compositor
    return compositor
  }

  private func synchronizeClockOverlays(
    composite: CompositeProgramDefinition,
    outputWidth: Int,
    outputHeight: Int
  ) {
    let hasClock = composite.steps.contains { step in
      if case .clock = step.component { return true }
      return false
    }
    guard hasClock else {
      failedClockOverlayInitializationConfiguration = nil
      clockOverlayRegistry?.synchronize(
        composite: composite,
        outputWidth: outputWidth,
        outputHeight: outputHeight
      )
      return
    }
    if clockOverlayRegistry == nil, let metalDevice {
      let initializationConfiguration = ClockOverlayInitializationConfiguration(
        steps: composite.steps.compactMap { step in
          guard case .clock(let component) = step.component else { return nil }
          return ClockOverlayInitializationConfiguration.Step(
            name: step.name,
            component: component
          )
        },
        outputWidth: outputWidth,
        outputHeight: outputHeight
      )
      guard failedClockOverlayInitializationConfiguration != initializationConfiguration else {
        return
      }
      do {
        clockOverlayRegistry = try clockOverlayRegistryFactory(
          metalDevice,
          lowFrequencyUpdateRegistry,
          clockCurrentTimeProvider
        )
        failedClockOverlayInitializationConfiguration = nil
      } catch {
        failedClockOverlayInitializationConfiguration = initializationConfiguration
        programRuntimeLogger.error(
          "Clock overlay renderer initialization failed: \(error.localizedDescription, privacy: .public)"
        )
        return
      }
    }
    clockOverlayRegistry?.synchronize(
      composite: composite,
      outputWidth: outputWidth,
      outputHeight: outputHeight
    )
  }

  private func refreshSources(
    configuration: ProgramRuntimeConfiguration,
    preferences: ProgramPreferences
  ) -> (
    presentationTime: CMTime?,
    isPreparingRenderResources: Bool,
    videoPipelineID: UUID
  ) {
    if activeVideoPTSMasterCameraID != configuration.videoPTSMasterCameraID {
      // The Workspace PTS master is a pipeline-level setting. A new
      // master starts a new timing epoch rather than carrying a PTS
      // from the previous source into the next rendered frame.
      activeVideoPTSMasterCameraID = configuration.videoPTSMasterCameraID
      videoPTSSelector.reset()
      missingMasterPTSFrameCount = 0
    }
    reusableCameraIDsByInputKey.removeAll(keepingCapacity: true)
    reusableCameraIDsByInputKey.reserveCapacity(configuration.cameraIDsByInputKey.count)
    for (key, cameraID) in configuration.cameraIDsByInputKey {
      reusableCameraIDsByInputKey[key] = cameraID
    }

    reusableSourcesByInputKey.removeAll(keepingCapacity: true)
    reusableSourcesByInputKey.reserveCapacity(reusableCameraIDsByInputKey.count)
    var framesByInputKey: [String: CapturedVideoFrame] = [:]
    for (key, cameraID) in reusableCameraIDsByInputKey {
      if let frame = captureSessionCoordinator.latestFrame(forCameraID: cameraID) {
        framesByInputKey[key] = frame
      }
    }
    var isPreparingRenderResources = framesByInputKey.count < reusableCameraIDsByInputKey.count
    #if canImport(Metal)
      var specifications: [String: VideoInputPipelineSpecification] = [:]
      specifications.reserveCapacity(reusableCameraIDsByInputKey.count)
      for (inputKey, cameraID) in reusableCameraIDsByInputKey {
        specifications[inputKey] = VideoInputPipelineSpecification(
          cameraID: cameraID,
          captureSessionID: framesByInputKey[inputKey]?.captureSessionID,
          mode: configuration.backgroundRemovalInputKeys.contains(inputKey)
            ? .backgroundRemoval : .passthrough
        )
      }
      if inputPreprocessingPipeline?.synchronize(specifications: specifications) == true {
        videoPTSSelector.reset()
      }
      if let inputPreprocessingPipeline, let inputTextureCache {
        for (key, frame) in framesByInputKey {
          switch inputPreprocessingPipeline.process(frame, forInputKey: key) {
          case .ready(let input):
            if let textures = try? VideoInputMetalTextures(
              pixelBuffer: input.frame.pixelBuffer,
              textureCache: inputTextureCache
            ) {
              let muted = preferences.isVideoLayerMuted(
                componentName: key,
                programName: configuration.videoLayerProgramName
              )
              reusableSourcesByInputKey[key] = textures.makeSource(
                from: input,
                contentKind: muted ? .dummy : .captured
              )
            } else {
              isPreparingRenderResources = true
            }
          case .preparing:
            isPreparingRenderResources = true
          case .unavailable:
            isPreparingRenderResources = true
          }
        }
      }
    #endif
    let masterFrame = configuration.videoPTSMasterCameraID.flatMap {
      captureSessionCoordinator.latestFrame(forCameraID: $0)
    }
    let ptsDecision = videoPTSSelector.select(
      masterCameraID: configuration.videoPTSMasterCameraID,
      masterCaptureSessionID: masterFrame?.captureSessionID,
      masterPresentationTime: masterFrame?.sourcePresentationTime
    )
    let presentationTime: CMTime? =
      switch ptsDecision {
      case .advanced(let value):
        value
      case .waitingForMasterPTS, .stalled, .rejectedNonMonotonic, .rejectedMasterSourceChange:
        nil
      }
    switch ptsDecision {
    case .waitingForMasterPTS, .rejectedNonMonotonic, .rejectedMasterSourceChange:
      missingMasterPTSFrameCount &+= 1
      if missingMasterPTSFrameCount == 1 || missingMasterPTSFrameCount.isMultiple(of: 120) {
        let masterKey = configuration.videoPTSMasterCameraID ?? "hostClock"
        let mappedKeys = configuration.cameraIDsByInputKey.keys.sorted().joined(separator: ",")
        let cameraIDs = configuration.cameraIDsByInputKey.values.sorted().joined(separator: ",")
        programRuntimeLogger.notice(
          "Program frame has no master PTS masterCameraID=\(masterKey, privacy: .public) masterFrameAvailable=\(masterFrame != nil, privacy: .public) mappedKeys=\(mappedKeys, privacy: .public) cameraIDs=\(cameraIDs, privacy: .public)"
        )
      }
    case .advanced, .stalled:
      break
    }
    #if canImport(Metal)
      let videoPipelineID = inputPreprocessingPipeline?.id ?? UUID()
    #else
      let videoPipelineID = UUID()
    #endif
    return (presentationTime, isPreparingRenderResources, videoPipelineID)
  }

}

private func logProgramRuntimeRenderFailed(
  _ error: Error, configuration: ProgramRuntimeConfiguration
) {
  let nsError = error as NSError
  programRuntimeLogger.error(
    "Active program render failed errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public) canvasWidth=\(configuration.canvasWidth, privacy: .public) canvasHeight=\(configuration.canvasHeight, privacy: .public) outputWidth=\(configuration.outputWidth, privacy: .public) outputHeight=\(configuration.outputHeight, privacy: .public) frameRate=\(configuration.frameRate, privacy: .public) timeSeconds=\(configuration.timeSeconds, privacy: .public) cameraInputCount=\(configuration.cameraIDsByInputKey.count, privacy: .public) backgroundRemovalInputCount=\(configuration.backgroundRemovalInputKeys.count, privacy: .public) stepCount=\(configuration.composite.steps.count, privacy: .public)"
  )
}

private func logProgramRuntimeRendererFailed(
  _ error: Error, configuration: ProgramRuntimeConfiguration
) {
  let nsError = error as NSError
  programRuntimeLogger.error(
    "Active program renderer failed errorDomain=\(nsError.domain, privacy: .public) errorCode=\(nsError.code, privacy: .public) canvasWidth=\(configuration.canvasWidth, privacy: .public) canvasHeight=\(configuration.canvasHeight, privacy: .public) outputWidth=\(configuration.outputWidth, privacy: .public) outputHeight=\(configuration.outputHeight, privacy: .public) frameRate=\(configuration.frameRate, privacy: .public) timeSeconds=\(configuration.timeSeconds, privacy: .public) cameraInputCount=\(configuration.cameraIDsByInputKey.count, privacy: .public) backgroundRemovalInputCount=\(configuration.backgroundRemovalInputKeys.count, privacy: .public) stepCount=\(configuration.composite.steps.count, privacy: .public)"
  )
}

private let programRuntimeLogger = Logger(
  subsystem: "tokyo.kaito.ldtx",
  category: "ProgramRuntime"
)
