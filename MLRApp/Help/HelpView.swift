import SwiftUI

// MARK: - Shared links + help contact
// One source of truth for the public web/app URL and the human escape hatch.
// Mirrors the web app's lib/help.ts HELP_CONTACT. No custom domain yet, so we
// point at the Vercel deployment.

enum MLRLinks {
    static let appURL = URL(string: "https://mlr-app-omega.vercel.app")!
    /// The guided-tour PDF, served by the web app (same file both platforms use).
    static let guidePDF = URL(string: "https://mlr-app-omega.vercel.app/mlr-app-guide.pdf")!
}

enum HelpContact {
    static let name = "Brian"
    static let phone = "+12248005389"   // E.164 — powers tap-to-text / tap-to-call
    static let email = "brian.theis15@gmail.com"
}

// MARK: - HelpView
// Plain-English Help / how-to screen for the least-technical family members.
// Leads with a real person to contact, then short FAQ cards. Mirrors the web
// app's /help page. Linked from the sign-in sheet and Home's "App & Help".

struct HelpView: View {
    @State private var composeState: MessageComposeState?
    @State private var showGuide = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                contactCard

                helpCard(emoji: "🌲", title: "What is this app?") {
                    Text("It's the home base for Muskellunge Lake Resort — the schedule, photos, dining, Family Fest, who's coming to events, and resort announcements, all in one place. Anyone in the family can use it.")
                }

                helpCard(emoji: "🧭", title: "Take a quick tour") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("New here? This short, plain-English walkthrough goes screen by screen — what each tab does, Family Fest, RSVPs, photos, and more.")
                        Button {
                            showGuide = true
                        } label: {
                            Label("Open the guided tour", systemImage: "book.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.mlrPrimary)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }

                helpCard(emoji: "👀", title: "Do I need an account?") {
                    Text("No — you can look around freely without signing in. You only add your name and email when you want to do something: post a photo, RSVP to an event, or get alerts. There's no password — we just email you a quick code to confirm it's you.")
                }

                helpCard(emoji: "📨", title: "I didn't get my sign-in code") {
                    VStack(alignment: .leading, spacing: 6) {
                        bullet("Give it a minute, then check your spam / junk folder — that's where it hides most often.")
                        bullet("Still nothing? On the sign-in screen, tap \u{201C}Resend code.\u{201D}")
                        bullet("Make sure the email you typed is correct — tap \u{201C}Use a different email\u{201D} to fix it.")
                        bullet("The code expires after a while. If it says expired, just resend a fresh one.")
                        bullet("Still stuck? Text \(HelpContact.name) (top of this page).")
                    }
                }

                helpCard(emoji: "🔠", title: "Make the text bigger") {
                    Text("The app follows your phone's text-size setting. To change it: Settings → Display & Brightness → Text Size (or Settings → Accessibility → Display & Text Size for even larger sizes). You can also pinch to zoom on photos.")
                }
            }
            .padding(16)
        }
        .background(Color.mlrSurface)
        .navigationTitle("Help & how-to")
        .navigationBarTitleDisplayMode(.inline)
        .messageComposer($composeState)
        .sheet(isPresented: $showGuide) {
            NavigationStack { GuideView() }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Help & how-to")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Color.mlrText)
            Text("New here, or stuck on something? Start below — and you can always just text \(HelpContact.name).")
                .font(.subheadline)
                .foregroundStyle(Color.mlrTextMuted)
        }
    }

    // MARK: - Contact escape hatch

    private var contactCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Need a hand? Text \(HelpContact.name).")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.mlrText)
            Text("If anything here doesn't work or doesn't make sense, send a quick text and \(HelpContact.name) will help you out.")
                .font(.subheadline)
                .foregroundStyle(Color.mlrTextMuted)
            HStack(spacing: 10) {
                Button {
                    composeState = MessageComposeState(recipients: [HelpContact.phone], body: "")
                } label: {
                    Label("Text \(HelpContact.name)", systemImage: "message.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.mlrPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                if let tel = URL(string: "tel://\(HelpContact.phone)") {
                    Link(destination: tel) {
                        Label("Call \(HelpContact.name)", systemImage: "phone.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.mlrPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.mlrCard)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            if let mail = URL(string: "mailto:\(HelpContact.email)?subject=\("MLR app — I need help".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") {
                Link("Prefer email? \(HelpContact.email)", destination: mail)
                    .font(.caption)
                    .foregroundStyle(Color.mlrTextMuted)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.mlrPrimary.opacity(0.06))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.mlrPrimary.opacity(0.15), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Helpers

    private func helpCard<Content: View>(emoji: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(emoji).font(.system(size: 18))
                Text(title).font(.system(size: 16, weight: .bold)).foregroundStyle(Color.mlrText)
            }
            content()
                .font(.subheadline)
                .foregroundStyle(Color.mlrTextMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
            Text(text)
        }
    }
}

#Preview {
    NavigationStack { HelpView() }
}
