// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LDTXAppKitUI
import LDTXAppUI
import LDTXRecordPlayerUI
import LDTXRecording
import LDTXWorkspace
import LDTXYouTubeAuth
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public enum LDTXApp {
  public static func main() {
    let app = NSApplication.shared
    let delegate = LDTXApplicationDelegate()
    app.setActivationPolicy(.regular)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
  }
}

struct WorkspaceWindowRequest: Codable, Hashable {
  enum Source: Codable, Hashable {
    case new(UUID)
    case file(URL)
  }
  let source: Source
  static func new() -> Self { Self(source: .new(UUID())) }
  static func file(_ url: URL) -> Self { Self(source: .file(url.standardizedFileURL)) }
}
typealias WorkspaceSceneRequest = WorkspaceWindowRequest

@MainActor
final class ApplicationWindows: NSObject, NSMenuItemValidation {
  static weak var current: ApplicationWindows?
  private let delegate: LDTXApplicationDelegate
  private let youtubeClientService: YouTubeClientService
  private let oauthClientState: OAuthClientState
  private let authState: YouTubeAuthState
  private var v4Workspaces: [WorkspaceWindowRequest: WorkspaceV4WindowController] = [:]
  private var recordings: [URL: RecordingWindowController] = [:]
  private var launcher: NSWindowController?
  private var settings: NSWindowController?
  private let terminationCoordinator = ApplicationTerminationCoordinator()
  private var closingObserver: NSObjectProtocol?

