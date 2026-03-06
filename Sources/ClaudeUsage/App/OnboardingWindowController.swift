import AppKit
import SwiftUI

class OnboardingWindowController: NSWindowController {
    static let shared = OnboardingWindowController()
    static let hasOnboardedKey = "hasOnboarded"
    static var hasOnboarded: Bool {
        get { UserDefaults.standard.bool(forKey: hasOnboardedKey) }
        set { UserDefaults.standard.set(newValue, forKey: hasOnboardedKey) }
    }
    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Sage Bar"
        window.center()
        super.init(window: window)
        window.contentView = NSHostingView(rootView: OnboardingView(onFinish: { [weak self] in
            Self.hasOnboarded = true
            self?.window?.close()
        }))
        window.delegate = self
    }
    required init?(coder: NSCoder) { nil }
    func showWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

extension OnboardingWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        Self.hasOnboarded = true
        NSApp.setActivationPolicy(.accessory)
    }
}

struct OnboardingView: View {
    let onFinish: () -> Void
    @State private var page = 0
    private let pages = 4
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Group {
                switch page {
                case 0: welcomePage
                case 1: accountsPage
                case 2: featuresPage
                default: getStartedPage
                }
            }
            .frame(maxWidth: .infinity)
            Spacer()
            HStack {
                if page > 0 {
                    Button("Back") { withAnimation { page -= 1 } }
                }
                Spacer()
                if page < pages - 1 {
                    Button("Next") { withAnimation { page += 1 } }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Get Started") { onFinish() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.bottom, 8)
        }
        .padding(24)
        .frame(width: 520, height: 420)
    }
    private var welcomePage: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)
            Text("Sage Bar").font(.title).bold()
            Text("Track AI token usage and costs\nacross all your providers.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
    }
    private var accountsPage: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 40))
                .foregroundColor(.accentColor)
            Text("Multi-Provider Accounts").font(.title2).bold()
            Text("Add accounts for Anthropic, OpenAI,\nGitHub Copilot, Windsurf, and Gemini.\nAPI keys are stored securely in Keychain.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
    }
    private var featuresPage: some View {
        VStack(spacing: 12) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 40))
                .foregroundColor(.accentColor)
            Text("Alerts & Automations").font(.title2).bold()
            Text("Set budget alerts, webhook integrations,\nautomation rules, and a global hotkey\nto access usage data instantly.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
    }
    private var getStartedPage: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)
            Text("You're All Set").font(.title2).bold()
            Text("Sage Bar lives in your menu bar.\nClick the icon to see usage at a glance,\nor open Settings to configure accounts.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
    }
}
