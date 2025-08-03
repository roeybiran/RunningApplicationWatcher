import AppKit
import ApplicationServices
import Dependencies
import RBKit
import Testing

@testable import RunningApplicationWatcher

// MARK: - RunningApplicationWatcherTests

@Suite("RunningApplicationWatcher", .serialized)
@MainActor
struct RunningApplicationWatcherTests {
  @Suite("NSWorkspace.runningApplications Observation", .serialized)
  @MainActor
  struct RunningApplicationsTests {
    @Test("Should observe correct NSWorkSpace key paths")
    func shouldObserveCorrectNSWorkSpaceKeyPaths() async throws {
      await withDependencies { deps in
        deps.processInfoClient = .nonXPC
        deps.sysctlClient = .nonZombie
      } operation: {
        var observeCalls: [(keyPath: String, options: NSKeyValueObservingOptions)] = []
        let mockWorkspace = NSWorkspace.Mock()
        mockWorkspace._addObserver = { _, keyPath, options, _ in
          observeCalls.append((keyPath: keyPath, options: options))
        }
        let sut = RunningApplicationWatcher(workspace: mockWorkspace)

        Task {
          for await _ in sut.events() { }
        }

        try? await Task.sleep(for: testSleepDuration)

        let expectedCalls = [
          (keyPath: "runningApplications", options: NSKeyValueObservingOptions([.initial, .new])),
          (keyPath: "frontmostApplication", options: NSKeyValueObservingOptions([.initial, .new])),
        ]

        for (i, call) in expectedCalls.enumerated() {
          #expect(call.keyPath == observeCalls[i].keyPath)
          #expect(call.options == observeCalls[i].options)
        }

        #expect(observeCalls.count == 2)
      }
    }

    @Test("Should emit launched event")
    func withRunningApplicationsChanged_shouldEmitLaunchedEvent() async throws {
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

        try? await Task.sleep(for: testSleepDuration)

        #expect(Set(sut.appObservations.keys) == Set(mockApps))
        #expect(sut.appObservations.keys.count == 2)

        for (_, value) in sut.appObservations {
          #expect(value.count == 4)
        }

        let expectedEvents: [RunningApplicationEvent] = [
          .launched(mockApps),
          .activated(mockApp1),
        ]

        #expect(collectedEvents == expectedEvents)
      }
    }

