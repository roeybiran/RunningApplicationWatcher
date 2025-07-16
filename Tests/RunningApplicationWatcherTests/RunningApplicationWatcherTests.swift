import Testing
import Dependencies
import AppKit
import ApplicationServices
import RBKit

@testable import RunningApplicationWatcher

@Suite(.serialized)
@MainActor
struct RunningApplicationWatcherTests {
  private static let testSleepDuration: Duration = .seconds(0.02)

  @Test
  func events_shouldObserveCorrectNSWorkSpaceKeyPaths() async throws {
    await withDependencies { deps in
      deps.processInfoClient = .nonXPC
      deps.sysctlClient = .nonZombie
    } operation: {
      var observeCalls: [(keyPath: String, options: NSKeyValueObservingOptions)] = []
      let mockWorkspace = NSWorkspace.Mock()
      mockWorkspace._addObserver = { observer, keyPath, options, context in
        observeCalls.append((keyPath: keyPath, options: options))
      }
      let sut = RunningApplicationWatcher(workspace: mockWorkspace)

      Task {
        for await _ in sut.events() {
        }
      }

      try? await Task.sleep(for: Self.testSleepDuration)

      let expectedCalls = [
        (keyPath: "runningApplications", options: NSKeyValueObservingOptions([.initial, .new])),
        (keyPath: "frontmostApplication", options: NSKeyValueObservingOptions([.initial, .new]))
      ]

      for (i, call) in expectedCalls.enumerated() {
        #expect(call.keyPath == observeCalls[i].keyPath)
        #expect(call.options == observeCalls[i].options)
      }

      #expect(observeCalls.count == 2)
    }
  }

  // MARK: - NSWorkspace.runningApplications Observations

  @Test
  func events_withRunningApplicationsChanged_shouldEmitLaunchedEvent() async throws {
    await withDependencies { deps in
      deps.processInfoClient = .nonXPC
      deps.sysctlClient = .nonZombie
    } operation: {
      var collectedEvents: [RunningApplicationEvent] = []

      let mockApp1 = AppMock(_isFinishedLaunching: false, _processIdentifier: 0)
      let mockApp2 = AppMock(_isFinishedLaunching: false, _processIdentifier: 1)
      let mockApps = [mockApp1, mockApp2]
      let mockWorkspace = NSWorkspace.Mock()
      mockWorkspace._frontmostApplication = mockApp1

      let sut = RunningApplicationWatcher(workspace: mockWorkspace)

      Task {
        for await event in sut.events() {
          collectedEvents.append(event)
        }
      }

      mockWorkspace._runningApplications = mockApps

      try? await Task.sleep(for: Self.testSleepDuration)

      #expect(Set(sut.appObservations.keys) == Set(mockApps))
      #expect(sut.appObservations.keys.count == 2)

      for (_, value) in sut.appObservations {
        #expect(value.count == 4)
      }
      
      let expectedEvents: [RunningApplicationEvent] = [
        .launched(mockApps),
        .activated(mockApp1)
      ]
      
      #expect(collectedEvents == expectedEvents)
    }
  }

  @Test
  func events_withFirstAppIsCurrent_shouldSkipApp() async throws {
    await withDependencies { deps in
      deps.processInfoClient = .nonXPC
      deps.sysctlClient = .nonZombie
    } operation: {
      let regularApp = AppMock(_isFinishedLaunching: false, _processIdentifier: 1)
      let mockApps = [.current, regularApp]
      let mockWorkspace = NSWorkspace.Mock()
      let sut = RunningApplicationWatcher(workspace: mockWorkspace)

      var collectedEvents: [RunningApplicationEvent] = []
      Task {
        for await event in sut.events() {
          collectedEvents.append(event)
        }
      }

      mockWorkspace._runningApplications = mockApps
      try? await Task.sleep(for: Self.testSleepDuration)

      #expect(sut.appObservations.keys.count == 1)
      #expect(sut.appObservations[regularApp]?.count == 4)
      
      let expectedEvents: [RunningApplicationEvent] = [
        .launched([regularApp])
      ]
      
      #expect(collectedEvents == expectedEvents)
    }
  }

