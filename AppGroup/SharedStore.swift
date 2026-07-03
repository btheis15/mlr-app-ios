import Foundation

// MARK: - Shared Store (App Group)
//
// SHARED FILE — add to BOTH the app target and the MLRWidget extension target.
//
// A tiny snapshot the app writes and the widgets/intents read, via the App Group
// suite so it crosses the process boundary. Configure the App Group capability on
// both targets with the same id: "group.com.muskellungelakeresort.mlr".

struct EventSnapshot: Codable {
    let title: String
    let startDate: String   // ISO yyyy-MM-dd
    let emoji: String
    let location: String?
}

/// Snapshot of the work checklist for the "Things to do" widget.
struct TodoSnapshot: Codable {
    let openCount: Int
    let titles: [String]   // a few top open items to preview
}

final class SharedStore {
    static let shared = SharedStore()

    static let appGroupId = "group.com.muskellungelakeresort.mlr"

    private let defaults: UserDefaults

    private init() {
        defaults = UserDefaults(suiteName: SharedStore.appGroupId) ?? .standard
    }

    private enum Key {
        static let nextEvent = "shared.nextEvent"
        static let memberName = "shared.memberName"
        static let todo = "shared.todo"
        static let pendingRoute = "shared.pendingRoute"
    }

    // MARK: Pending route (Control Center / extensions → app)
    //
    // Control Center controls can't reach the app's in-process IntentRouter, so a
    // control intent stashes a route key here and opens the app; RootView reads and
    // clears it when it next becomes active. Values match IntentRouter hosts
    // (e.g. "add-work-item").

    var pendingRoute: String? {
        get { defaults.string(forKey: Key.pendingRoute) }
        set {
            if let newValue { defaults.set(newValue, forKey: Key.pendingRoute) }
            else { defaults.removeObject(forKey: Key.pendingRoute) }
        }
    }

    // MARK: Work checklist (for the Things-to-do widget)

    var todo: TodoSnapshot? {
        get {
            guard let data = defaults.data(forKey: Key.todo) else { return nil }
            return try? JSONDecoder().decode(TodoSnapshot.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.todo)
            } else {
                defaults.removeObject(forKey: Key.todo)
            }
        }
    }

    // MARK: Next event (for NextEventWidget + Siri intents)

    var nextEvent: EventSnapshot? {
        get {
            guard let data = defaults.data(forKey: Key.nextEvent) else { return nil }
            return try? JSONDecoder().decode(EventSnapshot.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.nextEvent)
            } else {
                defaults.removeObject(forKey: Key.nextEvent)
            }
        }
    }

    // MARK: Member first name (for personalized Siri responses)

    var memberFirstName: String? {
        get { defaults.string(forKey: Key.memberName) }
        set { defaults.set(newValue, forKey: Key.memberName) }
    }

    /// Trigger a widget timeline reload after writing. Call from the app.
    func reloadWidgets() {
        #if canImport(WidgetKit)
        WidgetCenterReloader.reloadAll()
        #endif
    }
}

#if canImport(WidgetKit)
import WidgetKit
enum WidgetCenterReloader {
    static func reloadAll() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
#endif
