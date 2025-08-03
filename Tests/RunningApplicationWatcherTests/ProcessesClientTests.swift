import ApplicationServices
import Dependencies
import Foundation
import Testing

@testable import RunningApplicationWatcher

@Suite
struct ProcessesClientTests {
  @Test
  func isXPC_whenProcessTypeIsXPC_shouldReturnTrue() async throws {
    let client = ProcessesClient(
      getProcessInformation: { _, info in
        info.pointee.processType = NSHFSTypeCodeFromFileType("'XPC!'")
        return .zero
      },
      getProcessForPID: { _, _ in noErr })

    #expect(client.isXPC(pid: 123) == true)
  }

  @Test
  func isXPC_whenProcessTypeIsNotXPC_shouldReturnFalse() async throws {
    let client = ProcessesClient(
      getProcessInformation: { _, info in
        info.pointee.processType = NSHFSTypeCodeFromFileType("'APPL'")
        return .zero
      },
      getProcessForPID: { _, _ in noErr })

    #expect(client.isXPC(pid: 123) == false)
  }

  @Test
  func isXPC_withValidPid_shouldCallGetProcessInformationOnce() async throws {
    await confirmation(expectedCount: 1) { c in
      let client = ProcessesClient(
        getProcessInformation: { _, info in
          c()
          info.pointee.processType = NSHFSTypeCodeFromFileType("'XPC!'")
          return .zero
        },
        getProcessForPID: { _, _ in noErr })

      _ = client.isXPC(pid: 456)
    }
  }

  @Test
  func isXPC_withValidPid_shouldCallGetProcessForPIDOnceWithCorrectParameters() async throws {
    await confirmation(expectedCount: 1) { c in
      let client = ProcessesClient(
        getProcessInformation: { _, info in
          info.pointee.processType = NSHFSTypeCodeFromFileType("'XPC!'")
          return .zero
        },
        getProcessForPID: { pid, _ in
          c()
          #expect(pid == 456)
          return noErr
        })

      _ = client.isXPC(pid: 456)
    }
  }
}
