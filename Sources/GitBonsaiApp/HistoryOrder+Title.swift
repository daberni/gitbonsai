import Foundation
import GitEngine

extension HistoryOrder {
    /// The name in the settings and the history's column menu.
    var title: LocalizedStringResource {
        switch self {
        case .date: LocalizedStringResource("history.order.date", defaultValue: "Date", bundle: .module, comment: "History order: newest commit date first across branches.")
        case .authorDate: LocalizedStringResource("history.order.authorDate", defaultValue: "Author date", bundle: .module, comment: "History order: newest author date first across branches.")
        case .branchesTogether: LocalizedStringResource("history.order.branchesTogether", defaultValue: "Branches together", bundle: .module, comment: "History order: each branch's commits kept in one run.")
        }
    }
}
