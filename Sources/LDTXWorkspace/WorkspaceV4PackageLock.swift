// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation

/// A process-scoped exclusive lock beside a V4 Workspace package.
///
/// The App and CLI intentionally use the same sibling lock path, so a package
/// cannot be replaced beneath an open Workspace session.
public struct WorkspaceV4PackageLock: Sendable {
  fileprivate let descriptor: Int32
}

public enum WorkspaceV4PackageLockError: Error, Equatable, LocalizedError, Sendable {
  case alreadyLocked(URL)
  case invalidPackage(URL)
  case operationFailed(URL, Int32)

  public var errorDescription: String? {
    switch self {
    case .alreadyLocked: "The Workspace is already locked."
    case .invalidPackage(let url): "The Workspace package is not a directory: \(url.path)"
    case .operationFailed(let url, let code):
      "The Workspace lock operation failed for \(url.path) (errno \(code))."
    }
  }
}

public struct WorkspaceV4PackageLockService: Sendable {
  public static let fileName = "LDTX.lock"

  public init() {}

  public func acquire(
    at packageURL: URL,
    createsPackageDirectory: Bool = false
  ) throws -> WorkspaceV4PackageLock {
    let packageURL = packageURL.resolvingSymlinksInPath().standardizedFileURL
    var isDirectory = ObjCBool(false)
    if FileManager.default.fileExists(atPath: packageURL.path, isDirectory: &isDirectory) {
      guard isDirectory.boolValue else {
        throw WorkspaceV4PackageLockError.invalidPackage(packageURL)
      }
    } else if createsPackageDirectory {
      try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    } else {
      throw WorkspaceV4PackageLockError.invalidPackage(packageURL)
    }

    let lockURL = lockURL(for: packageURL)
    let descriptor = lockURL.path.withCString {
      Darwin.open($0, O_CREAT | O_RDWR | O_EXLOCK | O_NONBLOCK, S_IRUSR | S_IWUSR)
    }
    guard descriptor >= 0 else {
      let code = errno
      if code == EWOULDBLOCK { throw WorkspaceV4PackageLockError.alreadyLocked(lockURL) }
      throw WorkspaceV4PackageLockError.operationFailed(lockURL, code)
    }
    return WorkspaceV4PackageLock(descriptor: descriptor)
  }

  public func release(_ lock: WorkspaceV4PackageLock) {
    _ = Darwin.close(lock.descriptor)
  }

  public func lockURL(for packageURL: URL) -> URL {
    let packageURL = packageURL.resolvingSymlinksInPath().standardizedFileURL
    return packageURL.deletingLastPathComponent().appendingPathComponent(
      ".\(packageURL.lastPathComponent).\(Self.fileName)", isDirectory: false)
  }
}
