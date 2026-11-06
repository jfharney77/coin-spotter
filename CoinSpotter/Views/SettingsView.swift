import SwiftUI

struct SettingsView: View {
  @Bindable var model: SpotterModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Toggle("Confirm with Claude", isOn: $model.confirmWithClaude)
          if model.confirmWithClaude {
            SecureField("Anthropic API key", text: $model.apiKey)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
            Picker("Model", selection: $model.claudeModel) {
              ForEach(ClaudeModel.allCases) { Text($0.label).tag($0) }
            }
          }
        } footer: {
          Text(
            model.confirmWithClaude
              ? "Round objects found on the phone are sent to Claude, and you are alerted only when it agrees. The key is stored in the iOS Keychain."
              : "You are alerted for every round object the phone finds. This is free and works offline, but expect false alarms.")
        }

        Section {
          Button("Play a test alert") { model.testAlert() }
        } footer: {
          Text("You should hear it through the glasses while you are wearing them.")
        }

        Section {
          Toggle(
            "Use phone camera as glasses",
            isOn: Binding(
              get: { model.testModeOn },
              set: { on in Task { await model.setTestMode(on) } }))
        } footer: {
          Text("Test mode. Simulates a pair of glasses with the phone's back camera, so you can point it at coins on the floor without wearing anything.")
        }

        if model.isRegistered && !model.testModeOn {
          Section {
            Button("Disconnect glasses", role: .destructive) {
              model.disconnectGlasses()
              dismiss()
            }
          }
        }
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        Button("Done") { dismiss() }
      }
    }
  }
}
