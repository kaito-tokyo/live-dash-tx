// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXProgram
import Metal
import OSLog

private let clockOverlayRuntimeLogger = Logger(
  subsystem: "tokyo.kaito.ldtx",
  category: "clock-overlay"
)

public protocol ClockCurrentTimeProviding: Sendable {
  func now() -> Date
}

public struct SystemClockCurrentTimeProvider: ClockCurrentTimeProviding {
  public init() {}

  public func now() -> Date {
    Date()
  }
}

/// A deterministic, locale-independent Clock presentation.
struct ClockTextFormatter: Sendable {
  private let timeZoneProvider: @Sendable () -> TimeZone

  init(timeZoneProvider: @escaping @Sendable () -> TimeZone = { .autoupdatingCurrent }) {
    self.timeZoneProvider = timeZoneProvider
  }

  func string(from date: Date, component: ClockComponent) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone =
      component.usesSystemTimeZone
      ? timeZoneProvider()
      : TimeZone(secondsFromGMT: Int(min(max(component.utcOffsetMinutes, -840), 840)) * 60)
        ?? TimeZone(
          secondsFromGMT: 0)!
    switch (component.uses24HourTime, component.showsSeconds) {
    case (true, true):
      formatter.dateFormat = "HH:mm:ss"
    case (true, false):
      formatter.dateFormat = "HH:mm"
    case (false, true):
      formatter.dateFormat = "h:mm:ss a"
    case (false, false):
      formatter.dateFormat = "h:mm a"
    }
    let time = formatter.string(from: date)
    guard component.showsDate else { return time }
    formatter.dateFormat = "yyyy/MM/dd"
    return formatter.string(from: date) + "\n" + time
  }
}

enum ClockOverlayTextureError: Error, Equatable {
  case colorTextureMustBeRGB565
  case colorTextureMustBeSampleable2D
  case alphaTextureMustBeR8
  case alphaTextureMustBeSampleable2D
  case textureSizeMismatch
  case textureDeviceMismatch
}

/// A retained standard-texture overlay ready for the NV12 compositor boundary.
///
/// Color is always RGB565. Per-pixel alpha is represented separately and is
/// allocated only when the component needs it.
final class ClockOverlayTexture: @unchecked Sendable {
  let colorTexture: MTLTexture
  let alphaTexture: MTLTexture?

  init(colorTexture: MTLTexture, alphaTexture: MTLTexture? = nil) throws {
    guard colorTexture.pixelFormat == .b5g6r5Unorm else {
      throw ClockOverlayTextureError.colorTextureMustBeRGB565
    }
    guard Self.isSampleable2D(colorTexture) else {
      throw ClockOverlayTextureError.colorTextureMustBeSampleable2D
    }
    if let alphaTexture {
      guard alphaTexture.pixelFormat == .r8Unorm else {
        throw ClockOverlayTextureError.alphaTextureMustBeR8
      }
      guard Self.isSampleable2D(alphaTexture) else {
        throw ClockOverlayTextureError.alphaTextureMustBeSampleable2D
      }
      guard alphaTexture.width == colorTexture.width,
        alphaTexture.height == colorTexture.height
      else {
        throw ClockOverlayTextureError.textureSizeMismatch
      }
      guard alphaTexture.device.registryID == colorTexture.device.registryID else {
        throw ClockOverlayTextureError.textureDeviceMismatch
      }
    }
    self.colorTexture = colorTexture
    self.alphaTexture = alphaTexture
  }

  private static func isSampleable2D(_ texture: MTLTexture) -> Bool {
    texture.textureType == .type2D
      && texture.sampleCount == 1
      && (texture.usage == .unknown || texture.usage.contains(.shaderRead))
  }
}

struct ClockOverlayRenderRequest: Sendable, Equatable {
  var text: String
  var component: ClockComponent
  var pixelWidth: Int
  var pixelHeight: Int
}

/// Metal implementation point for the retained Clock texture generator.
///
/// Implementations may use half/float working textures and structured buffers,
/// but must return an RGB565 cache and optional R8 alpha cache.
protocol ClockOverlayRendering: Sendable {
  func renderClockOverlay(_ request: ClockOverlayRenderRequest) throws -> ClockOverlayTexture
}

/// Owns the low-frequency lifecycle and retained output for one Clock component.
///
/// It renders immediately when activated, registers only while active, and
/// coalesces requests while one render is in flight. A failed refresh leaves the
/// previous texture and successful request intact, so the next notification or
/// configuration update retries it.
final class ClockOverlayRuntime: @unchecked Sendable {
  typealias OverlayDidChange = @Sendable (ClockOverlayTexture) -> Void

  private struct State {
    var component: ClockComponent
    var pixelWidth: Int
    var pixelHeight: Int
    var isActive = false
    var renderInFlight = false
    var renderRequested = false
    var renderGeneration: UInt64 = 0
    var registration: LowFrequencyUpdateRegistration?
    var retainedTexture: ClockOverlayTexture?
    var lastSuccessfulRequest: ClockOverlayRenderRequest?
    var needsRetry = false
  }

