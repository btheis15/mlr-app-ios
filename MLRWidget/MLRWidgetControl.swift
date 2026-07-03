//
//  MLRWidgetControl.swift
//  MLRWidget
//
//  A Control Center / Lock Screen / Action button control that jumps straight
//  into adding a resort work item. Controls can't reach the app's in-process
//  router, so the intent stashes a route in the App Group and opens the app;
//  RootView drains it on activation and shows the add-work-item composer.
//

import AppIntents
import SwiftUI
import WidgetKit

struct AddWorkItemControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: "com.muskellungelakeresort.mlr.AddWorkItem"
        ) {
            ControlWidgetButton(action: QuickAddWorkItemControlIntent()) {
                Label("Add Work Item", systemImage: "checklist")
            }
        }
        .displayName("Add Work Item")
        .description("Quickly add a task to the MLR work checklist.")
    }
}

struct QuickAddWorkItemControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Work Item"
    static let description = IntentDescription("Opens MLR to add a work item.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        SharedStore.shared.pendingRoute = "add-work-item"
        return .result()
    }
}
