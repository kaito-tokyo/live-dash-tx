// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Testing

@testable import LDTXAppCore

@Suite
@MainActor
struct WindowLifecycleIntegrationTestSuite {
  @Test func testCloseModeSkipsPromptAndSaveButStillStopsOnce() {
    let gate = WorkspaceV4WindowCloseCoordinator(discardsUnsavedChangesOnClose: true)
    _ = NSApplication.shared
    let window = NSWindow()
    var confirmations = 0
    var saves = 0
    var stops = 0
    gate.chooseCloseAction = { _ in
      confirmations += 1
      return .abort
    }
    gate.beginInstalling(
      window: window, hasUnsavedChanges: true,
      saveBeforeClose: {
        saves += 1
        return true
      },
      onClose: { _ in stops += 1 }, onBecomeKey: {})
    #expect(gate.confirmClose())
    #expect(!gate.windowShouldClose(window))
    #expect(!gate.windowShouldClose(window))
    #expect(confirmations == 0)
    #expect(saves == 0)
    #expect(stops == 1)
  }

  @Test func cancellingQuitDoesNotStopAnyWorkspace() async {
    let coordinator = ApplicationTerminationCoordinator()
    var stops = 0
    let result = await coordinator.terminate([
      .init(confirm: { true }, stop: { stops += 1 }),
      .init(confirm: { false }, stop: { stops += 1 }),
    ])
    #expect(!result)
    #expect(stops == 0)
    #expect(!coordinator.isTerminating)
  }

  @Test func terminationWaitsForEverySession() async {
    let coordinator = ApplicationTerminationCoordinator()
    var events: [String] = []
    let result = await coordinator.terminate([
      .init(
        confirm: {
          events.append("confirm1")
          return true
        },
        stop: {
          await Task.yield()
          events.append("stop1")
        }),
      .init(
        confirm: {
          events.append("confirm2")
          return true
        },
        stop: {
          await Task.yield()
          events.append("stop2")
        }),
    ])
    #expect(result)
    #expect(events == ["confirm1", "confirm2", "stop1", "stop2"])
  }

  @Test func failedSavePreventsCloseAndShutdown() {
    let gate = WorkspaceV4WindowCloseCoordinator()
    _ = NSApplication.shared
    let window = NSWindow()
    var stops = 0
    gate.chooseCloseAction = { _ in .alertFirstButtonReturn }
    gate.beginInstalling(
      window: window, hasUnsavedChanges: true, saveBeforeClose: { false },
      onClose: { _ in stops += 1 }, onBecomeKey: {})
    #expect(!gate.windowShouldClose(window))
    #expect(stops == 0)
  }

  @Test func discardConfirmationDoesNotEraseDirtyStateBeforeQuitCommits() {
    let gate = WorkspaceV4WindowCloseCoordinator()
    _ = NSApplication.shared
    let window = NSWindow()
    var confirmations = 0
    gate.chooseCloseAction = { _ in
      confirmations += 1
      return .alertSecondButtonReturn
    }
    gate.beginInstalling(
      window: window, hasUnsavedChanges: true, saveBeforeClose: { true }, onClose: { _ in },
      onBecomeKey: {})
    #expect(gate.confirmClose())
    #expect(gate.confirmClose())
    #expect(confirmations == 2)
  }

  @Test func repeatedCloseRequestsStartShutdownOnlyOnce() {
    let gate = WorkspaceV4WindowCloseCoordinator()
    _ = NSApplication.shared
    let window = NSWindow()
    var stops = 0
    gate.beginInstalling(
      window: window, hasUnsavedChanges: false, saveBeforeClose: { true },
      onClose: { _ in stops += 1 }, onBecomeKey: {})
    #expect(!gate.windowShouldClose(window))
    #expect(!gate.windowShouldClose(window))
    #expect(stops == 1)
  }
}