  private let lock: NSLock
  private var state: State
  private let updateRegistry: LowFrequencyUpdateRegistry
  private let currentTimeProvider: any ClockCurrentTimeProviding
  private let formatter: ClockTextFormatter
  private let renderer: any ClockOverlayRendering
  private let rendererQueue: DispatchQueue
  private let overlayDidChange: OverlayDidChange

  init(
    component: ClockComponent,
    pixelWidth: Int = 256,
    pixelHeight: Int = 96,
    updateRegistry: LowFrequencyUpdateRegistry,
    currentTimeProvider: any ClockCurrentTimeProviding = SystemClockCurrentTimeProvider(),
    formatter: ClockTextFormatter = ClockTextFormatter(),
    renderer: any ClockOverlayRendering,
    rendererQueue: DispatchQueue = DispatchQueue(
      label: "tokyo.kaito.ldtx.ClockOverlayRuntime.renderer",
      qos: .userInitiated
    ),
    overlayDidChange: @escaping OverlayDidChange = { _ in }
  ) {
    lock = NSLock()
    state = State(
      component: component,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight
    )
    self.updateRegistry = updateRegistry
    self.currentTimeProvider = currentTimeProvider
    self.formatter = formatter
    self.renderer = renderer
    self.rendererQueue = rendererQueue
    self.overlayDidChange = overlayDidChange
  }

  func activate() {
    let needsRegistration = lock.withLock { () -> Bool in
      guard !state.isActive else { return false }
      state.isActive = true
      state.renderGeneration &+= 1
      return state.registration == nil
    }
    if needsRegistration {
      let registration = updateRegistry.register { [weak self] in
        self?.requestRender()
      }
      let registrationToCancel = lock.withLock { () -> LowFrequencyUpdateRegistration? in
        guard state.isActive, state.registration == nil else {
          return registration
        }
        state.registration = registration
        return nil
      }
      registrationToCancel?.cancel()
    }
    requestRender()
  }

  func update(
    component: ClockComponent,
    pixelWidth: Int? = nil,
    pixelHeight: Int? = nil
  ) {
    let needsRender = lock.withLock { () -> Bool in
      let nextPixelWidth = pixelWidth ?? state.pixelWidth
      let nextPixelHeight = pixelHeight ?? state.pixelHeight
      let overlayContentChanged =
        !state.component.hasEquivalentOverlayContent(to: component)
        || state.pixelWidth != nextPixelWidth
        || state.pixelHeight != nextPixelHeight
      let configurationChanged =
        !state.component.hasEquivalentClockConfiguration(to: component)
        || state.pixelWidth != nextPixelWidth
        || state.pixelHeight != nextPixelHeight
      state.component = component
      state.pixelWidth = nextPixelWidth
      state.pixelHeight = nextPixelHeight
      if overlayContentChanged {
        state.renderGeneration &+= 1
      }
      // A placement-only update normally reuses the retained texture. If a
      // render is already running, keep one follow-up request so the same
      // configuration update also retries that render if it fails. Equivalent
      // per-frame synchronization must not turn a failed low-frequency refresh
      // into retries at the canvas frame rate.
      return overlayContentChanged
        || (configurationChanged && (state.needsRetry || state.renderInFlight))
    }
    if needsRender {
      requestRender()
    }
  }

  func deactivate() {
    let registration = lock.withLock { () -> LowFrequencyUpdateRegistration? in
      if state.isActive {
        state.renderGeneration &+= 1
      }
      state.isActive = false
      state.renderRequested = false
      let registration = state.registration
      state.registration = nil
      return registration
    }
    registration?.cancel()
  }

  func retainedOverlay() -> ClockOverlayTexture? {
    lock.withLock { state.retainedTexture }
  }

  deinit {
    deactivate()
  }

  private func requestRender() {
    let shouldStart = lock.withLock { () -> Bool in
      guard state.isActive else { return false }
      state.renderRequested = true
      guard !state.renderInFlight else { return false }
      state.renderInFlight = true
      return true
    }
    guard shouldStart else { return }
    rendererQueue.async { [weak self] in
      self?.renderRequestedOverlays()
    }
  }

  private func renderRequestedOverlays() {
    while true {
      let renderConfiguration = lock.withLock {
        () -> (ClockComponent, Int, Int, UInt64)? in
        guard state.isActive, state.renderRequested else {
          state.renderInFlight = false
          return nil
        }
        state.renderRequested = false
        return (
          state.component,
          state.pixelWidth,
          state.pixelHeight,
          state.renderGeneration
        )
      }
      guard let (component, pixelWidth, pixelHeight, generation) = renderConfiguration else {
        return
      }

      let date = currentTimeProvider.now()
      let request = ClockOverlayRenderRequest(
        text: formatter.string(from: date, component: component),
        component: component,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight
      ).normalizedForRendering
      let isAlreadyCurrent = lock.withLock { () -> Bool in
        guard state.lastSuccessfulRequest?.rendersEquivalentOverlay(to: request) == true else {
          return false
        }
        if state.renderGeneration == generation {
          state.needsRetry = false
        }
        return true
      }
      if isAlreadyCurrent {
        continue
      }

      do {
        let texture = try renderer.renderClockOverlay(request)
        let shouldPublish = lock.withLock { () -> Bool in
          guard state.isActive, state.renderGeneration == generation else {
            return false
          }
          state.retainedTexture = texture
          state.lastSuccessfulRequest = request
          state.needsRetry = false
          return true
        }
        if shouldPublish {
          overlayDidChange(texture)
        }
      } catch {
        // Retain the last successful texture/request. A future pulse or
        // configuration change will retry this request.
        clockOverlayRuntimeLogger.error(
          "Clock overlay render failed: \(error.localizedDescription, privacy: .public)"
        )
        lock.withLock {
          if state.isActive, state.renderGeneration == generation {
            state.needsRetry = true
          }
        }
      }
    }
  }
}

