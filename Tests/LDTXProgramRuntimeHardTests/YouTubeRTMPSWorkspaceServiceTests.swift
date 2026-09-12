// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
import LDTXMP4
import LDTXYouTubeRTMPS
import Testing

@testable import LDTXProgramRuntime

@Suite
struct YouTubeRTMPSWorkspaceServiceIntegrationTestSuite {
  @Test func startsForOnlyTheConfiguredLandscapeCanvas() async throws {
    let publisher = FakeDualRTMPSPublisher()
    let destination = try YouTubeRTMPSDestination(
      ingestionURL: try #require(URL(string: "rtmps://a.rtmp.youtube.com/live2")),
      streamName: "landscape")
    let service = YouTubeRTMPSWorkspaceService(
      destinations: try YouTubeRTMPSDestinations(landscape: destination),
      publisher: publisher,
      failureHandler: { Issue.record("unexpected failure: \($0)") })
    let video = try await makeVideoSample()
    let audio = try makePCMSample(frameCount: 2_048)

    async let publishing: Void = service.waitUntilPublishing()
    service.appendLandscapeVideo(video)
    service.appendLandscapeAudioMix(audio)
    try await publishing
    let result = await service.finish()

    if case .failure(let error) = result { Issue.record("unexpected failure: \(error)") }
    let snapshot = await publisher.snapshot()
    #expect(snapshot.startCount == 1)
    #expect(snapshot.videoCanvases == [.landscape])
    #expect(snapshot.audioCanvases.contains(.landscape))
    #expect(!snapshot.audioCanvases.contains(.portrait))
  }

  @Test func startsAfterBothCanvasFormatsAndDeliversBufferedMediaInOrder() async throws {
    let publisher = FakeDualRTMPSPublisher()
    let service = YouTubeRTMPSWorkspaceService(
      destinations: try destinations(),
      publisher: publisher,
      failureHandler: { Issue.record("unexpected failure: \($0)") })
    let video = try await makeVideoSample()
    let audio = try makePCMSample(frameCount: 2_048)

    async let publishing: Void = service.waitUntilPublishing()
    service.appendLandscapeVideo(video)
    service.appendLandscapeAudioMix(audio)
    service.appendPortraitVideo(video)
    service.appendPortraitAudioMix(audio)
    try await publishing
    let result = await service.finish()

    if case .failure(let error) = result { Issue.record("unexpected failure: \(error)") }
    let snapshot = await publisher.snapshot()
    #expect(snapshot.startCount == 1)
    #expect(snapshot.stopCount == 1)
    #expect(snapshot.videoCanvases == [.landscape, .portrait])
    #expect(snapshot.audioCanvases.contains(.landscape))
    #expect(snapshot.audioCanvases.contains(.portrait))
    #expect(!snapshot.landscapeAudioSpecificConfig.isEmpty)
    #expect(!snapshot.portraitAudioSpecificConfig.isEmpty)
  }

  @Test func publishingWaitFailsWhenServiceFinishesBeforeFormatsArrive() async throws {
    let service = YouTubeRTMPSWorkspaceService(
      destinations: try destinations(),
      publisher: FakeDualRTMPSPublisher(),
      failureHandler: { Issue.record("unexpected failure: \($0)") })
    let waiter = Task { try await service.waitUntilPublishing() }

    _ = await service.finish()

    do {
      try await waiter.value
      Issue.record("expected stopped error")
    } catch {
      #expect(error as? YouTubeRTMPSWorkspaceServiceError == .stopped)
    }
  }

  @Test func failsAndStopsWhenPendingMediaLimitIsExceeded() async throws {
    let publisher = FakeDualRTMPSPublisher()
    let failure = DispatchSemaphore(value: 0)
    let service = YouTubeRTMPSWorkspaceService(
      destinations: try destinations(),
      publisher: publisher,
      pendingMediaLimit: 1,
      failureHandler: { error in
        #expect(error as? YouTubeRTMPSWorkspaceServiceError == .pendingMediaLimitExceeded)
        failure.signal()
      })
    let video = try await makeVideoSample()

    service.appendLandscapeVideo(video)
    service.appendPortraitVideo(video)
    #expect(await waits(for: failure, timeout: 2))
    let result = await service.finish()

    guard case .failure(let error) = result else {
      Issue.record("expected failure")
      return
    }
    #expect(error as? YouTubeRTMPSWorkspaceServiceError == .pendingMediaLimitExceeded)
    let snapshot = await publisher.snapshot()
    #expect(snapshot.startCount == 0)
    #expect(snapshot.stopCount >= 1)
  }

  private func destinations() throws -> YouTubeDualRTMPSDestinations {
    try YouTubeDualRTMPSDestinations(
      landscape: YouTubeRTMPSDestination(
        ingestionURL: try #require(URL(string: "rtmps://a.rtmp.youtube.com/live2")),
        streamName: "landscape"),
      portrait: YouTubeRTMPSDestination(
        ingestionURL: try #require(URL(string: "rtmps://b.rtmp.youtube.com/live2")),
        streamName: "portrait"))
  }

