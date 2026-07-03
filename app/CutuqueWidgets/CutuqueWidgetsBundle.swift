import SwiftUI
import WidgetKit

/// Ponto de entrada da widget extension. Por ora só a Live Activity de sessão
/// (o app não tem widgets de home screen ainda).
@main
struct CutuqueWidgetsBundle: WidgetBundle {
    var body: some Widget {
        SessionLiveActivity()
    }
}
