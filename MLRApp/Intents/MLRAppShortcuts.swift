import AppIntents

// MARK: - App Shortcuts (Siri)
//
// Registers the app's intents with Siri + Spotlight + the Shortcuts app, with
// spoken trigger phrases. "${applicationName}" expands to the app's name so users
// can say "What's next at MLR" etc. No setup needed by the user — these appear
// automatically once the app is installed.

struct MLRAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NextEventIntent(),
            phrases: [
                "What's next at \(.applicationName)",
                "What's happening at the resort in \(.applicationName)",
                "Next event in \(.applicationName)"
            ],
            shortTitle: "Next Event",
            systemImageName: "calendar"
        )
        AppShortcut(
            intent: FestCountdownIntent(),
            phrases: [
                "How many days until Family Fest in \(.applicationName)",
                "Family Fest countdown in \(.applicationName)",
                "When is Family Fest in \(.applicationName)"
            ],
            shortTitle: "Fest Countdown",
            systemImageName: "tree"
        )
        AppShortcut(
            intent: AskForHelpIntent(),
            phrases: [
                "Ask for help in \(.applicationName)",
                "I need a hand in \(.applicationName)"
            ],
            shortTitle: "Ask for Help",
            systemImageName: "hand.raised"
        )
        AppShortcut(
            intent: AddWorkItemIntent(),
            phrases: [
                "Add a work item in \(.applicationName)",
                "Add a task in \(.applicationName)",
                "Add a work item to \(.applicationName)"
            ],
            shortTitle: "Add Work Item",
            systemImageName: "checklist"
        )
        AppShortcut(
            intent: OpenAddWorkItemIntent(),
            phrases: [
                "Open the work item form in \(.applicationName)",
                "New work item form in \(.applicationName)"
            ],
            shortTitle: "Work Item Form",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: ShowWorkItemsIntent(),
            phrases: [
                "Show my work items in \(.applicationName)",
                "What's on the work checklist in \(.applicationName)"
            ],
            shortTitle: "Work Items",
            systemImageName: "checklist"
        )
        AppShortcut(
            intent: ShowUpcomingEventsIntent(),
            phrases: [
                "Show upcoming events in \(.applicationName)",
                "What's coming up at the resort in \(.applicationName)"
            ],
            shortTitle: "Upcoming Events",
            systemImageName: "calendar"
        )
        AppShortcut(
            intent: WhosGoingIntent(),
            phrases: [
                "Who's going in \(.applicationName)",
                "Who's coming to the event in \(.applicationName)"
            ],
            shortTitle: "Who's Going",
            systemImageName: "person.2"
        )
        AppShortcut(
            intent: OpenCommitteeChatIntent(),
            phrases: [
                "Open a committee chat in \(.applicationName)",
                "Message a committee in \(.applicationName)"
            ],
            shortTitle: "Committee Chat",
            systemImageName: "bubble.left.and.bubble.right"
        )
        AppShortcut(
            intent: OpenHouseChatIntent(),
            phrases: [
                "Open my house chat in \(.applicationName)",
                "Message my house in \(.applicationName)"
            ],
            shortTitle: "House Chat",
            systemImageName: "house"
        )
    }
}
