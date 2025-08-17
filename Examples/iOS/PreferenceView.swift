import HaishinKit
import SwiftUI

struct PreferenceView: View {
    @EnvironmentObject var model: PreferenceViewModel

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("URL")
                        .frame(width: 80, alignment: .leading)
                        .foregroundColor(.secondary)
                    TextField(Preference.default.uri, text: $model.uri)
                }.padding(.vertical, 4)
                HStack {
                    Text("Name")
                        .frame(width: 80, alignment: .leading)
                        .foregroundColor(.secondary)
                    TextField(Preference.default.streamName, text: $model.streamName)
                }.padding(.vertical, 4)
            } header: {
                Text("Stream")
            }
            Section {
                Picker("Format", selection: $model.audioFormat) {
                    ForEach(AudioCodecSettings.Format.allCases, id: \.self) { format in
                        Text("\(format)").tag(format)
                    }
                }
            } header: {
                Text("Audio Codec Settings")
            }
            Section {
                Toggle(isOn: $model.isLowLatencyRateControlEnabled) {
                    Text("LowLatency")
                }
                Picker("BitRateMode", selection: $model.bitRateMode) {
                    ForEach(model.bitRateModes, id: \.description) { index in
                        Text(index.description).tag(index)
                    }
                }
            } header: {
                Text("Video Codec Settings")
            }
            Section {
                Button(action: {
                    model.showIngestSheet.toggle()
                }, label: {
                    Text("Memory release test for IngestView")
                }).sheet(isPresented: $model.showIngestSheet, content: {
                    IngestView()
                })
            } header: {
                Text("Test Case")
            }
        }
    }
}

#Preview {
    PreferenceView()
}
