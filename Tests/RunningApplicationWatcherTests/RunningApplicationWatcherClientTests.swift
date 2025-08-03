import AppKit
import Dependencies
import RBKit
import Testing

@testable import RunningApplicationWatcher

@Suite("RunningApplicationWatcherClient Tests")
@MainActor
struct RunningApplicationWatcherClientTests {
  @Test("dependency key live value should create valid client")
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
