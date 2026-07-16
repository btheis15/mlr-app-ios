import SwiftUI

// MARK: - PreviewAsView
//
// Admin "view as" preview (device-local, UI-only): see the app as a regular
// member or as a signed-out guest, without changing your account or any data.
// Mirrors the web /admin/preview. Entering is admin-only; the floating
// PreviewBanner (shown app-wide while active) is how you exit.

struct PreviewAsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        List {
            Section {
                Text("See the app exactly as a member or a signed-out guest would. This only changes what you see on this device — it never touches your account or any data.")
                    .font(.mlrScaled(13))
                    .foregroundStyle(Color.mlrTextMuted)
            }

            Section("View as") {
                row(.member, title: "A member", subtitle: "Regular member view — admin controls hidden",
                    icon: "person.fill")
                row(.guest, title: "A guest", subtitle: "Signed-out experience — members-only content locked",
                    icon: "person.crop.circle.badge.questionmark")
            }

            if env.isPreviewing {
                Section {
                    Button(role: .destructive) {
                        env.setPreview(.off)
                    } label: {
                        Label("Exit preview", systemImage: "xmark.circle.fill")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Preview As")
        .navigationBarTitleDisplayMode(.large)
    }

    private func row(_ mode: AppEnvironment.PreviewMode, title: String, subtitle: String, icon: String) -> some View {
        Button {
            env.setPreview(env.previewMode == mode ? .off : mode)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.mlrScaled(16))
                    .foregroundStyle(Color.mlrPrimary)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.mlrScaled(15, weight: .medium)).foregroundStyle(Color.mlrText)
                    Text(subtitle).font(.caption).foregroundStyle(Color.mlrTextMuted)
                }
                Spacer()
                if env.previewMode == mode {
                    Image(systemName: "checkmark").foregroundStyle(Color.mlrPrimary).fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - PreviewBanner
//
// Floating pill shown app-wide (mounted in RootView) whenever a preview is
// active — names the current preview and offers a one-tap exit.

struct PreviewBanner: View {
    @Environment(AppEnvironment.self) private var env

    private var label: String {
        switch env.previewMode {
        case .guest:  return "Previewing as a guest"
        case .member: return "Previewing as a member"
        case .off:    return ""
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "eye.fill")
                .font(.mlrScaled(13, weight: .semibold))
            Text(label)
                .font(.mlrScaled(13, weight: .semibold))
            Spacer(minLength: 8)
            Button { env.setPreview(.off) } label: {
                Text("Exit")
                    .font(.mlrScaled(13, weight: .bold))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(.white.opacity(0.25))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.mlrWarning, in: Capsule())
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
    }
}
