// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import Foundation

@MainActor
final class ApplicationTerminationCoordinator {
  struct Participant {
    let confirm: () -> Bool
    let cancelConfirmation: () -> Void
    let stop: () async -> Void

    init(
      confirm: @escaping () -> Bool,
      cancelConfirmation: @escaping () -> Void = {},
      stop: @escaping () async -> Void
    ) {
      self.confirm = confirm
      self.cancelConfirmation = cancelConfirmation
      self.stop = stop
    }
  }
  private(set) var isTerminating = false

  func terminate(_ participants: [Participant]) async -> Bool {
    guard !isTerminating else { return false }
    isTerminating = true
    defer { isTerminating = false }
    // Confirm every window before stopping any session.
    guard participants.allSatisfy({ $0.confirm() }) else {
      for participant in participants { participant.cancelConfirmation() }
      return false
    }
    for participant in participants { await participant.stop() }
    return true
  }
}
