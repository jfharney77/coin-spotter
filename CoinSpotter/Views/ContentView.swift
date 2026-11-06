import SwiftUI

struct ContentView: View {
  @Bindable var model: SpotterModel
  @State private var showSettings = false

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          if model.isRegistered {
            spotter
          } else {
            connect
          }
        }
        .padding()
      }
      .navigationTitle("Coin Spotter")
      .toolbar {
        Button("Settings") { showSettings = true }
      }
      .sheet(isPresented: $showSettings) {
        SettingsView(model: model)
      }
      .alert("Allow camera access", isPresented: $model.askBeforeCameraPermission) {
        Button("Continue") { Task { await model.requestCameraPermission() } }
        Button("Cancel", role: .cancel) { model.stop() }
      } message: {
        Text("The Meta AI app will open so you can let Coin Spotter use the glasses camera.")
      }
    }
  }

  private var connect: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Connect your Meta glasses to begin. The Meta AI app will open and ask you to approve Coin Spotter.")
      Button(model.registrationState == .registering ? "Connecting" : "Connect glasses") {
        model.connectGlasses()
      }
      .buttonStyle(.borderedProminent)
      .disabled(model.registrationState == .registering)
    }
  }

  private var spotter: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text(model.activity)
        .font(.headline)

      if model.needsApiKey {
        Text("Add your Anthropic API key in Settings. Until then, possible coins are boxed on screen but not announced.")
          .foregroundStyle(.secondary)
      }
      if !model.hasActiveDevice && !model.isRunning {
        Text("Put on your glasses and make sure they are connected in the Meta AI app.")
          .foregroundStyle(.secondary)
      }

      Button(model.isRunning ? "Stop" : "Start spotting") {
        if model.isRunning { model.stop() } else { model.start() }
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .tint(model.isRunning ? .red : .accentColor)

      if let preview = model.preview {
        PreviewView(image: preview, candidates: model.candidates)
      }

      if let sighting = model.lastSighting {
        SightingView(sighting: sighting)
      }

      if model.isRunning || model.framesAnalyzed > 0 {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
          GridRow { Text("Frames checked"); Text("\(model.framesAnalyzed)") }
          GridRow { Text("Sent to Claude"); Text("\(model.claudeRequests)") }
          GridRow { Text("Coins announced"); Text("\(model.coinsFound)") }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
      }
    }
  }
}

/// The live frame with a box around each thing the on-phone filter flagged.
private struct PreviewView: View {
  let image: UIImage
  let candidates: [Candidate]

  var body: some View {
    Image(uiImage: image)
      .resizable()
      .aspectRatio(contentMode: .fit)
      .overlay {
        GeometryReader { geometry in
          ForEach(candidates.indices, id: \.self) { index in
            let candidate = candidates[index]
            // Padded so the box stays visible around an object only a few pixels wide.
            Rectangle()
              .stroke(.yellow, lineWidth: 2)
              .frame(
                width: candidate.width * geometry.size.width + 12,
                height: candidate.height * geometry.size.height + 12
              )
              .position(
                x: candidate.centerX * geometry.size.width,
                y: candidate.centerY * geometry.size.height)
          }
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 12))
  }
}

private struct SightingView: View {
  let sighting: Sighting

  var body: some View {
    HStack(spacing: 12) {
      if let data = sighting.crop, let image = UIImage(data: data) {
        Image(uiImage: image)
          .resizable()
          .frame(width: 88, height: 88)
          .clipShape(RoundedRectangle(cornerRadius: 8))
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(sighting.confirmed ? "Coin" : "Possible coin")
          .font(.headline)
        Text(sighting.position)
        Text(sighting.time, style: .time)
          .foregroundStyle(.secondary)
      }
    }
  }
}