  private func makeVideoSample() async throws -> CMSampleBuffer {
    let output = EncodedRTMPSSampleOutput()
    let encoder = try H264VideoEncoder(
      configuration: H264VideoEncoderConfiguration(
        width: 320, height: 180, frameRate: 30, bitRate: 800_000)
    ) { output.append($0) }
    encoder.encode(
      pixelBuffer: try makePixelBuffer(width: 320, height: 180),
      presentationTime: CMTime(value: 60, timescale: 600),
      duration: CMTime(value: 20, timescale: 600))
    try await withCheckedThrowingContinuation { continuation in
      encoder.finish { continuation.resume(with: $0) }
    }
    return try #require(try output.sampleBuffers().first)
  }

  private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault, width, height,
      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
      &pixelBuffer)
    #expect(status == kCVReturnSuccess)
    return try #require(pixelBuffer)
  }

  private func makePCMSample(frameCount: Int) throws -> CMSampleBuffer {
    let data = Data(repeating: 0, count: frameCount * 2 * MemoryLayout<Float32>.size)
    var blockBuffer: CMBlockBuffer?
    let blockStatus = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: data.count,
      blockAllocator: nil,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: data.count,
      flags: 0,
      blockBufferOut: &blockBuffer)
    #expect(blockStatus == kCMBlockBufferNoErr)
    let buffer = try #require(blockBuffer)
    data.withUnsafeBytes { bytes in
      let replaceStatus = CMBlockBufferReplaceDataBytes(
        with: bytes.baseAddress!,
        blockBuffer: buffer,
        offsetIntoDestination: 0,
        dataLength: data.count)
      #expect(replaceStatus == kCMBlockBufferNoErr)
    }
    var stream = AudioStreamBasicDescription(
      mSampleRate: 48_000,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 8,
      mFramesPerPacket: 1,
      mBytesPerFrame: 8,
      mChannelsPerFrame: 2,
      mBitsPerChannel: 32,
      mReserved: 0)
    var format: CMAudioFormatDescription?
    let formatStatus = CMAudioFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      asbd: &stream,
      layoutSize: 0,
      layout: nil,
      magicCookieSize: 0,
      magicCookie: nil,
      extensions: nil,
      formatDescriptionOut: &format)
    #expect(formatStatus == noErr)
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 48_000),
      presentationTimeStamp: CMTime(value: 48_000, timescale: 48_000),
      decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    let sampleStatus = CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault,
      dataBuffer: buffer,
      formatDescription: format,
      sampleCount: frameCount,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: 0,
      sampleSizeArray: nil,
      sampleBufferOut: &sample)
    #expect(sampleStatus == noErr)
    return try #require(sample)
  }

  private func waits(for semaphore: DispatchSemaphore, timeout: TimeInterval) async -> Bool {
    await Task.detached { waitForRTMPSWorkspaceSemaphore(semaphore, timeout: timeout) }.value
  }
}

private func waitForRTMPSWorkspaceSemaphore(_ semaphore: DispatchSemaphore, timeout: TimeInterval)
  -> Bool
{
  semaphore.wait(timeout: .now() + timeout) == .success
}

private actor FakeDualRTMPSPublisher: YouTubeRTMPSPublishing {
  struct Snapshot: Sendable {
    var startCount: Int
    var stopCount: Int
    var videoCanvases: [YouTubeRTMPSCanvas]
    var audioCanvases: [YouTubeRTMPSCanvas]
    var landscapeAudioSpecificConfig: Data
    var portraitAudioSpecificConfig: Data
  }

  private var startCount = 0
  private var stopCount = 0
  private var videoCanvases: [YouTubeRTMPSCanvas] = []
  private var audioCanvases: [YouTubeRTMPSCanvas] = []
  private var landscapeAudioSpecificConfig = Data()
  private var portraitAudioSpecificConfig = Data()

  func start(
    destinations _: YouTubeRTMPSDestinations,
    videoFormats _: [YouTubeRTMPSCanvas: YouTubeRTMPSVideoFormat],
    audioFormats: [YouTubeRTMPSCanvas: YouTubeRTMPSAudioFormat]
  ) async throws {
    startCount += 1
    landscapeAudioSpecificConfig = audioFormats[.landscape]?.audioSpecificConfig ?? Data()
    portraitAudioSpecificConfig = audioFormats[.portrait]?.audioSpecificConfig ?? Data()
  }

  func appendVideo(
    _: YouTubeRTMPSVideoSample,
    canvas: YouTubeRTMPSCanvas
  ) async throws {
    videoCanvases.append(canvas)
  }

  func appendAudio(
    _: YouTubeRTMPSAudioSample,
    canvas: YouTubeRTMPSCanvas
  ) async throws {
    audioCanvases.append(canvas)
  }

  func stop() async { stopCount += 1 }

  func snapshot() -> Snapshot {
    Snapshot(
      startCount: startCount,
      stopCount: stopCount,
      videoCanvases: videoCanvases,
      audioCanvases: audioCanvases,
      landscapeAudioSpecificConfig: landscapeAudioSpecificConfig,
      portraitAudioSpecificConfig: portraitAudioSpecificConfig)
  }
}

private final class EncodedRTMPSSampleOutput: @unchecked Sendable {
  private let lock = NSLock()
  private var results: [Result<CMSampleBuffer, Error>] = []

  func append(_ result: Result<CMSampleBuffer, Error>) {
    lock.withLock { results.append(result) }
  }

  func sampleBuffers() throws -> [CMSampleBuffer] {
    try lock.withLock { try results.map { try $0.get() } }
  }
}
