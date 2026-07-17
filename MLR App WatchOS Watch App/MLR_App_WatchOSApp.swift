//
//  MLR_App_WatchOSApp.swift
//  MLR App WatchOS Watch App
//

import SwiftUI

@main
struct MLR_App_WatchOS_Watch_AppApp: App {
    // Receives the Supabase session pushed from the paired iPhone and applies it
    // so the watch can make authenticated queries. Shared into the environment
    // for the data screens (chats / fest / work) to gate on `isAuthed`.
    @State private var session = WatchSessionReceiver.shared
    @State private var router = WatchRouter.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(session)
                .environment(router)
                .task {
                    session.activate()
                    // Route taps on forwarded notifications into the watch app.
                    WatchNotificationController.shared.activate()
                }
        }
    }
}
