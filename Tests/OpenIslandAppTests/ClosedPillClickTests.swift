import FocusCore
import Foundation
import Testing
@testable import OpenIslandApp

@MainActor
struct ClosedPillClickTests {
    @Test
    func clickOnEmptyBoardHintOpensTheIslandAndNotTheBoard() {
        let model = AppModel(focusStore: try! FocusStore.inMemory(), claudeRegistry: .temporaryForTesting())
        model.notchStatus = .closed
        #expect(model.focus.hasPickableTasks == false)

        var boardOpened = false
        let observer = NotificationCenter.default.addObserver(forName: .focusOpenBoard, object: nil, queue: nil) { _ in
            boardOpened = true
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        model.openIslandFromClosedPillClick()

        #expect(model.notchStatus == .opened)
        #expect(model.notchOpenReason == .click)
        #expect(boardOpened == false)
    }

    @Test
    func clickOnTaskWithoutTimerOpensTheIslandWithoutStartingFocus() throws {
        let model = AppModel(focusStore: try! FocusStore.inMemory(), claudeRegistry: .temporaryForTesting())
        model.focus.createTask(title: "A", column: .inProgress, projectPath: nil)
        let taskID = try #require(model.focus.board.tasks.first?.id)
        model.focus.startTask(taskID: taskID, sessionIDs: [], focusMinutes: nil)
        model.notchStatus = .closed
        #expect(model.focus.pomodoro == nil)

        model.openIslandFromClosedPillClick()

        #expect(model.notchStatus == .opened)
        #expect(model.focus.pomodoro == nil)
    }

    @Test
    func clickWithTasksOpensTheHubInsteadOfThePickerCard() {
        let model = AppModel(focusStore: try! FocusStore.inMemory(), claudeRegistry: .temporaryForTesting())
        model.focus.createTask(title: "A", column: .todo, projectPath: nil)
        model.notchStatus = .closed
        #expect(model.focus.hasPickableTasks)

        model.openIslandFromClosedPillClick()

        #expect(model.notchStatus == .opened)
        #expect(model.focus.card == nil)
    }
}
