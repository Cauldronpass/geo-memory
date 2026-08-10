// DayflowWidgetBundle.swift — paste over the Xcode-generated bundle file in
// the new DayflowWidget extension target.

import WidgetKit
import SwiftUI

@main
struct DayflowWidgetBundle: WidgetBundle {
    var body: some Widget {
        DayflowWidget()
        // Session 68. A second widget in the same bundle rather than a fifth app
        // — see the header of `DayflowLauncherWidget.swift` for why a wrapper app
        // could not have worked.
        DayflowLauncherWidget()
    }
}
