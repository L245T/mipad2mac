import Testing
@testable import MiPadCore
struct TabletConnectionTests {
    @Test func eitherArrivalOrderAndDuplicateEvents() {
        var state = TabletConnection()
        #expect(state.observe(penReady: false, displayIDs: [4]) == nil)
        #expect(state.observe(penReady: true, displayIDs: [4]) == 4)
        #expect(state.observe(penReady: true, displayIDs: [4]) == nil)
        state.disconnected()
        #expect(state.observe(penReady: true, displayIDs: []) == nil)
        #expect(state.observe(penReady: true, displayIDs: [4]) == 4)
    }
    @Test func requiresUnambiguousPairAndRearmsAfterRemoval() {
        var state = TabletConnection()
        #expect(state.observe(penReady: true, displayIDs: [4,5]) == nil)
        #expect(state.observe(penReady: true, displayIDs: [4]) == 4)
        #expect(state.observe(penReady: false, displayIDs: [4]) == nil)
        #expect(state.observe(penReady: true, displayIDs: [4]) == 4)
        #expect(state.observe(penReady: true, displayIDs: []) == nil)
        #expect(state.observe(penReady: true, displayIDs: [5]) == 5)
    }
    @Test func manualPauseLastsUntilNextConnection() {
        var pair = TabletConnection(); var control = AutomaticControl()
        _ = pair.observe(penReady: true, displayIDs: [4]); control.pause()
        if pair.observe(penReady: true, displayIDs: [4]) != nil { control.request() }
        #expect(control.next(permissions: true, target: true, pen: true) == .wait)
        pair.disconnected()
        if pair.observe(penReady: true, displayIDs: [4]) != nil { control.request() }
        #expect(control.next(permissions: true, target: true, pen: true) == .enable)
    }
}
