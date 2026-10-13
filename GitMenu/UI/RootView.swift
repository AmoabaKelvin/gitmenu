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
                } else if let w = model.selectedWork {
                    ThreadDetailView(thread: model.workThread(w), work: w)
                        .transition(.move(edge: .trailing))
                } else {
                    InboxView()
                }
            default:
                SignInView()
            }
        }
        .frame(width: 400, height: 560)
        .environmentObject(model.prefs)
        .animation(.easeOut(duration: 0.18), value: model.selected?.id)
        .animation(.easeOut(duration: 0.18), value: model.selectedWork?.id)
    }
}
