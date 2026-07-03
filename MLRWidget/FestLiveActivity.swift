import ActivityKit
import WidgetKit
import SwiftUI

// MARK: - Family Fest Live Activity UI
//
// Lives in the widget extension. Renders the Lock Screen banner + Dynamic Island
// presentations. The app drives the content via `FestLiveActivityController`.
// iOS 26: Live Activity surfaces inherit Liquid Glass automatically; we provide
// the content layout and let the system supply the material.

struct FestLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FestActivityAttributes.self) { context in
            // MARK: Lock Screen / banner presentation
            LockScreenFestView(context: context)
                .activityBackgroundTint(Color.mlrFest.opacity(0.12))
                .activitySystemActionForegroundColor(Color.mlrFest)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.emoji + " Fest")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                        Text(context.state.phaseLabel)
                            .font(.headline)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Next")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(context.state.nextEventTime)
                            .font(.headline)
                            .monospacedDigit()
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 6) {
                        Text(context.state.emoji)
                        VStack(alignment: .leading) {
                            Text(context.state.nextEventTitle)
                                .font(.subheadline.weight(.semibold))
                            if let loc = context.state.nextEventLocation {
                                Text(loc)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                }
            } compactLeading: {
                Text(context.state.emoji)
            } compactTrailing: {
                Text("D\(context.state.dayNumber)")
                    .font(.caption2.bold())
                    .foregroundStyle(Color.mlrFest)
            } minimal: {
                Text(context.state.emoji)
            }
            .widgetURL(URL(string: "mlr://family-fest"))
            .keylineTint(Color.mlrFest)
        }
    }
}

// MARK: - Lock Screen view

private struct LockScreenFestView: View {
    let context: ActivityViewContext<FestActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("🌲 Family Fest \(String(context.attributes.festYear))")
                        .font(.caption.bold())
                        .foregroundStyle(Color.mlrFest)
                    PulsingLiveDot(color: .mlrFest)
                }
                Text(context.state.phaseLabel)
                    .font(.title3.bold())
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("Up next")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(context.state.emoji) \(context.state.nextEventTitle)")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(context.state.nextEventTime)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding()
    }
}

// MARK: - Help Request Live Activity UI
//
// Shows the member's own active "Ask for Help" request with a live responder
// count ("2/3 on the way") until it's covered/closed. Driven by
// `HelpLiveActivityController`.

struct HelpLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HelpActivityAttributes.self) { context in
            LockScreenHelpView(context: context)
                .activityBackgroundTint(Color.mlrPrimary.opacity(0.12))
                .activitySystemActionForegroundColor(Color.mlrPrimary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.categoryEmoji + " Help")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                        Text(context.attributes.what)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(context.state.fulfilled ? "Covered" : "On the way")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(context.state.respondersCount)/\(context.state.neededCount)")
                            .font(.headline)
                            .monospacedDigit()
                            .foregroundStyle(context.state.fulfilled ? Color.mlrSuccess : Color.mlrPrimary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let w = context.state.whereText, !w.isEmpty {
                        Label(w, systemImage: "mappin.and.ellipse")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Text(context.attributes.categoryEmoji)
            } compactTrailing: {
                Text("\(context.state.respondersCount)/\(context.state.neededCount)")
                    .font(.caption2.bold())
                    .monospacedDigit()
                    .foregroundStyle(context.state.fulfilled ? Color.mlrSuccess : Color.mlrPrimary)
            } minimal: {
                Text(context.attributes.categoryEmoji)
            }
            .widgetURL(URL(string: "mlr://ask-for-help"))
            .keylineTint(Color.mlrPrimary)
        }
    }
}

private struct LockScreenHelpView: View {
    let context: ActivityViewContext<HelpActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("\(context.attributes.categoryEmoji) Help needed")
                        .font(.caption.bold())
                        .foregroundStyle(Color.mlrPrimary)
                    PulsingLiveDot(color: .mlrPrimary)
                }
                Text(context.attributes.what)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let w = context.state.whereText, !w.isEmpty {
                    Text(w)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(context.state.fulfilled ? "✅ Covered" : "On the way")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(context.state.respondersCount)/\(context.state.neededCount)")
                    .font(.title3.bold())
                    .monospacedDigit()
                    .foregroundStyle(context.state.fulfilled ? Color.mlrSuccess : Color.mlrPrimary)
            }
        }
        .padding()
    }
}
