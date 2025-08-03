import Dependencies
import Foundation
import Testing
@testable import RunningApplicationWatcher

@Suite("SysctlClient Tests")
struct SysctlClientTests {

  @Test("isZombie returns true when process is zombie")
  func isZombie_whenProcessIsZombie_returnsTrue() async throws {
    let client = SysctlClient(
      run: { _, _, oldp, _, _, _ in
        guard let kinfo = oldp?.assumingMemoryBound(to: kinfo_proc.self) else { return -1 }
        kinfo.pointee.kp_proc.p_stat = CChar(SZOMB)
        return 0
      })

    #expect(client.isZombie(pid: 123) == true)
  }

  @Test("isZombie returns false when process is not zombie")
  func isZombie_whenProcessIsNotZombie_returnsFalse() async throws {
    let client = SysctlClient(
      run: { _, _, oldp, _, _, _ in
        guard let kinfo = oldp?.assumingMemoryBound(to: kinfo_proc.self) else { return -1 }
        kinfo.pointee.kp_proc.p_stat = CChar(SRUN)
        return 0
      })

    #expect(client.isZombie(pid: 123) == false)
  }

  @Test("isZombie calls run dependency once with correct parameters")
  func isZombie_callsRunDependencyOnceWithCorrectParameters() async throws {
    await confirmation { c in
      let client = SysctlClient(
        run: { mib, count, oldp, oldlenp, _, _ in
          c()
          let capturedMib = Array(UnsafeBufferPointer(start: mib, count: Int(count)))
          let capturedSize = oldlenp?.pointee
          let capturedCount = count
          #expect(capturedMib == [CTL_KERN, KERN_PROC, KERN_PROC_PID, 123])
          #expect(capturedSize == MemoryLayout<kinfo_proc>.stride)
          #expect(capturedCount == 4)
          guard let kinfo = oldp?.assumingMemoryBound(to: kinfo_proc.self) else { return -1 }
          kinfo.pointee.kp_proc.p_stat = CChar(SRUN)
          return 0
        })

      _ = client.isZombie(pid: 123)
    }
  }
}
