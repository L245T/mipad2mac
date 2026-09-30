import Testing
@testable import MiPadCore
struct TargetDisplaySelectionTests {
    @Test func manualChoiceSurvivesPenReconnectAndDisplayOrderChanges() {
        var state = TargetDisplaySelection()
        state.choose(7)
        state.refresh(available: [4,7,1]); state.refresh(available: [1,7,4])
        #expect(state.isManual && state.displayID == 7)
        var connection = TabletConnection()
        #expect(connection.observe(penReady: true, displayIDs: [4]) == 4)
        #expect(state.isManual && state.displayID == 7)
        connection.disconnected()
        #expect(connection.observe(penReady: true, displayIDs: [4]) == 4)
        #expect(state.isManual && state.displayID == 7)
    }
    @Test func disappearanceClearsStaleChoiceAndChoosingPlaceholderBlocksAutoselection() {
        var state = TargetDisplaySelection()
        state.choose(7); state.refresh(available: [1,4])
        #expect(!state.isManual && state.displayID == nil)
        state.choose(nil); state.refresh(available: [1,4])
        #expect(state.isManual && state.displayID == nil)
        #expect(!TargetDisplaySelection().isManual)
    }
}
