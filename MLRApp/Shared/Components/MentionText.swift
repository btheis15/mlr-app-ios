import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

// MARK: - MentionText
// Renders a string with @name mentions highlighted in mlrPrimary green.
// Mirrors the web app's shared `MentionText` helper and the @mention pattern
// in chat bubbles and post comments.
//
// Usage:
//   MentionText("Hey @Dorothy, can you grab the paddles?")

// MARK: - MentionText view

struct MentionText: View {
    let text: String
    var baseFont: Font = .mlrBody
    var baseColor: Color = Color.mlrText
    var mentionColor: Color = Color.mlrPrimary

    init(_ text: String, baseFont: Font = .mlrBody, baseColor: Color = Color.mlrText, mentionColor: Color = Color.mlrPrimary) {
        self.text = text
        self.baseFont = baseFont
        self.baseColor = baseColor
        self.mentionColor = mentionColor
    }

    var body: some View {
        Text(attributedString)
            .font(baseFont)
    }

    private var attributedString: AttributedString {
        var result = AttributedString()
        let segments = Self.parse(text)

        for segment in segments {
            switch segment {
            case .plain(let s):
                var part = AttributedString(s)
                part.foregroundColor = UIColor(baseColor)
                result.append(part)

            case .mention(let s):
                var part = AttributedString(s)
                part.foregroundColor = UIColor(mentionColor)
                // Semi-bold weight for mentions
                part.font = UIFont.systemFont(
                    ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize,
                    weight: .semibold
                )
                result.append(part)
            }
        }
        return result
    }
}

// MARK: - Text segment parser

private enum TextSegment {
    case plain(String)
    case mention(String) // includes the leading @
}

extension MentionText {
    /// Splits `text` into alternating plain / mention segments.
    /// A mention is `@` followed by one or more non-whitespace characters.
    fileprivate static func parse(_ text: String) -> [TextSegment] {
        var segments: [TextSegment] = []
        // Match @word (word = alphanumeric + underscore, matching web app convention)
        let pattern = try! NSRegularExpression(pattern: #"@[\w]+"#)
        let nsText = text as NSString
        var cursor = text.startIndex

        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))

        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }

            // Plain text before this mention
            if cursor < range.lowerBound {
                segments.append(.plain(String(text[cursor..<range.lowerBound])))
            }

            // The mention itself
            segments.append(.mention(String(text[range])))

            cursor = range.upperBound
        }

        // Remaining plain text after the last mention
        if cursor < text.endIndex {
            segments.append(.plain(String(text[cursor...])))
        }

        return segments.isEmpty ? [.plain(text)] : segments
    }
}

// MARK: - MentionAutocomplete

/// A small overlay list that appears above the keyboard when the user types `@`
/// in a TextEditor. Filters the member list and lets the user tap to complete.
///
/// Usage in a view that has a TextEditor:
///
///   @State private var messageText = ""
///   @State private var mentionQuery: String? = nil   // nil = hidden
///
///   ZStack(alignment: .bottomLeading) {
///       TextEditor(text: $messageText)
///           .onChange(of: messageText) { _, new in
///               mentionQuery = detectMentionQuery(in: new)
///           }
///
///       if let query = mentionQuery {
///           MentionAutocomplete(
///               members: allMembers,
///               query: query,
///               onSelect: { profile in
///                   messageText = applyMention(profile, to: messageText)
///                   mentionQuery = nil
///               }
///           )
///       }
///   }

struct MentionAutocomplete: View {
    let members: [Profile]
    var query: String = ""
    var onSelect: (Profile) -> Void = { _ in }

    private var filtered: [Profile] {
        let q = query.lowercased()
        guard !q.isEmpty else { return Array(members.prefix(6)) }
        return members
            .filter { $0.name.lowercased().contains(q) }
            .prefix(6)
            .map { $0 }
    }

