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

/// Snapshot of the next upcoming house-calendar stay for the "Next Visit" widget.
struct VisitSnapshot: Codable {
    let who: String
    let dateLabel: String   // e.g. "Jul 18 – 20"
    let house: String?
}

/// The fest week resolved from `fest_config`, cached so the widget and the Siri
/// intents — which run in separate processes and can't await a Supabase fetch —
/// read the same window the app does.
///
/// ⚠️ The in-code constants in `FamilyFestConfig` are a FALLBACK ONLY. They were
/// the source of truth once and they went stale: they said 2026-07-27 → 07-31
/// while the database said 2026-07-26 → 08-01, so during the actual week the app
/// showed "Day n of 5" instead of "of 7", and on the real final day it had
/// already flipped to "wrap". Whatever writes this snapshot is the truth.
struct FestWindowSnapshot: Codable {
    let year: Int
    let startDate: String   // ISO yyyy-MM-dd
    let endDate: String     // ISO yyyy-MM-dd
    let name: String?
    let tagline: String?
    let theme: String?
    let coverUrl: String?
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
        static let nextVisit = "shared.nextVisit"
        static let festWindow = "shared.festWindow"
    }

    // MARK: Resolved fest week (app → widget / Siri intents)

    var festWindow: FestWindowSnapshot? {
        get {
            guard let data = defaults.data(forKey: Key.festWindow) else { return nil }
            return try? JSONDecoder().decode(FestWindowSnapshot.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.festWindow)
            } else {
                defaults.removeObject(forKey: Key.festWindow)
            }
        }
    }

    // MARK: Next visit up north (for NextVisitWidget)

    var nextVisit: VisitSnapshot? {
        get {
            guard let data = defaults.data(forKey: Key.nextVisit) else { return nil }
            return try? JSONDecoder().decode(VisitSnapshot.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.nextVisit)
            } else {
                defaults.removeObject(forKey: Key.nextVisit)
            }
        }
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
