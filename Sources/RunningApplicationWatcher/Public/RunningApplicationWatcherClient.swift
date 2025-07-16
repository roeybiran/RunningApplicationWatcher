import Foundation
import AppKit
import Dependencies
import DependenciesMacros

@DependencyClient
public struct RunningApplicationWatcherClient: Sendable {
  public var events: @MainActor @Sendable () -> AsyncStream<RunningApplicationEvent> = { .finished }
}

extension RunningApplicationWatcherClient: DependencyKey {
  public static let liveValue: Self = {
    return Self(events: {
      let instance = RunningApplicationWatcher(workspace: .shared)
      let (stream, cont) = AsyncStream.makeStream(of: RunningApplicationEvent.self)
      let task = Task {
        for await event in instance.events() {
          cont.yield(event)
        }
      }
      cont.onTermination = { _ in
        task.cancel()
      }
      return stream
    })
  }()
  public static let testValue = Self()
}

extension DependencyValues {
  public var runningApplicationWatcherClient: RunningApplicationWatcherClient {
    get { self[RunningApplicationWatcherClient.self] }
    set { self[RunningApplicationWatcherClient.self] = newValue }
  }
}