extension ClockOverlayRenderRequest {
  var normalizedForRendering: Self {
    var normalized = self
    normalized.component = component.normalizedForClockOverlayRendering
    return normalized
  }

  fileprivate func rendersEquivalentOverlay(to other: Self) -> Bool {
    text == other.text
      && pixelWidth == other.pixelWidth
      && pixelHeight == other.pixelHeight
      && component.hasEquivalentOverlayContent(to: other.component)
  }
}

extension ClockComponent {
  var normalizedForClockOverlayRendering: Self {
    let defaults = Self()
    var normalized = self
    normalized.foregroundRed = Self.normalizedUnit(foregroundRed, fallback: defaults.foregroundRed)
    normalized.foregroundGreen = Self.normalizedUnit(
      foregroundGreen,
      fallback: defaults.foregroundGreen
    )
    normalized.foregroundBlue = Self.normalizedUnit(
      foregroundBlue,
      fallback: defaults.foregroundBlue
    )
    normalized.foregroundAlpha = Self.normalizedUnit(
      foregroundAlpha,
      fallback: defaults.foregroundAlpha
    )
    normalized.backgroundRed = Self.normalizedUnit(backgroundRed, fallback: defaults.backgroundRed)
    normalized.backgroundGreen = Self.normalizedUnit(
      backgroundGreen,
      fallback: defaults.backgroundGreen
    )
    normalized.backgroundBlue = Self.normalizedUnit(
      backgroundBlue,
      fallback: defaults.backgroundBlue
    )
    normalized.backgroundAlpha = Self.normalizedUnit(
      backgroundAlpha,
      fallback: defaults.backgroundAlpha
    )
    normalized.utcOffsetMinutes = min(max(utcOffsetMinutes, -840), 840)
    normalized.outlines = outlines.prefix(2).map { outline in
      ClockTextOutline(
        thickness: outline.thickness.isFinite ? min(max(outline.thickness, 0), 64) : 0,
        color: outline.color
      )
    }
    return normalized
  }

  fileprivate func hasEquivalentOverlayContent(to other: Self) -> Bool {
    // Placement is consumed by the compositor, while its resulting pixel size
    // is compared separately by ClockOverlayRuntime.
    var lhs = normalizedForClockOverlayRendering
    var rhs = other.normalizedForClockOverlayRendering
    lhs.destinationX = 0
    lhs.destinationY = 0
    lhs.destinationWidth = 0
    lhs.destinationHeight = 0
    rhs.destinationX = 0
    rhs.destinationY = 0
    rhs.destinationWidth = 0
    rhs.destinationHeight = 0
    return lhs == rhs
  }

  fileprivate func hasEquivalentClockConfiguration(to other: Self) -> Bool {
    let lhs = normalizedForClockOverlayRendering
    let rhs = other.normalizedForClockOverlayRendering
    return lhs.destinationX.bitPattern == rhs.destinationX.bitPattern
      && lhs.destinationY.bitPattern == rhs.destinationY.bitPattern
      && lhs.destinationWidth.bitPattern == rhs.destinationWidth.bitPattern
      && lhs.destinationHeight.bitPattern == rhs.destinationHeight.bitPattern
      && lhs.foregroundRed.bitPattern == rhs.foregroundRed.bitPattern
      && lhs.foregroundGreen.bitPattern == rhs.foregroundGreen.bitPattern
      && lhs.foregroundBlue.bitPattern == rhs.foregroundBlue.bitPattern
      && lhs.foregroundAlpha.bitPattern == rhs.foregroundAlpha.bitPattern
      && lhs.backgroundRed.bitPattern == rhs.backgroundRed.bitPattern
      && lhs.backgroundGreen.bitPattern == rhs.backgroundGreen.bitPattern
      && lhs.backgroundBlue.bitPattern == rhs.backgroundBlue.bitPattern
      && lhs.backgroundAlpha.bitPattern == rhs.backgroundAlpha.bitPattern
      && lhs.showsSeconds == rhs.showsSeconds
      && lhs.uses24HourTime == rhs.uses24HourTime
      && lhs.showsDate == rhs.showsDate
      && lhs.usesSystemTimeZone == rhs.usesSystemTimeZone
      && lhs.utcOffsetMinutes == rhs.utcOffsetMinutes
  }

  private static func normalizedUnit(_ value: Float, fallback: Float) -> Float {
    guard value.isFinite else { return fallback }
    return min(max(value, 0), 1)
  }
}
