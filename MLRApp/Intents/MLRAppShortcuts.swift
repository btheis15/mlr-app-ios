import AppIntents

// MARK: - App Shortcuts (Siri)
//
// Registers the app's top intents with Siri + Spotlight + the Shortcuts app, with
// spoken trigger phrases. "${applicationName}" expands to the app's name. Apple
// caps this at 10 App Shortcuts, so this is a curated set of the most-asked
// questions — the resort's "Up North" vernacular is woven into the phrases, and
// several accept a spoken parameter (a day, a period, a member's name). Every
// other intent/entity in the app is still usable in the Shortcuts app and by
// Apple Intelligence via the Spotlight semantic index.

struct MLRAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NextEventIntent(),
            phrases: [
                "What's next in \(.applicationName)",
                "What's next up north in \(.applicationName)",
                "Next event in \(.applicationName)",
            ],
            shortTitle: "Next Event",
            systemImageName: "calendar"
        )
        AppShortcut(
            intent: EventsForPeriodIntent(),
            phrases: [
                "What events are happening \(\.$period) in \(.applicationName)",
                "What's going on \(\.$period) up north in \(.applicationName)",
                "What are the events \(\.$period) in \(.applicationName)",
            ],
            shortTitle: "Events",
            systemImageName: "calendar.badge.clock"
        )
        AppShortcut(
            intent: NextVisitUpNorthIntent(),
            phrases: [
                "When's the next time someone's going up north in \(.applicationName)",
                "Who's going up north next in \(.applicationName)",
                "Next visit up north in \(.applicationName)",
            ],
            shortTitle: "Next Visit Up North",
            systemImageName: "house"
        )
        AppShortcut(
            intent: DinnerForDayIntent(),
            phrases: [
                "Who's making dinner on \(\.$day) in \(.applicationName)",
                "Who's responsible for dinner on \(\.$day) in \(.applicationName)",
                "Who's making dinner in \(.applicationName)",
            ],
            shortTitle: "Who's Making Dinner",
            systemImageName: "fork.knife"
        )
        AppShortcut(
            intent: SearchUpNorthIntent(),
            phrases: [
                "Search Up North in \(.applicationName)",
                "Search \(.applicationName)",
                "Search the resort in \(.applicationName)",
            ],
            shortTitle: "Search Up North",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: FestCountdownIntent(),
            phrases: [
                "How many days until Family Fest in \(.applicationName)",
                "Family Fest countdown in \(.applicationName)",
                "When is Family Fest in \(.applicationName)",
            ],
            shortTitle: "Fest Countdown",
            systemImageName: "tree"
        )
        AppShortcut(
            intent: ThingsToDoUpNorthIntent(),
            phrases: [
                "What do we have to get done up north in \(.applicationName)",
                "What are some things to do up north in \(.applicationName)",
                "What's on the work list in \(.applicationName)",
            ],
            shortTitle: "Things To Do",
            systemImageName: "checklist"
        )
        AppShortcut(
            intent: BirthdayIntent(),
            phrases: [
                "When is \(\.$member)'s birthday in \(.applicationName)",
                "\(\.$member)'s birthday in \(.applicationName)",
                "Look up a birthday in \(.applicationName)",
            ],
            shortTitle: "Birthday",
            systemImageName: "birthday.cake"
        )
        AppShortcut(
            intent: AddWorkItemIntent(),
            phrases: [
                "Add a work item in \(.applicationName)",
                "Add a task up north in \(.applicationName)",
                "Add something to the work list in \(.applicationName)",
            ],
            shortTitle: "Add Work Item",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: AskForHelpIntent(),
            phrases: [
                "Ask for help in \(.applicationName)",
                "I need a hand up north in \(.applicationName)",
            ],
            shortTitle: "Ask for Help",
            systemImageName: "hand.raised"
        )
    }
}
