import SwiftData
import SwiftUI

struct RootView: View {
    var body: some View {
        DealerListView()
    }
}

#Preview {
    RootView()
        .environment(AppModel())
        .modelContainer(.preview)
}
