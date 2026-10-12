import SwiftUI
import StraysCore

struct DashboardView: View {
    var body: some View {
        ContentUnavailableView(
            "Nothing running",
            systemImage: "pawprint",
            description: Text("Strays \(StraysCore.version)")
        )
        .frame(minWidth: 720, minHeight: 460)
    }
}
