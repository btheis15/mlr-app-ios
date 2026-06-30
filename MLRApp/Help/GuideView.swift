import SwiftUI
import PDFKit

// MARK: - GuideView
// In-app viewer for the guided-tour PDF served by the web app
// (MLRLinks.guidePDF) — the SAME file the web /guide page embeds, so the tour
// stays in sync across both platforms with no bundled copy to drift. Loads the
// PDF data over the network and renders it with PDFKit; offers an "Open in
// Safari" / share fallback if it can't load.

struct GuideView: View {
    @State private var document: PDFDocument?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let document {
                PDFKitView(document: document)
                    .ignoresSafeArea(edges: .bottom)
            } else if loadFailed {
                failureState
            } else {
                ProgressView("Loading the tour…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.mlrSurface)
        .navigationTitle("Guided tour")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: MLRLinks.guidePDF) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .task { await load() }
    }

    private var failureState: some View {
        VStack(spacing: 14) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 40))
                .foregroundStyle(Color.mlrTextMuted)
            Text("Couldn't load the tour")
                .font(.headline)
                .foregroundStyle(Color.mlrText)
            Text("Check your connection and try again, or open it in Safari.")
                .font(.subheadline)
                .foregroundStyle(Color.mlrTextMuted)
                .multilineTextAlignment(.center)
            Link("Open in Safari ↗", destination: MLRLinks.guidePDF)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.mlrPrimary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        guard document == nil else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: MLRLinks.guidePDF)
            if let doc = PDFDocument(data: data) {
                document = doc
            } else {
                loadFailed = true
            }
        } catch {
            loadFailed = true
        }
    }
}

// MARK: - PDFKit bridge

private struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .systemGroupedBackground
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
    }
}

#Preview {
    NavigationStack { GuideView() }
}
