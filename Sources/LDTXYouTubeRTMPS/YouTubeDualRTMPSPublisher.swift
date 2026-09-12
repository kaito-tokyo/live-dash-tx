// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum YouTubeRTMPSCanvas: String, Sendable, Equatable, Hashable {
  case landscape
  case portrait
}

/// One or two Canvas destinations used by an RTMPS publishing session.
public struct YouTubeRTMPSDestinations: Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let landscape: YouTubeRTMPSDestination?
  public let portrait: YouTubeRTMPSDestination?

  public init(
    landscape: YouTubeRTMPSDestination? = nil,
    portrait: YouTubeRTMPSDestination? = nil
  ) throws {
    guard landscape != nil || portrait != nil,
      landscape != portrait,
      landscape?.streamName != portrait?.streamName
    else { throw YouTubeRTMPSError.invalidDestination }
    self.landscape = landscape
    self.portrait = portrait
  }

  public init(_ dual: YouTubeDualRTMPSDestinations) {
    landscape = dual.landscape
    portrait = dual.portrait
  }

  public var canvases: Set<YouTubeRTMPSCanvas> {
    var result: Set<YouTubeRTMPSCanvas> = []
    if landscape != nil { result.insert(.landscape) }
    if portrait != nil { result.insert(.portrait) }
    return result
  }

  public func destination(for canvas: YouTubeRTMPSCanvas) -> YouTubeRTMPSDestination? {
    switch canvas {
    case .landscape: landscape
    case .portrait: portrait
    }
  }

  public var description: String { "YouTubeRTMPSDestinations(<redacted>)" }
  public var debugDescription: String { description }
}

public struct YouTubeDualRTMPSDestinations: Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let landscape: YouTubeRTMPSDestination
  public let portrait: YouTubeRTMPSDestination

  public init(
    landscape: YouTubeRTMPSDestination,
    portrait: YouTubeRTMPSDestination
  ) throws {
    guard landscape != portrait, landscape.streamName != portrait.streamName else {
      throw YouTubeRTMPSError.invalidDestination
    }
    self.landscape = landscape
    self.portrait = portrait
  }

  public var description: String { "YouTubeDualRTMPSDestinations(<redacted>)" }
  public var debugDescription: String { description }
}

