import Foundation

/// 10d: 撤销 on a save card, said in a toast either way.
extension AppState {
    func undoChange(_ id: UUID, message: UUID, call: String) {
        if let problem = chat.undoChange(id, message: message, call: call) {
            toasts.show("没有撤销", note: problem, isError: true, seconds: 4)
        } else {
            toasts.show("已撤销", note: "文件回到了这次修改之前的样子", seconds: 2)
        }
    }
}
