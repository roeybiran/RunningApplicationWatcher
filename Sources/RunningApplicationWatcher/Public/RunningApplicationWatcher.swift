import Foundation
import AppKit
import Dependencies
import DependenciesMacros
import RBKit

// https://developer.apple.com/documentation/foundation/nskeyvalueobservedchange/newvalue
// "newValue and oldValue will only be non-nil if .new/.old is passed to observe(). In general, get the most up to date value by accessing it directly on the observed object instead."
// https://stackoverflow.com/questions/56427889/kvo-swift-newvalue-is-always-nil

@MainActor
final class RunningApplicationWatcher {

  var appObservations = [NSRunningApplication: [NSKeyValueObservation]]()

  @Dependency(\.processInfoClient) private var processInfo
  @Dependency(\.sysctlClient) private var sysctlClient
  // @Dependency(\.nsWorkspaceClient) private var workspace
  
  private let workspace: NSWorkspace

  public init(workspace: NSWorkspace) {
    self.workspace = workspace
  }

  public func events() -> AsyncStream<RunningApplicationEvent> {
    let (stream, continuation) = AsyncStream.makeStream(of: RunningApplicationEvent.self)

    let runningApplicationsObservation = workspace.observe(\.runningApplications, options: [.initial, .new]) { [weak self, processInfo, sysctlClient] workspace, change in
      guard let self else { assertionFailure(); return }
      guard let unsafeApps = change.newValue else { assert(change.kind == .removal || change.kind == .replacement); return }

      var safeApps = [NSRunningApplication]()

      for unsafeApp in unsafeApps {
        let pid = unsafeApp.processIdentifier

        if unsafeApp == .current {
          continue
        }

        if processInfo.isXPC(pid: pid) {
          debugLog(event: .skippingXPC, app: unsafeApp)
          continue
        }

        if sysctlClient.isZombie(pid: pid) {
          debugLog(event: .skippingZombie, app: unsafeApp)
          continue
        }

        safeApps.append(unsafeApp)
      }

      continuation.yield(.launched(safeApps))

      for safeApp in safeApps {
        debugLog(event: .launched, app: safeApp)

        let isFinishedLaunchingObservation = safeApp.observe(\.isFinishedLaunching, options: [.initial, .new]) { app, change in
          guard app.isFinishedLaunching else { return }
          assert(change.newValue != nil)
          debugLog(event: .isFinishedLaunching(app.isFinishedLaunching), app: app)
          continuation.yield(.didFinishedLaunching(app))
        }

//        let isActiveObservation = safeApp.observe(\.isActive, options: [.initial, .new]) { app, _ in
//          guard app.isActive else { return }
//          debugLog(event: .activated, app: app)
//          continuation.yield(.activated(app))
//        }

        let activationPolicyObservation = safeApp.observe(\.activationPolicy, options: [.new]) { app, change in
          debugLog(event: .activationPolicy(app.activationPolicy), app: app)
          continuation.yield(.activationPolicyChanged(app))
        }

        let isHiddenObservation = safeApp.observe(\.isHidden, options: [.new]) { app, change in
          assert(change.newValue != nil)
          debugLog(event: .isHidden(app.isHidden), app: app)
          continuation.yield(app.isHidden ? .hidden(app) : .unhidden(app))
        }

        let isTerminatedObservation = safeApp.observe(\.isTerminated, options: [.new]) { app, change in
          assert(change.newValue == true)
          debugLog(event: .terminated(app.isTerminated), app: app)
          continuation.yield(.terminated(app))
          Task { @MainActor [weak self] in
            guard let self else { return assertionFailure() }
            guard let existingObservations = appObservations.removeValue(forKey: app) else { return }
            for observation in existingObservations {
              observation.invalidate()
            }
          }
        }

        Task { @MainActor [weak self] in
          guard let self else { return assertionFailure() }
          appObservations[safeApp, default: []] = [
            isFinishedLaunchingObservation,
            activationPolicyObservation,
            isHiddenObservation,
            isTerminatedObservation
          ]
        }
      }
    }

    //  much more reliable than observing "\.isActive" individually on the app
    let frontmostApplicationObservation = workspace.observe(\.frontmostApplication, options: [.initial, .new]) { workspace, change in
      guard let app = workspace.frontmostApplication else { return }
      debugLog(event: .activated, app: app)
      Task { @MainActor [weak self] in
        guard let self else { return assertionFailure() }
        if appObservations[app] == nil { return }
        continuation.yield(.activated(app))
      }
    }

    continuation.onTermination = { _ in
      runningApplicationsObservation.invalidate()
      frontmostApplicationObservation.invalidate()
    }


    return stream
  }
}

//  private func isXPC(_ app: NSRunningApplication) -> Bool {
//    // example for XPC service that if observed, crashes Syphon. Launched whenever you run an Xcode playground
//    // /Applications/Xcode.app/Contents/SharedFrameworks/DVTPlaygroundStubMacServices.framework/Versions/A/XPCServices/com.apple.dt.Xcode.PlaygroundStub-macosx.xpc/
//    // https://github.com/lwouis/alt-tab-macos/blob/70ee681757628af72ed10320ab5dcc552dcf0ef6/src/logic/Applications.swift#L109
//    if let bundleURL = app.bundleURL, let bundle = bundleClient.create(url: bundleURL) {
//      let isXPCService = bundleClient.object(inBundle: bundle, forInfoDictionaryKey: "XPCService") != nil
//      let isBundlePackgeTypeXPC = bundleClient
//        .object(inBundle: bundle, forInfoDictionaryKey: "CFBundlePackageType") as? String == "XPC!"
//      let isXPC = isXPCService || isBundlePackgeTypeXPC
//      if isXPC { return false }
//    }
//  }

