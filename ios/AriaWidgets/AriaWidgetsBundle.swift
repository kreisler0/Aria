import SwiftUI
import WidgetKit

@main
struct AriaWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TaskWidget()
        CalendarWidget()
        QuickAddWidget()
        AriaLiveActivity()
    }
}
