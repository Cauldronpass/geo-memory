// JotWidgetBundle.swift — paste over the Xcode-generated bundle file in the
// new JotWidget extension target (same file, Xcode names it after the
// product, e.g. "JotWidgetBundle.swift" or folded into the single
// auto-generated "JotWidget.swift" depending on Xcode version — if Xcode
// only generated one file, split it into this file + JotWidget.swift below).

import WidgetKit
import SwiftUI

@main
struct JotWidgetBundle: WidgetBundle {
    var body: some Widget {
        JotWidget()
    }
}