    @Test("Should skip app when first app is current")
    func withFirstAppIsCurrent_shouldSkipApp() async throws {
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
        try? await Task.sleep(for: testSleepDuration)

        #expect(sut.appObservations.keys.count == 1)
        #expect(sut.appObservations[regularApp]?.count == 4)

        let expectedEvents: [RunningApplicationEvent] = [
          .launched([regularApp]),
        ]

        #expect(collectedEvents == expectedEvents)
      }
    }

    @Test("Should skip XPC app and verify endpoints are called")
    func withFirstAppIsXPC_shouldSkipApp() async throws {
      await confirmation("getProcessInformation should be called twice", expectedCount: 2) { confirmGetProcessInfo in
        await confirmation("getProcessForPID should be called twice", expectedCount: 2) { confirmGetProcessForPID in
          await withDependencies { deps in
            deps.processInfoClient = ProcessesClient(
              getProcessInformation: { pid, info in
                confirmGetProcessInfo()
                if pid.pointee.highLongOfPSN == 0 {
                  info.pointee.processType = NSHFSTypeCodeFromFileType("'XPC!'")
                } else {
                  info.pointee.processType = NSHFSTypeCodeFromFileType("'APPL'")
                }
                return .zero
              },
              getProcessForPID: { pid, ptr in
                confirmGetProcessForPID()
                if pid == 0 {
                  ptr.pointee = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: 0)
                } else {
                  ptr.pointee = ProcessSerialNumber(highLongOfPSN: 1, lowLongOfPSN: 1)
                }
                return noErr
              })
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

            try? await Task.sleep(for: testSleepDuration)

            #expect(sut.appObservations.keys.count == 1)
            #expect(sut.appObservations[regularApp]?.count == 4)

            let expectedEvents: [RunningApplicationEvent] = [
              .launched([regularApp]),
            ]

            #expect(collectedEvents == expectedEvents)
          }
        }
      }
    }

    @Test("Should not skip Passwords.app even though it's XPC")
    func withPasswordsAppAsXPC_shouldNotSkipApp() async throws {
      await withDependencies { deps in
        deps.processInfoClient = ProcessesClient(
          getProcessInformation: { _, info in
            // Both apps are XPC processes
            info.pointee.processType = NSHFSTypeCodeFromFileType("'XPC!'")
            return .zero
          },
          getProcessForPID: { pid, ptr in
            if pid == 0 {
              ptr.pointee = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: 0)
            } else {
              ptr.pointee = ProcessSerialNumber(highLongOfPSN: 1, lowLongOfPSN: 1)
            }
            return noErr
          })
        deps.sysctlClient = .nonZombie
      } operation: {
        let passwordsApp = AppMock(_isFinishedLaunching: false, _bundleIdentifier: "com.apple.Passwords", _processIdentifier: 0)
        let regularXPCApp = AppMock(_isFinishedLaunching: false, _bundleIdentifier: "com.example.xpc", _processIdentifier: 1)
        let mockApps = [passwordsApp, regularXPCApp]
        let mockWorkspace = NSWorkspace.Mock()

        var collectedEvents: [RunningApplicationEvent] = []
        let sut = RunningApplicationWatcher(workspace: mockWorkspace)

        Task {
          for await event in sut.events() {
            collectedEvents.append(event)
          }
        }

        mockWorkspace._runningApplications = mockApps

        try? await Task.sleep(for: testSleepDuration)

        // Passwords app should be observed despite being XPC
        #expect(sut.appObservations.keys.contains(passwordsApp))
        #expect(sut.appObservations[passwordsApp]?.count == 4)

        // Regular XPC app should not be observed
        #expect(!sut.appObservations.keys.contains(regularXPCApp))

        let expectedEvents: [RunningApplicationEvent] = [
          .launched([passwordsApp]),
        ]

        #expect(collectedEvents == expectedEvents)
      }
    }

    @Test("Should skip zombie app")
    func withFirstAppIsZombie_shouldSkipApp() async throws {
      await withDependencies { deps in
        deps.processInfoClient = .nonXPC
        deps.sysctlClient = SysctlClient(
          run: { mib, _, oldp, _, _, _ in
            // Mock sysctl behavior: return zombie status based on PID
            if let kinfo = oldp?.assumingMemoryBound(to: kinfo_proc.self) {
              if mib?[3] == 0 { // PID 0 is zombie
                kinfo.pointee.kp_proc.p_stat = CChar(SZOMB)
              } else { // PID 1 is not zombie
                kinfo.pointee.kp_proc.p_stat = CChar(SRUN)
              }
            }
            return 0
          })
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

        try? await Task.sleep(for: testSleepDuration)

        #expect(sut.appObservations.keys.count == 1)
        #expect(sut.appObservations[regularApp]?.count == 4)

        let expectedEvents: [RunningApplicationEvent] = [
          .launched([regularApp]),
        ]

        #expect(collectedEvents == expectedEvents)
      }
    }
  }

  @Suite("NSWorkspace.frontmostApplication Observation", .serialized)
  @MainActor
  struct FrontmostApplicationTests {
    @Test("Should emit activated event when frontmost application changes")
    func withFrontmostApplicationChanged_shouldEmitActivatedEvent() async throws {
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

        try? await Task.sleep(for: testSleepDuration)
        mockWorkspace._frontmostApplication = mockApp2
        try? await Task.sleep(for: testSleepDuration)

        let expectedEvents: [RunningApplicationEvent] = [
          .launched([mockApp, mockApp2]),
          .activated(mockApp),
          .activated(mockApp2),
        ]

        #expect(collectedEvents == expectedEvents)
      }
    }

    @Test("Should not emit activated event when frontmost application is nil")
    func withFrontmostApplicationNil_shouldNotEmitActivatedEvent() async throws {
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

        try? await Task.sleep(for: testSleepDuration)
        mockWorkspace._frontmostApplication = nil
        try? await Task.sleep(for: testSleepDuration)

        let expectedEvents: [RunningApplicationEvent] = [
          .launched([mockApp]),
          .activated(mockApp),
        ]

        #expect(collectedEvents == expectedEvents)
      }
    }

    @Test("Should not emit activated event for non-observed frontmost application")
    func withFrontmostApplicationNotObserved_shouldNotEmitActivatedEvent() async throws {
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
        try? await Task.sleep(for: testSleepDuration)

        let expectedEvents: [RunningApplicationEvent] = [
          .launched([observedApp]),
        ]

        #expect(collectedEvents == expectedEvents)
      }
    }
  }

  @Suite("NSRunningApplication Observations", .serialized)
  @MainActor
  struct NSRunningApplicationObservationsTests {
    @Test("Should emit didFinishedLaunching event when initial isFinishedLaunching is true")
    func withInitialIsFinishedLaunchingTrue_shouldEmitDidFinishedLaunchingEvent() async throws {
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

        try? await Task.sleep(for: testSleepDuration)

        let expectedEvents: [RunningApplicationEvent] = [
          .launched([mockApp]),
          .didFinishedLaunching(mockApp),
        ]

        #expect(collectedEvents == expectedEvents)
      }
    }

    @Test("Should not emit didFinishedLaunching event when initial isFinishedLaunching is false")
    func withInitialIsFinishedLaunchingFalse_shouldNotEmitDidFinishedLaunchingEvent() async throws {
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

        try? await Task.sleep(for: testSleepDuration)

        let expectedEvents: [RunningApplicationEvent] = [
          .launched([mockApp]),
        ]

        #expect(collectedEvents == expectedEvents)
      }
    }

    @Test("Should emit didFinishedLaunching event when isFinishedLaunching changes to true")
    func withIsFinishedLaunchingChangedToTrue_shouldEmitDidFinishedLaunchingEvent() async throws {
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

        try? await Task.sleep(for: testSleepDuration)
        mockApp._isFinishedLaunching = true
        try? await Task.sleep(for: testSleepDuration)

        let expectedEvents: [RunningApplicationEvent] = [
          .launched([mockApp]),
          .didFinishedLaunching(mockApp),
        ]

        #expect(collectedEvents == expectedEvents)
      }
    }

    @Test("Should emit activationPolicyChanged event when activation policy changes")
    func withActivationPolicyChanged_shouldEmitActivationPolicyChangedEvent() async throws {
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

        try? await Task.sleep(for: testSleepDuration)
        mockApp._activationPolicy = .regular
        try? await Task.sleep(for: testSleepDuration)

        let expectedEvents: [RunningApplicationEvent] = [
          .launched([mockApp]),
          .activationPolicyChanged(mockApp),
        ]

        #expect(collectedEvents == expectedEvents)
      }
    }

    @Test("Should emit hidden event when isHidden changes to true")
    func withIsHiddenChangedToTrue_shouldEmitHiddenEvent() async throws {
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

        try? await Task.sleep(for: testSleepDuration)
        mockApp._isHidden = true
        try? await Task.sleep(for: testSleepDuration)

        let expectedEvents: [RunningApplicationEvent] = [
          .launched([mockApp]),
          .hidden(mockApp),
        ]

        #expect(collectedEvents == expectedEvents)
      }
    }

    @Test("Should emit unhidden event when isHidden changes to false")
    func withIsHiddenChangedToFalse_shouldEmitUnhiddenEvent() async throws {
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

        try? await Task.sleep(for: testSleepDuration)
        mockApp._isHidden = false
        try? await Task.sleep(for: testSleepDuration)

        let expectedEvents: [RunningApplicationEvent] = [
          .launched([mockApp]),
          .unhidden(mockApp),
        ]

        #expect(collectedEvents == expectedEvents)
      }
    }

    @Test("Should emit terminated event when isTerminated changes to true")
    func withIsTerminatedChangedToTrue_shouldEmitTerminatedEvent() async throws {
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

        try? await Task.sleep(for: testSleepDuration)

        // Verify app is being observed before termination
        #expect(sut.appObservations.keys.contains(mockApp))
        #expect(sut.appObservations[mockApp]?.count == 4)

        mockApp._isTerminated = true

        try? await Task.sleep(for: testSleepDuration)

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
}

private let testSleepDuration = Duration.seconds(0.02)
