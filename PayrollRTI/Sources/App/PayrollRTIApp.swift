import SwiftUI

@main
struct PayrollRTIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Basic PAYE Tools", id: WindowID.main) {
            MainView()
                .environmentObject(appDelegate.server)
                .environmentObject(appDelegate.updates)
                .environmentObject(appDelegate.browser)
                .environment(\.appActions, appDelegate)
                .frame(minWidth: 800, minHeight: 560)
        }
        .defaultSize(width: 1200, height: 820)
        .commands {
            AppCommands(server: appDelegate.server, browser: appDelegate.browser, actions: appDelegate)
        }

        Settings {
            SettingsView()
                .environmentObject(appDelegate.server)
                .environment(\.appActions, appDelegate)
        }

        MenuBarExtra {
            StatusMenu()
                .environmentObject(appDelegate.server)
                .environment(\.appActions, appDelegate)
        } label: {
            StatusIcon(server: appDelegate.server)
        }
    }
}

enum WindowID {
    static let main = "main"
}

private struct AppActionsKey: EnvironmentKey {
    static let defaultValue: AppDelegate? = nil
}

extension EnvironmentValues {
    var appActions: AppDelegate? {
        get { self[AppActionsKey.self] }
        set { self[AppActionsKey.self] = newValue }
    }
}