    var body: some View {
        if !filtered.isEmpty {
            VStack(spacing: 0) {
                ForEach(filtered) { profile in
                    Button {
                        onSelect(profile)
                    } label: {
                        HStack(spacing: 10) {
                            AvatarView(profile: profile, size: .small)

                            Text(profile.name)
                                .font(.mlrScaled(14, weight: .medium))
                                .foregroundStyle(Color.mlrText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if profile.id != filtered.last?.id {
                        Divider()
                            .padding(.leading, 50)
                    }
                }
            }
            .background(Color.mlrSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.mlrBorder, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: -4)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - Mention detection helpers

/// Returns the current @query if the cursor is inside a mention, else nil.
/// Call from `.onChange(of: text)`.
func detectMentionQuery(in text: String) -> String? {
    // Find the last @ not followed by whitespace
    guard let atIndex = text.lastIndex(of: "@") else { return nil }
    let afterAt = text[text.index(after: atIndex)...]
    // Only active if the text after @ has no space (still typing the name)
    if afterAt.contains(" ") || afterAt.contains("\n") { return nil }
    return String(afterAt)
}

/// Replaces the trailing @query in `text` with `@fullName `.
func applyMention(_ profile: Profile, to text: String) -> String {
    guard let atIndex = text.lastIndex(of: "@") else { return text }
    let prefix = String(text[..<atIndex])
    return prefix + "@\(profile.name) "
}

// MARK: - MentionTextView (TextKit-backed growing input)
//
// A UITextView wrapped for SwiftUI so the composer feels genuinely native:
// clean insets, buttery auto-grow (1 line → maxHeight, then scrolls), inline
// @mention highlighting as you type, and cursor-aware mention detection (the
// active @query is derived from the real caret, not the last @ in the string).
// The wire format stays plain text — `text` is the source of truth; the
// highlighting is presentation only.

struct MentionTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    /// Set by the parent when the user taps an autocomplete row; consumed here
    /// (replaces the caret's @query with the full name) and reset to nil.
    @Binding var pendingMention: Profile?
    var placeholder: String = "Message…"
    var maxHeight: CGFloat = 124
    var onMentionQueryChange: (String?) -> Void = { _ in }
    /// Called when the user pastes image(s) from the clipboard (iMessage-style).
    var onPasteMedia: ([ChatAttachment]) -> Void = { _ in }

    private static let inset = UIEdgeInsets(top: 9, left: 6, bottom: 9, right: 6)

    func makeUIView(context: Context) -> UITextView {
        let tv = PasteAwareTextView()
        tv.pasteCoordinator = context.coordinator
        tv.delegate = context.coordinator
        tv.font = UIFont.preferredFont(forTextStyle: .body)
        tv.adjustsFontForContentSizeCategory = true
        tv.backgroundColor = .clear
        tv.textContainerInset = Self.inset
        tv.textContainer.lineFragmentPadding = 0
        tv.isScrollEnabled = false
        tv.textColor = .label

        let ph = UILabel()
        ph.text = placeholder
        ph.font = tv.font
        ph.textColor = .placeholderText
        ph.translatesAutoresizingMaskIntoConstraints = false
        tv.addSubview(ph)
        NSLayoutConstraint.activate([
            ph.leadingAnchor.constraint(equalTo: tv.leadingAnchor, constant: Self.inset.left),
            ph.topAnchor.constraint(equalTo: tv.topAnchor, constant: Self.inset.top),
        ])
        context.coordinator.placeholder = ph
        context.coordinator.textView = tv
        DispatchQueue.main.async { context.coordinator.recalcHeight(tv) }
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.parent = self

        // Consume a mention insertion requested by the parent.
        if let mention = pendingMention {
            context.coordinator.insert(mention: mention, in: tv)
            DispatchQueue.main.async { self.pendingMention = nil }
            return
        }

        // Sync external text changes (edit start, clear-on-send) without disturbing
        // the caret during normal typing (when tv.text already equals text).
        if tv.text != text {
            context.coordinator.setText(text, in: tv, caretToEnd: true)
        }
        context.coordinator.placeholder?.isHidden = !text.isEmpty
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MentionTextView
        weak var textView: UITextView?
        weak var placeholder: UILabel?

        init(_ parent: MentionTextView) { self.parent = parent }

        func textViewDidChange(_ tv: UITextView) {
            let caret = tv.selectedRange
            applyHighlight(to: tv, preservingCaret: caret)
            parent.text = tv.text
            placeholder?.isHidden = !tv.text.isEmpty
            recalcHeight(tv)
            parent.onMentionQueryChange(mentionQuery(in: tv))
        }

        func textViewDidChangeSelection(_ tv: UITextView) {
            parent.onMentionQueryChange(mentionQuery(in: tv))
        }

        // MARK: helpers

        func setText(_ newText: String, in tv: UITextView, caretToEnd: Bool) {
            tv.text = newText
            applyHighlight(to: tv, preservingCaret: nil)
            if caretToEnd {
                let end = (newText as NSString).length
                tv.selectedRange = NSRange(location: end, length: 0)
            }
            placeholder?.isHidden = !newText.isEmpty
            recalcHeight(tv)
        }

        func insert(mention profile: Profile, in tv: UITextView) {
            let ns = tv.text as NSString
            let caret = min(tv.selectedRange.location, ns.length)
            let upTo = ns.substring(to: caret)
            guard let atRange = upTo.range(of: "@", options: .backwards) else { return }
            let atOffset = upTo.distance(from: upTo.startIndex, to: atRange.lowerBound)
            let replaceLen = caret - atOffset
            let replacement = "@\(profile.name) "
            let newText = ns.replacingCharacters(in: NSRange(location: atOffset, length: replaceLen),
                                                 with: replacement)
            tv.text = newText
            applyHighlight(to: tv, preservingCaret: nil)
            tv.selectedRange = NSRange(location: atOffset + (replacement as NSString).length, length: 0)
            parent.text = newText
            placeholder?.isHidden = !newText.isEmpty
            recalcHeight(tv)
            parent.onMentionQueryChange(nil)
        }

        /// Recolor `@word` runs; keep everything else as body/label so text typed
        /// after a mention isn't tinted.
        func applyHighlight(to tv: UITextView, preservingCaret caret: NSRange?) {
            let text = tv.text ?? ""
            let full = NSRange(location: 0, length: (text as NSString).length)
            let body = UIFont.preferredFont(forTextStyle: .body)
            let attr = NSMutableAttributedString(string: text, attributes: [
                .font: body, .foregroundColor: UIColor.label,
            ])
            if let re = try? NSRegularExpression(pattern: "@[\\w]+") {
                for m in re.matches(in: text, range: full) {
                    attr.addAttributes([
                        .foregroundColor: UIColor(Color.mlrPrimary),
                        .font: UIFont.systemFont(ofSize: body.pointSize, weight: .semibold),
                    ], range: m.range)
                }
            }
            if tv.attributedText != attr {
                let sel = caret ?? tv.selectedRange
                tv.attributedText = attr
                tv.selectedRange = NSRange(location: min(sel.location, (text as NSString).length),
                                           length: 0)
            }
            tv.typingAttributes = [.font: body, .foregroundColor: UIColor.label]
        }

        func recalcHeight(_ tv: UITextView) {
            let width = tv.bounds.width
            guard width > 1 else { return }
            let fit = tv.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
            let clamped = min(max(fit, 0), parent.maxHeight)
            tv.isScrollEnabled = fit > parent.maxHeight + 0.5
            if abs(parent.height - clamped) > 0.5 {
                DispatchQueue.main.async { self.parent.height = clamped }
            }
        }

        /// The active @query based on the caret (nil if not currently in a mention).
        func mentionQuery(in tv: UITextView) -> String? {
            let ns = tv.text as NSString
            let caret = min(tv.selectedRange.location, ns.length)
            let upTo = ns.substring(to: caret)
            guard let atRange = upTo.range(of: "@", options: .backwards) else { return nil }
            let after = upTo[atRange.upperBound...]
            if after.contains(" ") || after.contains("\n") { return nil }
            return String(after)
        }
    }
}

// MARK: - PasteAwareTextView
//
// A UITextView that accepts pasted IMAGES (iMessage-style) in addition to text.
// When the clipboard has image(s), Paste hands them to the composer as
// attachments instead of doing nothing; text still pastes normally. Videos/PDFs
// from the clipboard are rare — the composer's attach button (Photos + Files)
// covers those.

final class PasteAwareTextView: UITextView {
    weak var pasteCoordinator: MentionTextView.Coordinator?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) && UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let pb = UIPasteboard.general
        if pb.hasImages, let images = pb.images, !images.isEmpty {
            let items: [ChatAttachment] = images.compactMap { img in
                guard let data = img.jpegData(compressionQuality: 0.85) else { return nil }
                return ChatAttachment(data: data, filename: "pasted.jpg", mimeType: "image/jpeg", kind: .image, preview: img)
            }
            if !items.isEmpty {
                pasteCoordinator?.parent.onPasteMedia(items)
                if pb.hasStrings { super.paste(sender) } // keep any text paste too
                return
            }
        }
        super.paste(sender)
    }
}

// MARK: - ChatAttachment
//
// A file staged in the composer, uploaded on send. Photos/videos preview inline;
// anything else (PDFs, docs, …) shows as a file chip.

struct ChatAttachment: Identifiable {
    let id = UUID()
    var data: Data
    var filename: String
    var mimeType: String
    var kind: Kind
    var preview: UIImage?
    enum Kind { case image, video, file }
}

// MARK: - ChatComposer
//
// The full message input bar: the growing TextKit field, the @mention
// autocomplete popover, an optional "editing" banner, an attach button (photos,
// videos, or any file) with a staged-attachment strip, clipboard image paste,
// and a spring-animated send button with haptics. Reusable across chat.

struct ChatComposer: View {
    @Binding var text: String
    let roster: [Profile]
    var isEditing: Bool = false
    var sending: Bool = false
    /// Whether the attach button + clipboard-image paste are offered. Off for
    /// surfaces that are text-only (e.g. work-item comments).
    var allowsAttachments: Bool = true
    /// Called on send with the staged attachments (cleared here afterwards).
    var onSend: ([ChatAttachment]) -> Void
    var onCancelEdit: () -> Void = {}

    @State private var height: CGFloat = 36
    @State private var mentionQuery: String?
    @State private var pendingMention: Profile?
    @State private var attachments: [ChatAttachment] = []
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool { (!trimmed.isEmpty || !attachments.isEmpty) && !sending }

    var body: some View {
        VStack(spacing: 0) {
            if let query = mentionQuery, !roster.isEmpty {
                MentionAutocomplete(members: roster, query: query) { profile in
                    pendingMention = profile
                    mentionQuery = nil
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if isEditing {
                HStack {
                    Label("Editing message", systemImage: "pencil")
                        .font(.mlrScaled(12))
                        .foregroundStyle(Color.mlrTextMuted)
                    Spacer()
                    Button("Cancel") { onCancelEdit() }
                        .font(.mlrScaled(12, weight: .semibold))
                        .foregroundStyle(Color.mlrPrimary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }

            // Staged attachments (photos/videos/files), removable before sending.
            if !attachments.isEmpty && !isEditing {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { att in
                            attachmentThumb(att)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                if !isEditing && allowsAttachments {
                    Menu {
                        Button { showPhotoPicker = true } label: { Label("Photo or Video", systemImage: "photo") }
                        Button { showFileImporter = true } label: { Label("File", systemImage: "doc") }
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.mlrScaled(18, weight: .medium))
                            .foregroundStyle(Color.mlrTextMuted)
                            .frame(width: 34, height: 38)
                    }
                }

                MentionTextView(
                    text: $text,
                    height: $height,
                    pendingMention: $pendingMention,
                    onMentionQueryChange: { q in
                        withAnimation(.easeOut(duration: 0.16)) { mentionQuery = q }
                    },
                    onPasteMedia: { items in if allowsAttachments { attachments.append(contentsOf: items) } }
                )
                .frame(height: height)
                .padding(.horizontal, 8)
                .background(Color.mlrSurface)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.mlrBorder, lineWidth: 1))

                Button {
                    Haptics.tap()
                    onSend(attachments)
                    attachments = []
                } label: {
                    Group {
                        if sending {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: isEditing ? "checkmark" : "arrow.up")
                                .font(.mlrScaled(16, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 38, height: 38)
                    .background(canSend ? Color.mlrPrimary : Color.mlrPrimary.opacity(0.4))
                    .clipShape(Circle())
                    .scaleEffect(canSend ? 1 : 0.9)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: canSend)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.mlrSurface)
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems, maxSelectionCount: 5, matching: .any(of: [.images, .videos]))
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadPhotoItems(items) }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            handleFileImport(result)
        }
    }

    // MARK: - Attachment thumbnail

    @ViewBuilder
    private func attachmentThumb(_ att: ChatAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if att.kind == .image, let img = att.preview {
                    Image(uiImage: img).resizable().scaledToFill()
                } else if att.kind == .video {
                    ZStack {
                        Color.mlrCard
                        Image(systemName: "film").font(.mlrScaled(20)).foregroundStyle(Color.mlrTextMuted)
                    }
                } else {
                    VStack(spacing: 2) {
                        Image(systemName: "doc.fill").font(.mlrScaled(18)).foregroundStyle(Color.mlrTextMuted)
                        Text(att.filename).font(.system(size: 8)).lineLimit(1).foregroundStyle(Color.mlrTextMuted)
                    }
                    .padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.mlrCard)
                }
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Button {
                attachments.removeAll { $0.id == att.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.mlrScaled(16))
                    .foregroundStyle(.white, .black.opacity(0.5))
            }
            .padding(2)
        }
    }

    // MARK: - Loading picked media

    @MainActor
    private func loadPhotoItems(_ items: [PhotosPickerItem]) async {
        for item in items {
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            if isVideo {
                attachments.append(ChatAttachment(data: data, filename: "video.mp4", mimeType: "video/mp4", kind: .video, preview: nil))
            } else {
                let img = UIImage(data: data)
                let jpeg = img?.jpegData(compressionQuality: 0.8) ?? data
                attachments.append(ChatAttachment(data: jpeg, filename: "photo.jpg", mimeType: "image/jpeg", kind: .image, preview: img))
            }
        }
        photoItems = []
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { continue }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let kind: ChatAttachment.Kind = mime.hasPrefix("image") ? .image : mime.hasPrefix("video") ? .video : .file
            let preview = kind == .image ? UIImage(data: data) : nil
            attachments.append(ChatAttachment(data: data, filename: url.lastPathComponent, mimeType: mime, kind: kind, preview: preview))
        }
    }
}

// MARK: - Preview

#if DEBUG
struct MentionText_Previews: PreviewProvider {
    static let sampleMembers = [
        Profile.guest,
    ]

    static var previews: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionLabel(text: "MentionText")

            MentionText("Hey @Dorothy, can you grab the paddles?")

            MentionText(
                "Great idea @Leo! @Dorothy and I will handle the fish fry.",
                baseFont: .mlrScaled(15)
            )

            MentionText("No mentions in this string — plain text only.")

            Divider()

            SectionLabel(text: "MentionAutocomplete")
            MentionAutocomplete(
                members: [Profile.guest],
                query: "le",
                onSelect: { _ in }
            )
            .padding(.horizontal)
        }
        .padding(20)
        .previewDisplayName("MentionText")
    }
}
#endif
