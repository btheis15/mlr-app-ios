import SwiftUI
import Kingfisher

// MARK: - Avatar Size

enum AvatarSize {
    case small    // 32pt — inline mentions, compact rows
    case medium   // 44pt — list rows, chat bubbles
    case large    // 80pt — member sheets, profile headers
    case xlarge   // 120pt — full profile page top

    var points: CGFloat {
        switch self {
        case .small:   return 32
        case .medium:  return 44
        case .large:   return 80
        case .xlarge:  return 120
        }
    }

    var iconSize: CGFloat {
        switch self {
        case .small:   return 14
        case .medium:  return 20
        case .large:   return 36
        case .xlarge:  return 54
        }
    }

    /// Thickness of the admin ring
    var ringWidth: CGFloat { 2 }

    /// Gap between the image edge and the ring stroke (visual breathing room)
    var ringPadding: CGFloat { 2 }
}

// MARK: - AvatarView

/// Loads a member avatar from a URL string.
/// Falls back to a `person.fill` system image on nil URL or load failure.
/// Draws a 2pt `mlrPrimary` ring for admins.
///
/// Usage:
///   AvatarView(url: profile.avatarUrl, size: .medium, isAdmin: profile.isAdmin)
struct AvatarView: View {
    let url: String?
    var size: AvatarSize = .medium
    var isAdmin: Bool = false

    private var diameter: CGFloat { size.points }
    private var totalDiameter: CGFloat {
        isAdmin ? diameter + (size.ringPadding + size.ringWidth) * 2 : diameter
    }

    var body: some View {
        ZStack {
            avatarCircle
                // Admin ring: drawn as an overlay stroke slightly outside the circle
                .overlay(
                    Circle()
                        .stroke(Color.mlrPrimary, lineWidth: isAdmin ? size.ringWidth : 0)
                        .padding(-size.ringPadding)
                )
        }
        .frame(width: totalDiameter, height: totalDiameter)
        // Decorative: a member's name is always shown alongside the avatar,
        // so hiding it keeps VoiceOver from announcing a redundant image.
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var avatarCircle: some View {
        if let urlString = url, let imageUrl = URL(string: urlString) {
            // Kingfisher: memory + disk cached, downsampled to the display size, so
            // avatars don't re-download on every scroll (unlike AsyncImage).
            KFImage(imageUrl)
                .placeholder { fallbackCircle }
                .setProcessor(DownsamplingImageProcessor(
                    size: CGSize(width: diameter * 3, height: diameter * 3)))
                .scaleFactor(UIScreen.main.scale)
                .cacheOriginalImage()
                .fade(duration: 0.2)
                .resizable()
                .scaledToFill()
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
        } else {
            fallbackCircle
        }
    }

    private var fallbackCircle: some View {
        Circle()
            .fill(Color.mlrPrimaryLight)
            .frame(width: diameter, height: diameter)
            .overlay(
                Image(systemName: "person.fill")
                    .font(.mlrScaled(size.iconSize))
                    .foregroundStyle(Color.mlrPrimary)
            )
    }
}

// MARK: - Convenience initialisers

extension AvatarView {
    /// Convenience init from a `Profile` model.
    init(profile: Profile, size: AvatarSize = .medium) {
        self.url = profile.avatarUrl
        self.size = size
        self.isAdmin = profile.isAdmin
    }
}

// MARK: - Preview

#if DEBUG
struct AvatarView_Previews: PreviewProvider {
    static var previews: some View {
        HStack(spacing: 20) {
            // No URL — fallback
            AvatarView(url: nil, size: .small)
            AvatarView(url: nil, size: .medium)
            AvatarView(url: nil, size: .large)
            // Admin ring
            AvatarView(url: nil, size: .medium, isAdmin: true)
            // Real URL (requires network in preview)
            AvatarView(
                url: "https://i.pravatar.cc/150?img=3",
                size: .large,
                isAdmin: true
            )
        }
        .padding()
        .previewDisplayName("AvatarView")
    }
}
#endif
