import SwiftUI

// MARK: - Flat section helpers

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(Theme.textSecondary)
            .tracking(0.5)
            .padding(.horizontal, 20)
    }
}

private struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 20)
    }
}

private struct ToggleRow: View {
    let label: String
    @Binding var isOn: Bool
    var subtitle: String? = nil

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.text)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                }
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

// MARK: - Settings

struct SettingsContentView: View {
    @StateObject private var transcriber = Transcriber()
    @AppStorage("polishingEnabled") private var polishingEnabled = false
    @AppStorage("baseTone") private var baseTone = "neutral"
    @AppStorage("userStyleDescription") private var styleDescription = ""
    @AppStorage("alwaysEnglish") private var alwaysEnglish = false
    @State private var dictionaryEntries: [String: String] = [:]
    @State private var newOriginal = ""
    @State private var newCorrected = ""
    @State private var toneOverrides: [String: String] = [:]
    @State private var runningApps: [(name: String, bundleID: String)] = []
    @State private var selectedAppBundleID = ""
    @State private var newAppTone = "neutral"
    private let dictionary = DictionaryStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Text("Settings")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(Theme.text)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 24)

            // Speech Recognition
            SectionHeader(title: "Speech Recognition")
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    switch transcriber.modelState {
                    case .checking:
                        ProgressView().controlSize(.small)
                        Text("Checking…")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.text)
                    case .ready:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 14))
                        Text("On-device recognition ready")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.text)
                    case .error(let msg):
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                            .font(.system(size: 14))
                        Text(msg)
                            .font(.system(size: 13))
                            .foregroundColor(Theme.text)
                            .lineLimit(2)
                    default:
                        EmptyView()
                    }
                    Spacer()
                    Text("Whisper small")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }
            .padding(.bottom, 20)

            // Text Polishing
            SectionHeader(title: "Text Polishing")
            SettingsDivider()

            ToggleRow(
                label: "Enable polishing",
                isOn: $polishingEnabled,
                subtitle: polishingEnabled
                    ? "Tone adapts per app, smart formatting always runs"
                    : "Formatting only — punctuation, paragraphs, lists"
            )

            if polishingEnabled {
                SettingsDivider()

                // Base Tone
                VStack(alignment: .leading, spacing: 8) {
                    Text("Base Tone")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.text)
                    Picker("", selection: $baseTone) {
                        Text("Casual").tag("casual")
                        Text("Neutral").tag("neutral")
                        Text("Professional").tag("professional")
                    }
                    .pickerStyle(.segmented)

                    toneExample
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)

                SettingsDivider()

                // Style Description
                VStack(alignment: .leading, spacing: 8) {
                    Text("Style Description")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.text)
                    TextField("e.g., Clean and direct. No fluff.", text: $styleDescription)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.text)
                        .padding(8)
                        .background(Theme.fieldBg)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            }

            Spacer().frame(height: 20)

            // Language
            SectionHeader(title: "Language")
            SettingsDivider()

            ToggleRow(
                label: "Always output in English",
                isOn: $alwaysEnglish,
                subtitle: alwaysEnglish ? "Non-English dictation will be translated" : nil
            )

            Spacer().frame(height: 20)

            // Per-App Tone
            SectionHeader(title: "Per-App Tone")
            SettingsDivider()

            if !toneOverrides.isEmpty {
                ForEach(toneOverrides.sorted(by: { $0.key < $1.key }), id: \.key) { bundleID, tone in
                    HStack {
                        Text(appName(for: bundleID))
                            .font(.system(size: 13))
                            .foregroundColor(Theme.text)
                        Spacer()
                        Text(tone.capitalized)
                            .font(.system(size: 12))
                            .foregroundColor(Theme.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Theme.fieldBg)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        Button(action: {
                            ToneManager.shared.removeOverride(bundleID: bundleID)
                            toneOverrides = ToneManager.shared.allOverrides
                        }) {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(Theme.textSecondary.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    SettingsDivider()
                }
            }

            HStack(spacing: 8) {
                Picker("", selection: $selectedAppBundleID) {
                    Text("Select app…").tag("")
                    ForEach(runningApps.filter { !toneOverrides.keys.contains($0.bundleID) }, id: \.bundleID) { app in
                        Text(app.name).tag(app.bundleID)
                    }
                }
                .frame(maxWidth: .infinity)
                .font(.system(size: 12))

                Picker("", selection: $newAppTone) {
                    Text("Casual").tag("casual")
                    Text("Neutral").tag("neutral")
                    Text("Professional").tag("professional")
                    Text("Raw").tag("raw")
                }
                .frame(width: 110)
                .font(.system(size: 12))

                Button("Add") {
                    guard !selectedAppBundleID.isEmpty else { return }
                    ToneManager.shared.setOverride(bundleID: selectedAppBundleID, tone: newAppTone)
                    toneOverrides = ToneManager.shared.allOverrides
                    selectedAppBundleID = ""
                }
                .disabled(selectedAppBundleID.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Spacer().frame(height: 20)

            // Dictionary
            SectionHeader(title: "Dictionary")
            SettingsDivider()

            if dictionaryEntries.isEmpty {
                Text("No custom words yet. Edit after dictating to auto-learn, or add below.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                SettingsDivider()
            } else {
                ForEach(dictionaryEntries.sorted(by: { $0.key < $1.key }), id: \.key) { original, corrected in
                    HStack {
                        Text(original)
                            .font(.system(size: 13))
                            .foregroundColor(Theme.textSecondary)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9))
                            .foregroundColor(Theme.textSecondary.opacity(0.5))
                        Text(corrected)
                            .font(.system(size: 13))
                            .foregroundColor(Theme.text)
                        Spacer()
                        Button(action: {
                            dictionary.remove(original: original)
                            dictionaryEntries = dictionary.entries
                        }) {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(Theme.textSecondary.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    SettingsDivider()
                }
            }

            HStack(spacing: 8) {
                TextField("heard as", text: $newOriginal)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.text)
                    .padding(8)
                    .background(Theme.fieldBg)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Image(systemName: "arrow.right")
                    .font(.system(size: 9))
                    .foregroundColor(Theme.textSecondary.opacity(0.5))

                TextField("correct spelling", text: $newCorrected)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.text)
                    .padding(8)
                    .background(Theme.fieldBg)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Button("Add") {
                    guard !newOriginal.isEmpty, !newCorrected.isEmpty else { return }
                    dictionary.add(original: newOriginal, corrected: newCorrected)
                    dictionaryEntries = dictionary.entries
                    newOriginal = ""
                    newCorrected = ""
                }
                .disabled(newOriginal.isEmpty || newCorrected.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Spacer().frame(height: 20)

            // Shortcuts
            SectionHeader(title: "Shortcuts")
            SettingsDivider()

            ForEach(shortcuts, id: \.key) { shortcut in
                HStack {
                    Text(shortcut.key)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(Theme.text)
                    Spacer()
                    Text(shortcut.desc)
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                SettingsDivider()
            }

            Spacer().frame(height: 24)
        }
        .background(Theme.bg)
        .onAppear {
            transcriber.checkAndDownload()
            dictionaryEntries = dictionary.entries
            toneOverrides = ToneManager.shared.allOverrides
            runningApps = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
                .compactMap { app in
                    guard let bid = app.bundleIdentifier else { return nil }
                    return (name: app.localizedName ?? bid, bundleID: bid)
                }
                .sorted { $0.name < $1.name }
        }
    }

    @ViewBuilder
    private var toneExample: some View {
        switch baseTone {
        case "casual":
            Text("\"hey can you send me that thing\" → keeps as-is, fixes punctuation")
        case "professional":
            Text("\"hey can you send me that thing\" → \"Could you please send me the item we discussed?\"")
        default:
            Text("\"hey can you send me that thing\" → \"Hey, can you send me that thing we talked about?\"")
        }
    }

    private var shortcuts: [(key: String, desc: String)] {
        [
            ("Hold Fn", "Start dictating"),
            ("Release Fn", "Stop and paste"),
            ("Double-tap Fn", "Lock (hands-free)"),
            ("Ctrl + Fn", "Summarize mode"),
            ("Option + Fn", "Ask a question"),
            ("Escape", "Cancel recording"),
            ("Ctrl+Cmd+V", "Paste last transcription"),
            ("Right-click pill", "Open menu"),
        ]
    }

    private func appName(for bundleID: String) -> String {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == bundleID }?
            .localizedName ?? bundleID.components(separatedBy: ".").last ?? bundleID
    }
}

struct SettingsView: View {
    var body: some View {
        ScrollView {
            SettingsContentView()
        }
        .frame(width: 420, height: 620)
        .background(Theme.bg)
        .preferredColorScheme(.light)
    }
}
