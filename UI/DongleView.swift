import SwiftUI

struct DongleView: View {
    @ObservedObject var dongle: DongleController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "waveform.path")
                    .font(.title2)
                Text("BTD 700")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await dongle.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(dongle.busy)
                .help("Refresh dongle status")
            }

            if !dongle.available {
                Text("Plug in your BTD 700, then press Refresh.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                CardSection("Connection") {
                    LabeledContent("State", value: dongle.connectionDescription)
                    LabeledContent("Codec", value: dongle.activeCodecDescription)
                    LabeledContent("Quality", value: dongle.qualityDescription)
                    if !dongle.firmware.isEmpty {
                        LabeledContent("Firmware", value: dongle.firmware)
                    }
                    HStack {
                        Spacer()
                        Button(dongle.connectionState <= 1 ? "Reconnect" : "Disconnect") {
                            Task { await dongle.setConnected(dongle.connectionState <= 1) }
                        }
                        .disabled(dongle.busy)
                    }
                }

                CardSection("Transmission") {
                    Picker("Mode", selection: Binding(
                        get: { dongle.audioMode },
                        set: { value in Task { await dongle.setAudioMode(value) } }
                    )) {
                        Text(DongleController.AudioMode.highQuality.title).tag(DongleController.AudioMode.highQuality)
                        Text(DongleController.AudioMode.gaming.title).tag(DongleController.AudioMode.gaming)
                    }
                    .disabled(dongle.busy)

                    if availableCodecs.count > 1 {
                        HStack {
                            Text("Codec")
                            Spacer()
                            Menu("Request codec") {
                                Button("Automatic") {
                                    Task { await dongle.setCodec(.automatic) }
                                }
                                ForEach(availableCodecs) { codec in
                                    Button(codec.title) {
                                        Task { await dongle.setCodec(codec) }
                                    }
                                }
                            }
                            .disabled(dongle.busy)
                        }
                    }
                    Text("Available with the connected headphones: \(supportedCodecDescription).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let message = dongle.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 320, height: 400, alignment: .topLeading)
        .task { await dongle.refresh() }
    }

    private var supportedCodecDescription: String {
        let names = availableCodecs.map(\.title)
        return names.isEmpty ? "no available codecs" : names.joined(separator: ", ")
    }

    private var availableCodecs: [DongleController.Codec] {
        DongleController.Codec.allCases.filter {
            $0 != .automatic && dongle.supportedCodecMask & $0.rawValue != 0
        }
    }
}
