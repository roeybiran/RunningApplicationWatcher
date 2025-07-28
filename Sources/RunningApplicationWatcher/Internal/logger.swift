import AppKit
import os

private let logger = Logger(
  subsystem: Bundle.main.bundleIdentifier ?? "",
  category: "running application watcher"
)

func debugLog(_ message: String) {
  guard UserDefaults.standard.bool(forKey: "_RunningApplicationWatcherLoggingEnabled") else { return }
  logger.log("\(message, privacy: .public)")
}

enum Event: CustomStringConvertible {
  case launched
  case terminated(Bool?)
  case activationPolicy(NSApplication.ActivationPolicy?)
  case isFinishedLaunching(Bool?)
  case isHidden(Bool?)
  case activated
  case skippingXPC
  case skippingZombie

  var description: String {
    switch self {
    case .launched:
      "launched"
    case .terminated(let bool):
      "terminated \(String(describing: bool))"
    case .activationPolicy(let activationPolicy):
      "activation policy \(String(describing: activationPolicy))"
    case .isFinishedLaunching(let bool):
      "is finished launching \(String(describing: bool))"
    case .isHidden(let bool):
      "is hidden \(String(describing: bool))"
    case .activated:
      "activated"
    case .skippingXPC:
      "skipping XPC"
    case .skippingZombie:
      "skipping zombie"
    }
  }
}

func debugLog(event: Event, app: NSRunningApplication?) {
  debugLog("\(event): <\(app?.localizedName ?? "UNKNOWN")>")
}


