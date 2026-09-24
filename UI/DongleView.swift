import SwiftUI

struct DongleView: View {
    @ObservedObject var dongle: DongleController

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.path")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(ControlStyle.accent)
                    .frame(width: 46, height: 46)
                    .background(ControlStyle.accent.opacity(0.12), in: .rect(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text("BTD 700")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("USB audio transmitter")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await dongle.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(dongle.busy)
                .help("Refresh dongle status")
            }
            .padding(.horizontal, 2)

            if !dongle.available {
                CardSection("Connection") {
                    Label("Plug in your BTD 700. It will connect automatically.", systemImage: "cable.connector")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            } else {
                CardSection("Connection") {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(dongle.connectionState >= 2 ? ControlStyle.accent : .orange)
                            .frame(width: 7, height: 7)
                        Text(dongle.connectionDescription)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                        Spacer()
                        if !dongle.firmware.isEmpty {
                            Text("FW \(dongle.firmware)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    HStack(spacing: 10) {
                        detail("CODEC", dongle.activeCodecDescription)
                        detail("QUALITY", dongle.qualityDescription)
                    }

                    Button {
                        Task { await dongle.setConnected(dongle.connectionState <= 1) }
                    } label: {
                        Text(dongle.connectionState <= 1 ? "Reconnect headphones" : "Disconnect headphones")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .disabled(dongle.busy)
                }

                CardSection("Transmission") {
                    HStack(spacing: 9) {
                        modeButton(.highQuality, icon: "waveform")
                        modeButton(.gaming, icon: "gamecontroller")
                    }

                    if dongle.audioMode == .broadcast {
                        Text("Auracast broadcast is active. Choose a mode above to return to headphone audio.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }

                    if availableCodecs.count > 1 {
                        HStack {
                            Text("Preferred codec")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Menu("Choose") {
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

                    Text("Supported by these headphones: \(supportedCodecDescription)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            if let message = dongle.errorMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .task { await dongle.refresh() }
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.white.opacity(0.05), in: .rect(cornerRadius: 10))
    }

    private func modeButton(_ mode: DongleController.AudioMode, icon: String) -> some View {
        let selected = dongle.audioMode == mode
        return Button {
            Task { await dongle.setAudioMode(mode) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                Text(mode == .gaming ? "Low latency" : "High quality")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .foregroundStyle(selected ? ControlStyle.background : .white.opacity(0.7))
            .background(selected ? ControlStyle.accent : .white.opacity(0.07), in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(dongle.busy)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var supportedCodecDescription: String {
        let names = availableCodecs.map(\.title)
        return names.isEmpty ? "none reported" : names.joined(separator: ", ")
    }

    private var availableCodecs: [DongleController.Codec] {
        DongleController.Codec.allCases.filter {
            $0 != .automatic && dongle.supportedCodecMask & $0.rawValue != 0
        }
    }
}
