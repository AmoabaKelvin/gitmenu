import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            switch model.auth {
            case .signedIn:
                if let t = model.selected {
                    ThreadDetailView(thread: t)
                        .transition(.move(edge: .trailing))
                } else {
                    InboxView()
                }
            default:
                SignInView()
            }
        }
        .frame(width: 400, height: 560)
        .animation(.easeOut(duration: 0.18), value: model.selected?.id)
    }
}
