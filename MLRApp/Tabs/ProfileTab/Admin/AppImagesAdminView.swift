import SwiftUI
import PhotosUI

// MARK: - AppImagesAdminView
//
// Admin/committee screen to swap key site images (the Home logo, the Family Fest
// cover, …) without shipping a new build. Uploads to the public `site-assets`
// bucket and saves the URL in `app_images` (migration 0054); both web + iOS read
// it and fall back to the bundled asset. "Reset" clears the URL → back to the
// bundled default.

struct AppImagesAdminView: View {
    @Environment(AppEnvironment.self) private var env

    struct ManagedImage: Identifiable {
        var id: String { key }
        let key: String
        let title: String
        let fallback: String
        let note: String
        /// Wide banner (cover) vs compact (logo) — just a preview-height hint.
        let wide: Bool
    }

    private let images: [ManagedImage] = [
        .init(key: SiteImageKey.homeLogo, title: "Home logo", fallback: "brand-logo-green",
              note: "Shown at the top of the Home screen.", wide: false),
        .init(key: SiteImageKey.festCover, title: "Family Fest cover", fallback: "family-fest-cover",
              note: "The banner across the Family Fest tab.", wide: true),
    ]

    var body: some View {
        List {
            Section {
                Text("Pick a new image to replace the default everywhere — web and iOS update together. Reset to go back to the built-in art.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(images) { img in
                Section(img.title) {
                    AppImageRow(key: img.key, fallback: img.fallback, note: img.note, wide: img.wide)
                }
            }
        }
        .navigationTitle("App Images")
        .navigationBarTitleDisplayMode(.inline)
        .task { await env.appImagesService.load() }
    }
}

// MARK: - Row

private struct AppImageRow: View {
    @Environment(AppEnvironment.self) private var env
    let key: String
    let fallback: String
    let note: String
    let wide: Bool

    @State private var item: PhotosPickerItem?
    @State private var uploading = false
    @State private var error: String?

    private var hasCustom: Bool { env.appImagesService.url(for: key) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SiteImage(key: key, fallback: fallback)
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .frame(maxHeight: wide ? 170 : 110)
                .padding(.vertical, 4)

            Text(note)
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                PhotosPicker(selection: $item, matching: .images) {
                    Label(hasCustom ? "Replace photo" : "Change photo", systemImage: "photo.on.rectangle.angled")
                }
                .disabled(uploading)
                Spacer()
                if hasCustom {
                    Button(role: .destructive) {
                        Task { await reset() }
                    } label: {
                        Text("Reset")
                    }
                    .disabled(uploading)
                }
            }

            if uploading {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Uploading…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(Color.mlrDanger)
            }
        }
        .onChange(of: item) { _, newItem in
            guard let newItem else { return }
            Task { await upload(newItem) }
        }
    }

    private func upload(_ pick: PhotosPickerItem) async {
        uploading = true
        error = nil
        defer { uploading = false; item = nil }
        do {
            guard let data = try await pick.loadTransferable(type: Data.self),
                  let uiImage = UIImage(data: data) else {
                error = "Couldn't read that image."
                return
            }
            let url = try await env.mediaService.uploadSiteImage(image: uiImage, key: key)
            try await env.appImagesService.save(key: key, url: url)
        } catch {
            self.error = "Upload failed. \(EditorError.message(error))"
            Haptics.error()
        }
    }

    private func reset() async {
        error = nil
        do {
            try await env.appImagesService.reset(key: key)
        } catch {
            self.error = "Couldn\u{2019}t reset to default. \(EditorError.message(error))"
            Haptics.error()
        }
    }
}

// MARK: - In-place pencil on the Home logo

/// Puts a small pencil on the Home logo for whoever may edit app images
/// (admins, plus fest editors via `can_edit_fest`, the same rule
/// `AppImagesService.canEdit()` documents). Hidden while previewing as someone
/// else. Opens the App Images screen (pushed on the surrounding NavigationStack).
private struct HomeLogoEditPencil: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    @State private var canEdit = false
    @State private var open = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if (env.isAdmin || canEdit) && !env.isPreviewing {
                    InPlaceEditPencil(thing: "app images") { open = true }
                        .padding(.trailing, 8)
                }
            }
            .navigationDestination(isPresented: $open) { AppImagesAdminView() }
            .task(id: env.currentProfile?.id) {
                guard env.isSignedIn, !env.isAdmin else { return }
                canEdit = await env.appImagesService.canEdit()
            }
    }
}

extension View {
    /// See `HomeLogoEditPencil`.
    func homeLogoEditPencil() -> some View { modifier(HomeLogoEditPencil()) }
}
