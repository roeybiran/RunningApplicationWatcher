import AppKit

public enum RunningApplicationEvent: Hashable, Sendable {
  case launched([NSRunningApplication])
  case didFinishedLaunching(NSRunningApplication)
  case activated(NSRunningApplication)
  case terminated(NSRunningApplication)
  case hidden(NSRunningApplication)
  case unhidden(NSRunningApplication)
  case activationPolicyChanged(NSRunningApplication)
}