public actor YouTubeDualRTMPSPublisher {
  public typealias PublisherFactory = @Sendable (YouTubeRTMPSCanvas) -> YouTubeRTMPSPublisher
  public typealias EventHandler =
    @Sendable (
      YouTubeRTMPSCanvas, YouTubeRTMPSPublisherEvent
    ) -> Void

  private let landscape: YouTubeRTMPSPublisher
  private let portrait: YouTubeRTMPSPublisher
  private enum State { case idle, starting, started, stopping }
  private var state = State.idle
  private var activeCanvases: Set<YouTubeRTMPSCanvas> = []
  private var generation: UInt64 = 0
  private var stopTask: Task<Void, Never>?

  public init(eventHandler: @escaping EventHandler = { _, _ in }) {
    landscape = YouTubeRTMPSPublisher(
      eventHandler: { eventHandler(.landscape, $0) })
    portrait = YouTubeRTMPSPublisher(
      eventHandler: { eventHandler(.portrait, $0) })
  }

  public init(factory: PublisherFactory) {
    landscape = factory(.landscape)
    portrait = factory(.portrait)
  }

  public func start(
    destinations: YouTubeDualRTMPSDestinations,
    landscapeVideoFormat: YouTubeRTMPSVideoFormat,
    portraitVideoFormat: YouTubeRTMPSVideoFormat,
    landscapeAudioFormat: YouTubeRTMPSAudioFormat,
    portraitAudioFormat: YouTubeRTMPSAudioFormat
  ) async throws {
    try await start(
      destinations: YouTubeRTMPSDestinations(destinations),
      videoFormats: [.landscape: landscapeVideoFormat, .portrait: portraitVideoFormat],
      audioFormats: [.landscape: landscapeAudioFormat, .portrait: portraitAudioFormat])
  }

  public func start(
    destinations: YouTubeRTMPSDestinations,
    videoFormats: [YouTubeRTMPSCanvas: YouTubeRTMPSVideoFormat],
    audioFormats: [YouTubeRTMPSCanvas: YouTubeRTMPSAudioFormat]
  ) async throws {
    guard state == .idle else { throw YouTubeRTMPSError.protocolFailure("dual start") }
    let canvases = destinations.canvases
    guard canvases.allSatisfy({ videoFormats[$0] != nil && audioFormats[$0] != nil })
    else { throw YouTubeRTMPSError.invalidDestination }
    generation &+= 1
    let startGeneration = generation
    state = .starting
    do {
      try await withThrowingTaskGroup(of: Void.self) { group in
        if let destination = destinations.landscape,
          let videoFormat = videoFormats[.landscape], let audioFormat = audioFormats[.landscape]
        {
          group.addTask {
            try await self.landscape.connect(
              to: destination, videoFormat: videoFormat, audioFormat: audioFormat)
          }
        }
        if let destination = destinations.portrait,
          let videoFormat = videoFormats[.portrait], let audioFormat = audioFormats[.portrait]
        {
          group.addTask {
            try await self.portrait.connect(
              to: destination, videoFormat: videoFormat, audioFormat: audioFormat)
          }
        }
        do {
          while try await group.next() != nil {}
        } catch {
          group.cancelAll()
          await landscape.finish()
          await portrait.finish()
          throw error
        }
      }
      guard generation == startGeneration, state == .starting else {
        throw YouTubeRTMPSError.notPublishing
      }
      activeCanvases = canvases
      state = .started
    } catch {
      if generation == startGeneration {
        await landscape.finish()
        if generation == startGeneration {
          await portrait.finish()
          if generation == startGeneration { state = .idle }
        }
      }
      throw error
    }
  }

  public func appendVideo(
    _ sample: YouTubeRTMPSVideoSample,
    canvas: YouTubeRTMPSCanvas
  ) async throws {
    guard state == .started, activeCanvases.contains(canvas) else {
      throw YouTubeRTMPSError.notPublishing
    }
    let appendGeneration = generation
    do {
      switch canvas {
      case .landscape: try await landscape.appendVideo(sample)
      case .portrait: try await portrait.appendVideo(sample)
      }
    } catch let error as YouTubeRTMPSError where error == .queueLimitExceeded {
      throw error
    } catch {
      if generation == appendGeneration { await stop() }
      throw error
    }
  }

  public func appendAudio(
    _ sample: YouTubeRTMPSAudioSample,
    canvas: YouTubeRTMPSCanvas
  ) async throws {
    guard state == .started, activeCanvases.contains(canvas) else {
      throw YouTubeRTMPSError.notPublishing
    }
    let appendGeneration = generation
    do {
      switch canvas {
      case .landscape: try await landscape.appendAudio(sample)
      case .portrait: try await portrait.appendAudio(sample)
      }
    } catch let error as YouTubeRTMPSError where error == .queueLimitExceeded {
      throw error
    } catch {
      if generation == appendGeneration { await stop() }
      throw error
    }
  }

  public func stop() async {
    if let stopTask {
      await stopTask.value
      return
    }
    guard state != .idle else { return }
    generation &+= 1
    let stopGeneration = generation
    state = .stopping
    let task = Task { await self.stopSession(generation: stopGeneration) }
    stopTask = task
    await task.value
  }

  private func stopSession(generation stopGeneration: UInt64) async {
    async let landscapeStop: Void = landscape.finish()
    async let portraitStop: Void = portrait.finish()
    _ = await (landscapeStop, portraitStop)
    guard generation == stopGeneration else { return }
    activeCanvases.removeAll()
    stopTask = nil
    state = .idle
  }
}
