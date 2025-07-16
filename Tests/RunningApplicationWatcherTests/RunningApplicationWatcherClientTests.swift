import Testing
import Dependencies
import AppKit
import RBKit

@testable import RunningApplicationWatcher

@Suite
@MainActor
struct RunningApplicationWatcherClientTests {
  @Test
  func dependencyKey_liveValue_shouldCreateValidClient() async throws {
    await confirmation(expectedCount: 2) { c in
      await withDependencies { deps in
        deps.processInfoClient = .nonXPC
        deps.sysctlClient = .nonZombie
      } operation: {

        let client = RunningApplicationWatcherClient.liveValue

        var events1 = [RunningApplicationEvent]()
        Task {
          for await evt in client.events() {
            events1.append(evt)
            c()
            break
          }
        }

        var events2 = [RunningApplicationEvent]()
        Task {
          for await evt in client.events() {
            events2.append(evt)
            c()
            break
          }
        }

        try? await Task.sleep(for: .seconds(0.5))
      }
    }
  }

}
