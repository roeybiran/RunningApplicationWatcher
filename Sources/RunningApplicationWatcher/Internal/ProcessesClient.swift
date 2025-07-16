import Foundation
import ApplicationServices

import Dependencies
import DependenciesMacros

@DependencyClient
struct ProcessesClient: Sendable {
  var getProcessInformation: @Sendable (_ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ info: UnsafeMutablePointer<ProcessInfoRec>) -> OSErr = { _, _ in 0 }
  var getProcessForPID: @Sendable (_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus = { _, _ in 0 }
}


extension ProcessesClient {
  // "these private APIs are more reliable than Bundle.init? as it can return nil (e.g. for com.apple.dock.etci)"
  // https://github.com/lwouis/alt-tab-macos/blob/70ee681757628af72ed10320ab5dcc552dcf0ef6/src/logic/Applications.swift#L115
  func isXPC(pid: pid_t) -> Bool {
    var psn = ProcessSerialNumber()
    _ = getProcessForPID(pid, &psn)
    var info = ProcessInfoRec()
    _ = getProcessInformation(&psn, &info)
    // https://github.com/lwouis/alt-tab-macos/blob/70ee681757628af72ed10320ab5dcc552dcf0ef6/src/api-wrappers/HelperExtensions.swift#L174
    let nsFileType = NSFileTypeForHFSTypeCode(info.processType).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
    debugLog("ProcessClient nsFileType: \(nsFileType)")
    return nsFileType == "XPC!"
  }
}

extension ProcessesClient: DependencyKey {
  static let liveValue = Self(
    getProcessInformation: GetProcessInformation,
    getProcessForPID: GetProcessForPID,
  )

  static let testValue = Self()

#if DEBUG
  static let nonXPC = ProcessesClient(
    getProcessInformation: { _, info in
      info.pointee.processType = NSHFSTypeCodeFromFileType("'APPL'")
      return .zero
    },
    getProcessForPID: { _, _ in noErr }
  )
#endif
}

extension DependencyValues {
  var processInfoClient: ProcessesClient {
    get { self[ProcessesClient.self] }
    set { self[ProcessesClient.self] = newValue }
  }
}


// see Processes.h
// https://github.com/lwouis/alt-tab-macos/blob/70ee681757628af72ed10320ab5dcc552dcf0ef6/src/api-wrappers/PrivateApis.swift#L228
@_silgen_name("GetProcessInformation") @discardableResult
func GetProcessInformation(_ psn: UnsafeMutablePointer<ProcessSerialNumber>, _ info: UnsafeMutablePointer<ProcessInfoRec>) -> OSErr

// https://github.com/lwouis/alt-tab-macos/blob/70ee681757628af72ed10320ab5dcc552dcf0ef6/src/api-wrappers/PrivateApis.swift#L232
@_silgen_name("GetProcessForPID") @discardableResult
func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