  @Test
  func events_withFirstAppIsXPC_shouldSkipApp() async throws {
    await withDependencies { deps in
      deps.processInfoClient = ProcessesClient(
        getProcessInformation: { pid, info in
          if pid.pointee.highLongOfPSN == 0 {
            info.pointee.processType = NSHFSTypeCodeFromFileType("'XPC!'")
          } else {
            info.pointee.processType = NSHFSTypeCodeFromFileType("'APPL'")
          }
          return .zero
        },
        getProcessForPID: { pid, ptr in
          if pid == 0 {
            ptr.pointee = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: 0)
          } else {
            ptr.pointee = ProcessSerialNumber(highLongOfPSN: 1, lowLongOfPSN: 1)
          }
          return noErr
        }
      )
      deps.sysctlClient = .nonZombie
    } operation: {
      let xpcApp = AppMock(_isFinishedLaunching: false, _processIdentifier: 0)
      let regularApp = AppMock(_isFinishedLaunching: false, _processIdentifier: 1)
      let mockApps = [xpcApp, regularApp]
      let mockWorkspace = NSWorkspace.Mock()

      var collectedEvents: [RunningApplicationEvent] = []
      let sut = RunningApplicationWatcher(workspace: mockWorkspace)

      Task {
        for await event in sut.events() {
          collectedEvents.append(event)
        }
      }

      mockWorkspace._runningApplications = mockApps

      try? await Task.sleep(for: Self.testSleepDuration)

      #expect(sut.appObservations.keys.count == 1)
      #expect(sut.appObservations[regularApp]?.count == 4)
      
      let expectedEvents: [RunningApplicationEvent] = [
        .launched([regularApp])
      ]
      
      #expect(collectedEvents == expectedEvents)
    }
  }

  @Test
  func events_withFirstAppIsZombie_shouldSkipApp() async throws {
    await withDependencies { deps in
      deps.processInfoClient = .nonXPC
      deps.sysctlClient = SysctlClient(
        run: { mib, miblen, oldp, oldlenp, newp, newlen in
          // Mock sysctl behavior: return zombie status based on PID
          if let kinfo = oldp?.assumingMemoryBound(to: kinfo_proc.self) {
            if mib?[3] == 0 { // PID 0 is zombie
              kinfo.pointee.kp_proc.p_stat = CChar(SZOMB)
            } else { // PID 1 is not zombie
              kinfo.pointee.kp_proc.p_stat = CChar(SRUN)
            }
          }
          return 0
        }
      )
    } operation: {
      let zombieApp = AppMock(_isFinishedLaunching: false, _processIdentifier: 0)
      let regularApp = AppMock(_isFinishedLaunching: false, _processIdentifier: 1)
      let mockApps = [zombieApp, regularApp]
      let mockWorkspace = NSWorkspace.Mock()
      var collectedEvents: [RunningApplicationEvent] = []
      let sut = RunningApplicationWatcher(workspace: mockWorkspace)

      Task {
        for await event in sut.events() {
          collectedEvents.append(event)
        }
      }

      mockWorkspace._runningApplications = mockApps

      try? await Task.sleep(for: Self.testSleepDuration)

      #expect(sut.appObservations.keys.count == 1)
      #expect(sut.appObservations[regularApp]?.count == 4)
      
      let expectedEvents: [RunningApplicationEvent] = [
        .launched([regularApp])
      ]
      
      #expect(collectedEvents == expectedEvents)
    }
  }

  // MARK: - NSWorkspace.frontmostApplication Observations

  @Test
  func events_withFrontmostApplicationChanged_shouldEmitActivatedEvent() async throws {
    await withDependencies { deps in
      deps.processInfoClient = .nonXPC
      deps.sysctlClient = .nonZombie
    } operation: {
      let mockApp = AppMock(_isFinishedLaunching: false, _processIdentifier: 0)
      let mockApp2 = AppMock(_isFinishedLaunching: false, _processIdentifier: 1)
      let mockWorkspace = NSWorkspace.Mock()
      mockWorkspace._runningApplications = [mockApp, mockApp2]
      mockWorkspace._frontmostApplication = mockApp

      var collectedEvents: [RunningApplicationEvent] = []
      let sut = RunningApplicationWatcher(workspace: mockWorkspace)

      Task {
        for await event in sut.events() {
          collectedEvents.append(event)
        }
      }

      try? await Task.sleep(for: Self.testSleepDuration)
      mockWorkspace._frontmostApplication = mockApp2
      try? await Task.sleep(for: Self.testSleepDuration)

      let expectedEvents: [RunningApplicationEvent] = [
        .launched([mockApp, mockApp2]),
        .activated(mockApp),
        .activated(mockApp2),
      ]

      #expect(collectedEvents == expectedEvents)
    }
  }

  @Test
  func events_withFrontmostApplicationNil_shouldNotEmitActivatedEvent() async throws {
    await withDependencies { deps in
      deps.processInfoClient = .nonXPC
      deps.sysctlClient = .nonZombie
    } operation: {
      let mockApp = AppMock(_isFinishedLaunching: false, _processIdentifier: 0)
      let mockWorkspace = NSWorkspace.Mock()
      mockWorkspace._runningApplications = [mockApp]
      mockWorkspace._frontmostApplication = mockApp

      let sut = RunningApplicationWatcher(workspace: mockWorkspace)
      var collectedEvents: [RunningApplicationEvent] = []
      Task {
        for await event in sut.events() {
          collectedEvents.append(event)
        }
      }

      try? await Task.sleep(for: Self.testSleepDuration)
      mockWorkspace._frontmostApplication = nil
      try? await Task.sleep(for: Self.testSleepDuration)

      let expectedEvents: [RunningApplicationEvent] = [
        .launched([mockApp]),
        .activated(mockApp),
      ]

      #expect(collectedEvents == expectedEvents)
    }
  }

  @Test
  func events_withFrontmostApplicationNotObserved_shouldNotEmitActivatedEvent() async throws {
    await withDependencies { deps in
      deps.processInfoClient = .nonXPC
      deps.sysctlClient = .nonZombie
    } operation: {
      let observedApp = AppMock(_isFinishedLaunching: false, _processIdentifier: 0)
      let nonObservedApp = AppMock(_isFinishedLaunching: false, _processIdentifier: 1)
      let mockWorkspace = NSWorkspace.Mock()
      mockWorkspace._runningApplications = [observedApp]
      var collectedEvents: [RunningApplicationEvent] = []

      let sut = RunningApplicationWatcher(workspace: mockWorkspace)

      Task {
        for await event in sut.events() {
          collectedEvents.append(event)
        }
      }

      mockWorkspace._frontmostApplication = nonObservedApp
      try? await Task.sleep(for: Self.testSleepDuration)

      let expectedEvents: [RunningApplicationEvent] = [
        .launched([observedApp])
      ]

      #expect(collectedEvents == expectedEvents)
    }
  }

  // MARK: - NSRunningApplication Observations

  @Test
  func events_withInitialIsFinishedLaunchingTrue_shouldEmitDidFinishedLaunchingEvent() async throws {
    await withDependencies { deps in
      deps.processInfoClient = .nonXPC
      deps.sysctlClient = .nonZombie
    } operation: {
      let mockApp = AppMock(_isFinishedLaunching: true, _processIdentifier: 0)
      let mockWorkspace = NSWorkspace.Mock()
      mockWorkspace._runningApplications = [mockApp]

      var collectedEvents: [RunningApplicationEvent] = []

      let sut = RunningApplicationWatcher(workspace: mockWorkspace)

      Task {
        for await event in sut.events() {
          collectedEvents.append(event)
        }
      }

      try? await Task.sleep(for: Self.testSleepDuration)

      let expectedEvents: [RunningApplicationEvent] = [
        .launched([mockApp]),
        .didFinishedLaunching(mockApp),
      ]

      #expect(collectedEvents == expectedEvents)
    }
  }

  @Test
  func events_withInitialIsFinishedLaunchingFalse_shouldNotEmitDidFinishedLaunchingEvent() async throws {
    await withDependencies { deps in
      deps.processInfoClient = .nonXPC
      deps.sysctlClient = .nonZombie
    } operation: {
      let mockApp = AppMock(_isFinishedLaunching: false, _processIdentifier: 0)
      let mockWorkspace = NSWorkspace.Mock()
      mockWorkspace._runningApplications = [mockApp]

      var collectedEvents: [RunningApplicationEvent] = []
      let sut = RunningApplicationWatcher(workspace: mockWorkspace)

      Task {
        for await event in sut.events() {
          collectedEvents.append(event)
        }
      }

      try? await Task.sleep(for: Self.testSleepDuration)

      let expectedEvents: [RunningApplicationEvent] = [
        .launched([mockApp]),
      ]

      #expect(collectedEvents == expectedEvents)
    }
  }

  @Test
  func events_withIsFinishedLaunchingChangedToTrue_shouldEmitDidFinishedLaunchingEvent() async throws {
    await withDependencies { deps in
      deps.processInfoClient = .nonXPC
      deps.sysctlClient = .nonZombie
    } operation: {
      let mockApp = AppMock(_isFinishedLaunching: false, _processIdentifier: 0)
      let mockWorkspace = NSWorkspace.Mock()
      mockWorkspace._runningApplications = [mockApp]

      var collectedEvents: [RunningApplicationEvent] = []

      let sut = RunningApplicationWatcher(workspace: mockWorkspace)

      Task {
        for await event in sut.events() {
          collectedEvents.append(event)
        }
      }

      try? await Task.sleep(for: Self.testSleepDuration)
      mockApp._isFinishedLaunching = true
      try? await Task.sleep(for: Self.testSleepDuration)

      let expectedEvents: [RunningApplicationEvent] = [
        .launched([mockApp]),
        .didFinishedLaunching(mockApp),
      ]
      
      #expect(collectedEvents == expectedEvents)
    }
  }

  @Test
  func events_withActivationPolicyChanged_shouldEmitActivationPolicyChangedEvent() async throws {
    await withDependencies { deps in
      deps.processInfoClient = .nonXPC
      deps.sysctlClient = .nonZombie
    } operation: {
      let mockApp = AppMock(_isFinishedLaunching: false, _activationPolicy: .accessory, _processIdentifier: 0)
      let mockWorkspace = NSWorkspace.Mock()
      mockWorkspace._runningApplications = [mockApp]

      var collectedEvents: [RunningApplicationEvent] = []

      let sut = RunningApplicationWatcher(workspace: mockWorkspace)
      Task {
        for await event in sut.events() {
          collectedEvents.append(event)
        }
      }

      try? await Task.sleep(for: Self.testSleepDuration)
      mockApp._activationPolicy = .regular
      try? await Task.sleep(for: Self.testSleepDuration)

      let expectedEvents: [RunningApplicationEvent] = [
        .launched([mockApp]),
        .activationPolicyChanged(mockApp),
      ]
      
      #expect(collectedEvents == expectedEvents)
    }
  }

  @Test
  func events_withIsHiddenChangedToTrue_shouldEmitHiddenEvent() async throws {
    await withDependencies { deps in
      deps.processInfoClient = .nonXPC
      deps.sysctlClient = .nonZombie
    } operation: {
      let mockApp = AppMock(_isFinishedLaunching: false, _isHidden: false, _processIdentifier: 0)
      let mockWorkspace = NSWorkspace.Mock()
      mockWorkspace._runningApplications = [mockApp]

      var collectedEvents: [RunningApplicationEvent] = []
      let sut = RunningApplicationWatcher(workspace: mockWorkspace)
      Task {
        for await event in sut.events() {
          collectedEvents.append(event)
        }
      }

      try? await Task.sleep(for: Self.testSleepDuration)
      mockApp._isHidden = true
      try? await Task.sleep(for: Self.testSleepDuration)

      let expectedEvents: [RunningApplicationEvent] = [
        .launched([mockApp]),
        .hidden(mockApp),
      ]
      
      #expect(collectedEvents == expectedEvents)
    }
  }

  @Test
  func events_withIsHiddenChangedToFalse_shouldEmitUnhiddenEvent() async throws {
    await withDependencies { deps in
      deps.processInfoClient = .nonXPC
      deps.sysctlClient = .nonZombie
    } operation: {
      let mockApp = AppMock(_isFinishedLaunching: false, _isHidden: true, _processIdentifier: 0)
      let mockWorkspace = NSWorkspace.Mock()
      mockWorkspace._runningApplications = [mockApp]

      var collectedEvents: [RunningApplicationEvent] = []

      let sut = RunningApplicationWatcher(workspace: mockWorkspace)
      Task {
        for await event in sut.events() {
          collectedEvents.append(event)
        }
      }

      try? await Task.sleep(for: Self.testSleepDuration)
      mockApp._isHidden = false
      try? await Task.sleep(for: Self.testSleepDuration)

      let expectedEvents: [RunningApplicationEvent] = [
        .launched([mockApp]),
        .unhidden(mockApp),
      ]
      
      #expect(collectedEvents == expectedEvents)
    }
  }

  @Test
  func events_withIsTerminatedChangedToTrue_shouldEmitTerminatedEvent() async throws {
    await withDependencies { deps in
      deps.processInfoClient = .nonXPC
      deps.sysctlClient = .nonZombie
    } operation: {
      let mockApp = AppMock(_isTerminated: false, _isFinishedLaunching: false, _processIdentifier: 0)
      let mockWorkspace = NSWorkspace.Mock()
      mockWorkspace._runningApplications = [mockApp]

      var collectedEvents: [RunningApplicationEvent] = []

      let sut = RunningApplicationWatcher(workspace: mockWorkspace)

      Task {
        for await event in sut.events() {
          collectedEvents.append(event)
        }
      }

      try? await Task.sleep(for: Self.testSleepDuration)
      
      // Verify app is being observed before termination
      #expect(sut.appObservations.keys.contains(mockApp))
      #expect(sut.appObservations[mockApp]?.count == 4)
      
      mockApp._isTerminated = true

      try? await Task.sleep(for: Self.testSleepDuration)
      
      // Verify app observations are cleaned up after termination
      #expect(!sut.appObservations.keys.contains(mockApp))
      #expect(sut.appObservations[mockApp] == nil)
      
      let expectedEvents: [RunningApplicationEvent] = [
        .launched([mockApp]),
        .terminated(mockApp),
      ]
      
      #expect(collectedEvents == expectedEvents)
    }
  }
}
