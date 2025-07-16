import RBKit
import AppKit

/// Equates by PID, for easier testing.
class AppMock: NSRunningApplication.Mock, @unchecked Sendable {
  override func isEqual(_ object: Any?) -> Bool {
    if let object = object as? AppMock {
      return _processIdentifier == object.processIdentifier
    } else {
      return false
    }
  }
}

