import SwiftUI

struct SettingsView: View {
    @Environment(ExportManager.self) private var exporter
    @Environment(ICloudWebSession.self) private var icloud
    @AppStorage(DefaultsKey.includeLivePhotoVideo) private var includeLivePhotoVideo = true
    @AppStorage(DefaultsKey.includeRAW) private var includeRAW = true
    @AppStorage(DefaultsKey.setFileDates) private var setFileDates = true

    var body: some View {
        @Bindable var exporter = exporter
        Form {
            Section("What to export") {
                Toggle("Include the video half of Live Photos", isOn: $includeLivePhotoVideo)
                Toggle("Include both files of RAW+JPEG pairs", isOn: $includeRAW)
            }
            Section("Files") {
                Toggle("Set file dates to when the photo was taken", isOn: $setFileDates)
            }
            Section("iCloud") {
                LabeledContent("Fast downloads") {
                    if let account = icloud.account {
                        HStack {
                            Text("Signed in as \(account.name)")
                            Button("Sign Out") { Task { await icloud.signOut() } }
                        }
                    } else {
                        Button("Sign In to iCloud…") { icloud.isSignInPresented = true }
                    }
                }
                Text("Signed in, Originals downloads files straight from iCloud instead of through Photos, which limits them to about 0.7 MB/s.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Downloads") {
                Stepper("Parallel downloads: \(exporter.maxConcurrent)", value: $exporter.maxConcurrent, in: 1...12)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
