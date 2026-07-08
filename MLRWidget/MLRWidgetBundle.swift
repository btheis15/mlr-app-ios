//
//  MLRWidgetBundle.swift
//  MLRWidget
//
//  Created by Brian Theis on 7/1/26.
//

import WidgetKit
import SwiftUI

@main
struct MLRWidgetBundle: WidgetBundle {
    var body: some Widget {
        NextEventWidget()
        FamilyFestCountdownWidget()
        ThingsToDoWidget()
        NextVisitWidget()
        AddWorkItemControl()
        FestLiveActivity()
        HelpLiveActivity()
    }
}
