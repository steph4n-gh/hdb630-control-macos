import Cocoa
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let bluetooth = BluetoothManager()
    private let dongle = DongleController()
    private var controller: HeadphoneController!
    private var cancellables = Set<AnyCancellable>()
    private var didAutoConnect = false
    private var pollTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = HeadphoneController(bluetooth: bluetooth)

        NSApp.setActivationPolicy(.accessory)

        // Status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "HDB 630")
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Popover
        popover = NSPopover()
        popover.behavior = .transient
        let hostingController = NSHostingController(rootView:
            ControlRootView(controller: controller, bluetooth: bluetooth, dongle: dongle)
        )
        hostingController.sizingOptions = .preferredContentSize
        popover.contentViewController = hostingController

        // Update menu bar with battery level
        controller.$batteryLevel
            .combineLatest(bluetooth.$state)
            .receive(on: RunLoop.main)
            .sink { [weak self] battery, state in
                guard let button = self?.statusItem.button else { return }
                if state == .connected && battery > 0 {
                    button.title = " \(battery)%"
                } else {
                    button.title = ""
                }
            }
            .store(in: &cancellables)

        // Set device name + auto-connect on launch
        bluetooth.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                if state == .connected {
                    let name = self.bluetooth.pairedDevices.first?.name ?? "HDB 630"
                    self.controller.deviceInfo.name = name
                } else if state == .disconnected && !self.didAutoConnect && !self.bluetooth.pairedDevices.isEmpty {
                    self.didAutoConnect = true
                    if let hdb = self.bluetooth.pairedDevices.first(where: {
                        ($0.name ?? "").localizedCaseInsensitiveContains("HDB") ||
                        ($0.name ?? "").localizedCaseInsensitiveContains("630")
                    }), hdb.isConnected() {
                        self.bluetooth.connect(to: hdb)
                    }
                }
            }
            .store(in: &cancellables)

        bluetooth.scanForDevices()

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.bluetooth.disconnect()
        }

    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            updatePolling()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
            if bluetooth.state == .connected {
                Task { await controller.pollState() }
            }
            updatePolling()
        }
    }

    private var needsPolling: Bool {
        popover.isShown
    }

    private func updatePolling() {
        if needsPolling && bluetooth.state == .connected {
            startPolling()
        } else {
            stopPolling()
        }
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.bluetooth.state == .connected else { return }
            Task { await self.controller.pollState() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}

private struct ControlRootView: View {
    @ObservedObject var controller: HeadphoneController
    @ObservedObject var bluetooth: BluetoothManager
    @ObservedObject var dongle: DongleController
    @State private var selectedTab = 0

    private var contentHeight: CGFloat {
        if selectedTab == 1 { return dongle.available ? 375 : 150 }
        return bluetooth.state == .connected ? 610 : 225
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                tab("Headphones", icon: "headphones", index: 0)
                tab("BTD 700", icon: "waveform.path", index: 1)
            }
            .padding(4)
            .background(.white.opacity(0.055), in: .rect(cornerRadius: 12))
            .padding(.horizontal, 16)
            .padding(.top, 15)
            .padding(.bottom, 2)

            Group {
                if selectedTab == 0 {
                    StatusBarView(controller: controller, bluetooth: bluetooth)
                        .environmentObject(bluetooth)
                } else {
                    ScrollView(showsIndicators: false) {
                        DongleView(dongle: dongle)
                            .environmentObject(bluetooth)
                    }
                }
            }
            .frame(height: contentHeight, alignment: .top)
        }
        .frame(width: 360)
        .background {
            LinearGradient(
                colors: [ControlStyle.background, Color(red: 0.09, green: 0.14, blue: 0.19)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .preferredColorScheme(.dark)
        .tint(ControlStyle.accent)
    }

    private func tab(_ title: String, icon: String, index: Int) -> some View {
        Button {
            selectedTab = index
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(selectedTab == index ? .white : .white.opacity(0.56))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(selectedTab == index ? .white.opacity(0.13) : .clear, in: .rect(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedTab == index ? .isSelected : [])
    }
}
