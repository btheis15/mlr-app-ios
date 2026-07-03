//
//  MLRWidgetLiveActivity.swift
//  MLRWidget
//
//  Created by Brian Theis on 7/1/26.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct MLRWidgetAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Dynamic stateful properties about your activity go here!
        var emoji: String
    }

    // Fixed non-changing properties about your activity go here!
    var name: String
}

struct MLRWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MLRWidgetAttributes.self) { context in
            // Lock screen/banner UI goes here
            VStack {
                Text("Hello \(context.state.emoji)")
            }
            .activityBackgroundTint(Color.cyan)
            .activitySystemActionForegroundColor(Color.black)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI goes here.  Compose the expanded UI through
                // various regions, like leading/trailing/center/bottom
                DynamicIslandExpandedRegion(.leading) {
                    Text("Leading")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("Trailing")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Bottom \(context.state.emoji)")
                    // more content
                }
            } compactLeading: {
                Text("L")
            } compactTrailing: {
                Text("T \(context.state.emoji)")
            } minimal: {
                Text(context.state.emoji)
            }
            .widgetURL(URL(string: "http://www.apple.com"))
            .keylineTint(Color.red)
        }
    }
}

extension MLRWidgetAttributes {
    fileprivate static var preview: MLRWidgetAttributes {
        MLRWidgetAttributes(name: "World")
    }
}

extension MLRWidgetAttributes.ContentState {
    fileprivate static var smiley: MLRWidgetAttributes.ContentState {
        MLRWidgetAttributes.ContentState(emoji: "😀")
     }
     
     fileprivate static var starEyes: MLRWidgetAttributes.ContentState {
         MLRWidgetAttributes.ContentState(emoji: "🤩")
     }
}

#Preview("Notification", as: .content, using: MLRWidgetAttributes.preview) {
   MLRWidgetLiveActivity()
} contentStates: {
    MLRWidgetAttributes.ContentState.smiley
    MLRWidgetAttributes.ContentState.starEyes
}
