import SwiftUI

/// Launch flow while no project is open; the main view otherwise. Removing the last project from
/// Manage Projects returns here to the launch flow.
struct AppRootView: View {
    let state: AppState
    let session: ProjectSession
    let remembersWindowFrame: Bool

    @State private var mode: WindowShaper.Mode

    init(state: AppState, session: ProjectSession, initialMode: WindowShaper.Mode, remembersWindowFrame: Bool) {
        self.state = state
        self.session = session
        self.remembersWindowFrame = remembersWindowFrame
        _mode = State(initialValue: initialMode)
    }

    var body: some View {
        Group {
            switch mode {
            case .launch:
                LaunchFlowView(state: state, session: session) { mode = .main }
            case .main:
                RootView(state: state, session: session)
            }
        }
        .background(WindowShaper(mode: mode, remembersFrame: remembersWindowFrame))
        .onChange(of: session.current?.id) { _, id in
            if id == nil {
                state.projectMenu = nil
                state.isManagingProjects = false
                mode = .launch
            }
        }
        .preferredColorScheme(.dark)
    }
}