  init(delegate: LDTXApplicationDelegate) {
    self.delegate = delegate
    let service = AppFeatureRegistry.provider.makeYouTubeClientService()
    youtubeClientService = service
    oauthClientState = OAuthClientState(
      youtubeClientService: service,
      restoresPersistedOAuthClient: !LDTXRuntimeMode.isPreview && !LDTXRuntimeMode.isUITesting
        && !LDTXRuntimeMode.isUnitTesting)
    authState = YouTubeAuthState(youtubeClientService: service)
    super.init()
    Self.current = self
    delegate.applicationRouter.launcherOpenCoordinator.installOpenHandler { [weak self] in
      self?.showLauncher()
    }
    delegate.applicationRouter.workspaceOpenCoordinator.installOpenHandler { [weak self] in
      self?.openWorkspace(.file($0))
    }
    delegate.applicationRouter.recordingOpenCoordinator.installOpenHandler { [weak self] in
      self?.openRecording($0)
    }
    closingObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: nil, queue: .main
    ) { [weak self] notification in
      guard let window = notification.object as? NSWindow else { return }
      MainActor.assumeIsolated {
        guard let self else { return }
        self.v4Workspaces = self.v4Workspaces.filter { $0.value.window !== window }
        self.recordings = self.recordings.filter { $0.value.window !== window }
        if self.settings?.window === window { self.authState.cancelAuthorization() }
      }
    }
    installMenus()
  }

  func launch() {
    if LDTXRuntimeMode.isPreview {
      launcher = hostWindow(
        Text("LDTX Preview"), title: "LDTX Preview", size: NSSize(width: 320, height: 200))
      launcher?.showWindow(nil)
    } else if LDTXRuntimeMode.isUITesting {
      openWorkspace(.new())
    } else if let fixture = LDTXRuntimeMode.recordingPreviewFixture {
      openRecording(fixture.recordingURL)
    } else if v4Workspaces.isEmpty && recordings.isEmpty {
      showLauncher()
    }
    NSApp.activate(ignoringOtherApps: true)
  }

  func showLauncher() {
    if launcher == nil {
      launcher = hostWindow(
        LauncherContent(
          newWorkspace: { [weak self] in self?.openWorkspaceV4(.new()) },
          openFile: { [weak self] in self?.openFile(nil) }),
        title: "LDTX", size: NSSize(width: 420, height: 260))
      launcher?.window?.styleMask.remove(.resizable)
    }
    launcher?.showWindow(nil)
    launcher?.window?.makeKeyAndOrderFront(nil)
  }

  @discardableResult
  func openWorkspace(_ request: WorkspaceWindowRequest) -> NSWindow? {
    openWorkspaceV4(request)
  }

  @discardableResult
  func openWorkspaceV4(_ request: WorkspaceWindowRequest) -> NSWindow? {
    if let existing = v4Workspaces[request] {
      existing.showWindow(nil)
      existing.window?.makeKeyAndOrderFront(nil)
      return existing.window
    }
    let controller = WorkspaceV4WindowController(
      request: request,
      lowFrequencyUpdateRegistry: delegate.lowFrequencyUpdateRegistry,
      diagnosticsContext: delegate.applicationRouter.recordingDiagnosticsContextIfEnabled())
    controller.identityChanged = { [weak self, weak controller] request in
      guard let self, let controller else { return }
      self.v4Workspaces = self.v4Workspaces.filter { $0.value !== controller }
      self.v4Workspaces[request] = controller
    }
    guard controller.start() else {
      controller.close()
      return nil
    }
    v4Workspaces[request] = controller
    controller.showWindow(nil)
    launcher?.close()
    return controller.window
  }

  @discardableResult
  func openRecording(_ url: URL) -> NSWindow? {
    let url = url.standardizedFileURL
    if let controller = recordings[url] {
      controller.showWindow(nil)
      controller.window?.makeKeyAndOrderFront(nil)
      return controller.window
    }
    let controller = RecordingWindowController(
      recordingURL: url, scenarioFixture: LDTXRuntimeMode.recordingPreviewFixture)
    controller.window?.identifier = NSUserInterfaceItemIdentifier(
      "Recording.AppKit.v1." + UUID().uuidString)
    controller.window?.restorationClass = ApplicationWindowRestorer.self
    controller.window?.isRestorable = true
    recordings[url] = controller
    controller.showWindow(nil)
    launcher?.close()
    return controller.window
  }

  @objc func newWorkspace(_ sender: Any?) { openWorkspaceV4(.new()) }
  @objc func openFile(_ sender: Any?) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [
      UTType(exportedAs: "tokyo.kaito.ldtx.workspace"),
      UTType(exportedAs: "tokyo.kaito.ldtx.recording"),
    ]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    delegate.application(NSApp, open: [url])
  }
  @objc func save(_ sender: Any?) {
    if let activeV4Workspace { activeV4Workspace.save() }
  }
  @objc func saveAs(_ sender: Any?) {
    if let activeV4Workspace { activeV4Workspace.saveAs() }
  }
  @objc func reload(_ sender: Any?) {
    activeV4Workspace?.reload()
  }
  @objc func toggleInspector(_ sender: Any?) {
    if let workspace = activeV4Workspace {
      workspace.toggleInspector(sender)
    } else {
      (NSApp.keyWindow?.windowController as? RecordingWindowController)?.toggleInspector(sender)
    }
  }
  @objc func crashReports(_ sender: Any?) {
    NSWorkspace.shared.open(
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Logs/DiagnosticReports", isDirectory: true))
  }
  @objc func showSettings(_ sender: Any?) {
    if settings == nil {
      settings = hostWindow(
        SettingsContent(oauth: oauthClientState, auth: authState), title: "Settings",
        size: NSSize(width: 600, height: 480))
    }
    settings?.showWindow(nil)
    settings?.window?.makeKeyAndOrderFront(nil)
  }
  private var activeV4Workspace: WorkspaceV4WindowController? {
    NSApp.keyWindow?.windowController as? WorkspaceV4WindowController
  }
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(save), #selector(saveAs): return activeV4Workspace != nil
    case #selector(reload):
      return activeV4Workspace.map { !$0.recordingSession.isRecording } ?? false
    case #selector(toggleInspector):
      return activeV4Workspace != nil
        || NSApp.keyWindow?.windowController is RecordingWindowController
    default: return true
    }
  }

  func terminate(reply: @escaping (Bool) -> Void) {
    let participants = v4Workspaces.values.map { controller in
      ApplicationTerminationCoordinator.Participant(
        confirm: { controller.confirmTermination() },
        cancelConfirmation: { controller.cancelTerminationConfirmation() },
        stop: { await controller.closeWorkspace() })
    }
    Task { @MainActor in
      reply(await terminationCoordinator.terminate(participants))
    }
  }

  private func installMenus() {
    let main = NSMenu()
    func menu(_ name: String) -> NSMenu {
      let item = NSMenuItem()
      item.title = name
      let menu = NSMenu(title: name)
      item.submenu = menu
      main.addItem(item)
      return menu
    }
    func add(
      _ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
      target: AnyObject? = nil
    ) {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
      item.target = target
      menu.addItem(item)
    }
    let app = menu("LDTX")
    add(app, "About LDTX", #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
    add(app, "Settings…", #selector(showSettings), ",", target: self)
    app.addItem(.separator())
    let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
    services.submenu = NSMenu(title: "Services")
    app.addItem(services)
    NSApp.servicesMenu = services.submenu
    add(app, "Hide LDTX", #selector(NSApplication.hide(_:)), "h")
    add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
    app.addItem(.separator())
    add(app, "Quit LDTX", #selector(NSApplication.terminate(_:)), "q")
    let file = menu("File")
    add(file, "New Workspace", #selector(newWorkspace), "n", target: self)
    add(file, "Open File…", #selector(openFile), "o", target: self)
    add(file, "Close", #selector(NSWindow.performClose(_:)), "w")
    add(file, "Save", #selector(save), "s", target: self)
    add(file, "Save As…", #selector(saveAs), "S", target: self)
    add(file, "Reload Workspace", #selector(reload), target: self)
    let edit = menu("Edit")
    for (title, selector, key) in [
      ("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
      ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a"),
    ] { add(edit, title, NSSelectorFromString(selector), key) }
    let view = menu("View")
    add(view, "Toggle Inspector", #selector(toggleInspector), target: self)
    let window = menu("Window")
    add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
    add(window, "Zoom", #selector(NSWindow.performZoom(_:)))
    NSApp.windowsMenu = window
    let help = menu("Help")
    add(help, "Show Crash Reports in Finder", #selector(crashReports), target: self)
    NSApp.mainMenu = main
  }
}

@MainActor
private func hostWindow<Content: View>(_ content: Content, title: String, size: NSSize)
  -> NSWindowController
{
  let window = NSWindow(contentViewController: NSHostingController(rootView: content))
  window.title = title
  window.setContentSize(size)
  window.center()
  window.isReleasedWhenClosed = false
  return NSWindowController(window: window)
}

private struct LauncherContent: View {
  let newWorkspace: () -> Void
  let openFile: () -> Void
  var body: some View {
    VStack(spacing: 20) {
      Image(systemName: "video.badge.waveform").font(.system(size: 44)).foregroundStyle(.tint)
      Text("LDTX").font(.largeTitle.bold())
      HStack {
        Button("New Workspace", action: newWorkspace).keyboardShortcut(.defaultAction)
        Button("Open File…", action: openFile)
      }
    }.padding(36)
  }
}
private struct SettingsContent: View {
  @ObservedObject var oauth: OAuthClientState
  @ObservedObject var auth: YouTubeAuthState
  var body: some View {
    SettingsView {
      YouTubeAccountSettingsView(
        oauthStatus: oauth.status, authorizationStatus: auth.status,
        isImportingOAuthClient: $oauth.isImportingOAuthClient,
        canAuthorize: oauth.configuration != nil && !auth.isAuthorizing,
        restoreAuthorization: { auth.restore(for: oauth.configuration) },
        authorizeYouTube: { auth.authorize(configuration: oauth.configuration) },
        loadOAuthClient: { oauth.load(from: $0) != nil })
    }
  }
}

@MainActor
final class ApplicationWindowRestorer: NSObject, NSWindowRestoration {
  static func restoreWindow(
    withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder,
    completionHandler: @escaping (NSWindow?, (any Error)?) -> Void
  ) {
    guard let windows = ApplicationWindows.current,
      let url = state.decodeObject(of: NSURL.self, forKey: "LDTX.AppKit.v1.url") as URL?,
      let kind = state.decodeObject(of: NSString.self, forKey: "LDTX.AppKit.v1.kind") as String?,
      FileManager.default.fileExists(atPath: url.path)
    else {
      completionHandler(nil, nil)
      return
    }
    let window: NSWindow?
    switch kind {
    case "workspace": window = windows.openWorkspace(.file(url))
    case "recording": window = windows.openRecording(url)
    default: window = nil
    }
    window?.identifier = identifier
    completionHandler(window, nil)
  }
}
