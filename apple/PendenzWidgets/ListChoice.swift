import AppIntents
import WidgetKit

// A list as the widget's settings offer it: Reminders, the inbox, everything, or a project.
nonisolated struct ListEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "List" }
    static var defaultQuery: ListQuery { ListQuery() }

    // The name of a `WidgetList`.
    var id: String
    var name: String
    var symbol: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: symbol))
    }

    init(_ list: WidgetList, in snapshot: WidgetSnapshot?) {
        id = list.id
        name = list.title(in: snapshot)
        symbol = list.symbol(in: snapshot)
    }
}

nonisolated struct ListQuery: EntityQuery {
    // A list that is no longer offered keeps its entity: the widget then says that the project
    // is gone, where a missing entity would quietly turn it into another list.
    func entities(for identifiers: [String]) async throws -> [ListEntity] {
        let snapshot = WidgetFile.read()
        return identifiers.compactMap { WidgetList(id: $0) }.map { ListEntity($0, in: snapshot) }
    }

    func suggestedEntities() async throws -> [ListEntity] {
        let snapshot = WidgetFile.read()
        let lists = [WidgetList.reminders, .inbox, .all] + (snapshot?.projects ?? []).map { .project($0.id) }
        return lists.map { ListEntity($0, in: snapshot) }
    }

    func defaultResult() async -> ListEntity? {
        ListEntity(.reminders, in: nil)
    }
}

// The one setting of the widget, reached with "Edit Widget".
struct ListWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "List"
    static var description: IntentDescription? { IntentDescription("Choose the list this widget shows.") }

    @Parameter(title: "List")
    var list: ListEntity?

    init() {}
}
