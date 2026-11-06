import MWDATCore
import SwiftUI

@main
struct CoinSpotterApp: App {
  @State private var model: SpotterModel
  @Environment(\.scenePhase) private var scenePhase

  init() {
    do {
      try Wearables.configure()
    } catch {
      NSLog("[CoinSpotter] Could not configure the Meta Wearables SDK: \(error)")
    }
    _model = State(wrappedValue: SpotterModel(wearables: Wearables.shared))
  }

  var body: some Scene {
    WindowGroup {
      ContentView(model: model)
        .onOpenURL { model.handleCallback($0) }
        .alert("Something went wrong", isPresented: $model.showError) {
          Button("OK") {}
        } message: {
          Text(model.errorMessage)
        }
    }
    .onChange(of: scenePhase) { _, phase in
      model.setOnScreen(phase == .active)
    }
  }
}
