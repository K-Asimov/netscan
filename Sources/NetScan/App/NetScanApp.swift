import SwiftUI
import AppKit

@main
struct NetScanApp: App {
    @StateObject private var viewModel = ScanViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 900, minHeight: 500)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Scan") {
                Button("Start Scan") {
                    viewModel.startScan()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(viewModel.isScanning)

                Button("Stop Scan") {
                    viewModel.stopScan()
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!viewModel.isScanning)

                Divider()

                Button("Clear Results") {
                    viewModel.clearResults()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(viewModel.devices.isEmpty)
            }

            CommandMenu("Port Scan") {
                Button("Start Port Scan") {
                    viewModel.startPortScanForSelectedDevice()
                }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(viewModel.selectedDevice == nil)

                Button("Configure Port Scan") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                .keyboardShortcut("g", modifiers: .command)
            }
        }

        Settings {
            PreferencesView(viewModel: viewModel)
        }
    }
}
