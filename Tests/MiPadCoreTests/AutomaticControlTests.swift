import Testing
@testable import MiPadCore

struct AutomaticControlTests {
    @Test func mappingRetryPreservesRequestedMode() {
        var state = AutomaticControl()
        #expect(state.next(permissions: true, target: true, pen: true) == .enable)
        #expect(state.requested && !state.pending)
        state.retryIfRequested()
        #expect(state.next(permissions: true, target: false, pen: true) == .wait)
        #expect(state.requested)
        #expect(state.next(permissions: true, target: true, pen: true) == .enable)
        state.pause()
        state.retryIfRequested()
        #expect(!state.requested && !state.pending)
        #expect(state.next(permissions: true, target: true, pen: true) == .wait)
    }
    @Test func failedAttemptDoesNotChangeModeOrLoop() {
        var state = AutomaticControl()
        #expect(state.next(permissions: true, target: true, pen: true) == .enable)
        #expect(state.requested)
        #expect(state.next(permissions: true, target: true, pen: true) == .wait)
    }
    @Test func permissionCompletionEnablesOnceWithoutReports() {
        var state = AutomaticControl()
        #expect(state.next(permissions: false, target: true, pen: true) == .requestPermissions)
        #expect(state.next(permissions: false, target: true, pen: true) == .wait)
        #expect(state.next(permissions: true, target: true, pen: true) == .enable)
        #expect(state.next(permissions: true, target: true, pen: true) == .wait)
    }
    @Test func waitsForDeviceAndDisplayAndHonorsPause() {
        var state = AutomaticControl()
        #expect(state.next(permissions: true, target: false, pen: true) == .wait)
        #expect(state.next(permissions: true, target: true, pen: false) == .wait)
        state.pause()
        #expect(state.next(permissions: true, target: true, pen: true) == .wait)
        state.request()
        #expect(state.next(permissions: true, target: true, pen: true) == .enable)
    }
}
