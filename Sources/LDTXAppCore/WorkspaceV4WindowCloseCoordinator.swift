// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AppKit

@MainActor
final class WorkspaceV4WindowCloseCoordinator: NSObject, NSWindowDelegate {
  typealias CloseOperation = (@escaping @MainActor @Sendable () -> Void) -> Void
  typealias SaveOperation = () -> Bool
  typealias BecomeKeyOperation = () -> Void
  typealias AfterCloseOperation = @MainActor @Sendable () -> Void

  private let discardsUnsavedChangesOnClose: Bool
  init(discardsUnsavedChangesOnClose: Bool = LDTXRuntimeMode.discardsUnsavedChangesOnClose) {
    self.discardsUnsavedChangesOnClose = discardsUnsavedChangesOnClose
    super.init()
  }
  var chooseCloseAction: ((NSWindow) -> NSApplication.ModalResponse)?
  private var onClose: CloseOperation?
  private var saveBeforeClose: SaveOperation?
  private var hasUnsavedChanges = false
  private var onBecomeKey: BecomeKeyOperation?
  private weak var observedWindow: NSWindow?
  private var closeIsAllowed = false
  private var closeIsPending = false
  private weak var pendingWindow: NSWindow?

  func beginInstalling(
    window: NSWindow?, hasUnsavedChanges: Bool,
    saveBeforeClose: @escaping SaveOperation, onClose: @escaping CloseOperation,
    onBecomeKey: @escaping BecomeKeyOperation
  ) {
    self.onClose = onClose
    self.saveBeforeClose = saveBeforeClose
    self.hasUnsavedChanges = hasUnsavedChanges
    self.onBecomeKey = onBecomeKey
    install(window: window)
  }
  func install(window: NSWindow?) {
    guard let window else { return }
    if observedWindow === window, window.delegate === self { return }
    observedWindow = window
    window.delegate = self
    if window.isKeyWindow { onBecomeKey?() }
  }
  func windowDidBecomeKey(_ notification: Notification) { onBecomeKey?() }
  func updateDocumentEdited(_ edited: Bool) {
    hasUnsavedChanges = edited
    (observedWindow ?? pendingWindow)?.isDocumentEdited = edited
  }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    if closeIsAllowed { return true }
    guard !closeIsPending, let onClose, confirmDiscardingUnsavedChanges(in: sender) else {
      return false
    }
    closeIsPending = true
    sender.orderOut(nil)
    onClose { [weak self, weak sender] in
      guard let self, let sender else { return }
      self.closeIsAllowed = true
      sender.performClose(nil)
    }
    return false
  }
  @discardableResult
  func closeForReload(afterClose: @escaping AfterCloseOperation) -> Bool {
    guard !closeIsAllowed, !closeIsPending, let onClose,
      let window = observedWindow ?? pendingWindow
    else { return false }
    pendingWindow = nil
    closeIsPending = true
    window.orderOut(nil)
    onClose { [weak self, weak window] in
      guard let self, let window else { return }
      self.closeIsAllowed = true
      window.performClose(nil)
      DispatchQueue.main.async { afterClose() }
    }
    return true
  }
  func confirmClose() -> Bool {
    guard let window = observedWindow else { return true }
    return confirmDiscardingUnsavedChanges(in: window)
  }
  private func confirmDiscardingUnsavedChanges(in window: NSWindow) -> Bool {
    guard hasUnsavedChanges, !discardsUnsavedChangesOnClose else { return true }
    let alert = NSAlert()
    alert.messageText = "Do you want to save the changes made to this Workspace?"
    alert.informativeText = "Your changes will be lost if you don’t save them."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Save")
    alert.addButton(withTitle: "Don’t Save")
    alert.addButton(withTitle: "Cancel")
    switch chooseCloseAction?(window) ?? alert.runModal() {
    case .alertFirstButtonReturn: return saveBeforeClose?() == true
    case .alertSecondButtonReturn: return true
    default: return false
    }
  }
}
