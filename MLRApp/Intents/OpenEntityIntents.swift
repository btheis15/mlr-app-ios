import AppIntents

// MARK: - Open-entity intents — `.system.open` assistant schema (Siri / Apple Intelligence)
//
// Conform the app's core entities to Apple's `.system.open` schema so requests
// like "open the Meals committee" or "open the 4th of July" resolve the entity
// (via its EntityStringQuery) and navigate there — no shortcut needed. Each
// intent hands an `mlr://` route to `IntentRouter`, reusing the app's existing
// deep-link navigation. `.system.open` is iOS 27+, matching the search schema;
// the deployment target stays at iOS 26.

@available(iOS 27.0, *)
@AppIntent(schema: .system.open)
struct OpenEventIntent: OpenIntent {
    static var title: LocalizedStringResource = "Open Event"

    @Dependency private var router: IntentRouter

    var target: EventEntity

    func perform() async throws -> some IntentResult {
        await router.requestRoute(.events)
        return .result()
    }
}

@available(iOS 27.0, *)
@AppIntent(schema: .system.open)
struct OpenCommitteeIntent: OpenIntent {
    static var title: LocalizedStringResource = "Open Committee"

    @Dependency private var router: IntentRouter

    var target: CommitteeEntity

    func perform() async throws -> some IntentResult {
        await router.requestRoute(.committeeChat(slug: target.id))
        return .result()
    }
}

@available(iOS 27.0, *)
@AppIntent(schema: .system.open)
struct OpenMemberIntent: OpenIntent {
    static var title: LocalizedStringResource = "Open Person"

    @Dependency private var router: IntentRouter

    var target: MemberEntity

    func perform() async throws -> some IntentResult {
        // People resolve to the Home tab (the People directory lives there);
        // mirrors the Spotlight `mlr://people` routing.
        await router.requestRoute(.home)
        return .result()
    }
}

@available(iOS 27.0, *)
@AppIntent(schema: .system.open)
struct OpenWorkItemIntent: OpenIntent {
    static var title: LocalizedStringResource = "Open Work Item"

    @Dependency private var router: IntentRouter

    var target: WorkItemEntity

    func perform() async throws -> some IntentResult {
        // Work items resolve to the Home tab (the Work Checklist lives there);
        // mirrors the Spotlight `mlr://work` routing.
        await router.requestRoute(.home)
        return .result()
    }
}
