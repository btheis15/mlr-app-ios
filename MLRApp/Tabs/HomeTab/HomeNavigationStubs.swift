import SwiftUI
import MapKit
import CoreLocation
import Kingfisher

// MARK: - LocalPlacesView
// Nearby golf, food & drink, coffee and anything else the admins add. Backed by
// the `local_places` table (LocalPlacesService); falls back to the in-code list
// when the table cannot be read. These are third-party businesses near the
// resort: nothing here is the resort's own address, wifi or check-in info.

extension LocalPlace {
    var accentColor: Color { Self.color(forAccent: accent) }
    static func color(forAccent accent: String) -> Color {
        switch accent {
        case "lake": return .mlrLake
        case "campfire": return .mlrCampfire
        case "sun": return .mlrSun
        case "dusk": return .mlrDusk
        default: return .mlrPrimary
        }
    }
    static let accentNames = ["primary", "lake", "campfire", "sun", "dusk"]
}

struct LocalPlacesView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var search = ""
    @State private var editing: LocalPlace?
    @State private var adding = false

    private var service: LocalPlacesService { env.localPlacesService }
    private var canEdit: Bool { env.isAdmin && service.isEditable }

    private var filtered: [LocalPlace] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return service.visiblePlaces }
        return service.visiblePlaces.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || ($0.category ?? "").localizedCaseInsensitiveContains(q)
                || ($0.blurb ?? "").localizedCaseInsensitiveContains(q)
        }
    }

    /// Golf, food, coffee first (in that order), then other groups A to Z.
    private var sections: [(group: String, places: [LocalPlace])] {
        let grouped = Dictionary(grouping: filtered, by: \.placeGroup)
        let known = LocalPlace.knownGroups.filter { grouped[$0] != nil }
        let others = grouped.keys.filter { !LocalPlace.knownGroups.contains($0) }.sorted()
        return (known + others).map { g in
            (g, (grouped[g] ?? []).sorted { $0.position < $1.position })
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if env.isAdmin && service.hasLoaded && !service.isEditable {
                    Label("Editing becomes available once the database update is applied. Showing the built-in list for now.",
                          systemImage: "info.circle")
                        .font(.mlrScaled(13))
                        .foregroundStyle(Color.mlrTextMuted)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardStyle()
                }

                if !service.hasLoaded {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else if service.visiblePlaces.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "mappin.slash").font(.mlrScaled(30)).foregroundStyle(Color.mlrTextSubtle)
                        Text("No local places yet").font(.mlrScaled(16, weight: .semibold)).foregroundStyle(Color.mlrText)
                        Text("Nearby spots will show up here once they are added.")
                            .font(.mlrScaled(13)).foregroundStyle(Color.mlrTextMuted)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 40)
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                }

                ForEach(sections, id: \.group) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text(LocalPlace.groupEmoji(section.group)).font(.mlrScaled(20))
                            Text(LocalPlace.groupTitle(section.group))
                                .font(.mlrSectionTitle)
                                .foregroundStyle(Color.mlrText)
                            Text("\(section.places.count)")
                                .font(.mlrScaled(12, weight: .semibold))
                                .foregroundStyle(Color.mlrTextMuted)
                                .contentTransition(.numericText())
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(Color.mlrPrimaryLight, in: Capsule())
                        }
                        .accessibilityAddTraits(.isHeader)
                        .padding(.top, 6)

                        ForEach(section.places) { place in
                            LocalPlaceCard(place: place,
                                           onEdit: canEdit ? { editing = place } : nil)
                        }
                    }
                }

                if canEdit {
                    Button { adding = true; Haptics.tap() } label: {
                        Label("Add a place", systemImage: "plus.circle.fill")
                            .font(.mlrScaled(15, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.pressable)
                    .foregroundStyle(Color.mlrPrimary)
                    .cardStyle()
                    .padding(.top, 4)
                }
            }
            .padding(16)
        }
        .mlrBackdrop()
        .navigationTitle("Local Places")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $search, prompt: "Search places")
        .task { await service.load(env: env) }
        .refreshable { await service.load(env: env) }
        .sheet(item: $editing) { place in
            LocalPlaceEditor(place: place, isNew: false)
        }
        .sheet(isPresented: $adding) {
            LocalPlaceEditor(place: .blank(group: LocalPlace.knownGroups[1]), isNew: true)
        }
    }
}

// MARK: - Card

struct LocalPlaceCard: View {
    let place: LocalPlace
    var onEdit: (() -> Void)? = nil

    private var accent: Color { place.accentColor }

    private func nonEmpty(_ s: String?) -> String? {
        let t = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? nil : t
    }

    private func url(_ s: String?) -> URL? { nonEmpty(s).flatMap { URL(string: $0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let photo = url(place.imageUrl) {
                KFImage(photo)
                    .resizable().scaledToFill()
                    .frame(height: 150).frame(maxWidth: .infinity)
                    .clipped()
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    if url(place.imageUrl) == nil {
                        IconTile(emoji: place.displayEmoji, accent: accent, size: 48)
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        if let cat = nonEmpty(place.category) {
                            Eyebrow(cat, color: accent)
                        }
                        HStack(spacing: 6) {
                            Text(place.name.isEmpty ? "Name" : place.name)
                                .font(.system(.title3, weight: .semibold))
                                .foregroundStyle(Color.mlrText)
                            if !place.isActive {
                                Text("Hidden")
                                    .font(.mlrScaled(10, weight: .bold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.mlrWarning.opacity(0.18), in: Capsule())
                                    .foregroundStyle(Color.mlrWarning)
                            }
                        }
                        if let loc = nonEmpty(place.locality) {
                            Label(loc, systemImage: "mappin.and.ellipse")
                                .font(.mlrSecondary)
                                .foregroundStyle(Color.mlrTextMuted)
                        }
                    }
                    Spacer(minLength: 0)
                    if let onEdit {
                        Button(action: onEdit) {
                            Image(systemName: "pencil.circle.fill")
                                .font(.mlrScaled(24))
                                .foregroundStyle(Color.mlrPrimary)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.pressable)
                        .accessibilityLabel("Edit \(place.name)")
                        .padding(.top, -8).padding(.trailing, -8)
                    }
                }

                if let blurb = nonEmpty(place.blurb) {
                    Text(blurb)
                        .font(.mlrSecondary)
                        .foregroundStyle(Color.mlrTextMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                actions
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mlrCard(.plain, padding: 0)
        .opacity(place.isActive ? 1 : 0.7)
        .contextMenu {
            if let phone = nonEmpty(place.phoneDisplay) ?? nonEmpty(place.phoneTel) {
                Button { UIPasteboard.general.string = phone; Haptics.success() } label: {
                    Label("Copy phone", systemImage: "phone")
                }
            }
            if let addr = nonEmpty(place.address) {
                Button { UIPasteboard.general.string = addr; Haptics.success() } label: {
                    Label("Copy address", systemImage: "mappin")
                }
            }
            ShareLink(item: shareText) { Label("Share", systemImage: "square.and.arrow.up") }
        }
    }

    private var shareText: String {
        [place.name, nonEmpty(place.address) ?? nonEmpty(place.locality),
         nonEmpty(place.phoneDisplay), nonEmpty(place.website)]
            .compactMap { $0 }.joined(separator: "\n")
    }

    @ViewBuilder private var actions: some View {
        let hasAny = nonEmpty(place.internalHref) == "/tee-times" || url(place.bookingUrl) != nil
            || url(place.ratesUrl) != nil || url(place.orderUrl) != nil || url(place.menuUrl) != nil
            || nonEmpty(place.phoneTel) != nil || url(place.website) != nil
            || nonEmpty(place.address) != nil || nonEmpty(place.locality) != nil
        if hasAny {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if nonEmpty(place.internalHref) == "/tee-times" {
                        // In-app hand-off to the Tee Times page.
                        NavigationLink(destination: TeeTimesView()) {
                            PlaceChip(label: nonEmpty(place.internalCta) ?? "Tee Times", icon: "calendar")
                        }
                    }
                    if let u = url(place.bookingUrl) {
                        Link(destination: u) {
                            PlaceChip(label: nonEmpty(place.bookingCta) ?? "Book tee time", icon: "calendar")
                        }
                    }
                    if let u = url(place.ratesUrl) {
                        Link(destination: u) {
                            PlaceChip(label: nonEmpty(place.ratesCta) ?? "See rates", icon: "dollarsign.circle")
                        }
                    }
                    if let u = url(place.orderUrl) {
                        Link(destination: u) { PlaceChip(label: "Order", icon: "cart") }
                    }
                    if let u = url(place.menuUrl) {
                        Link(destination: u) { PlaceChip(label: "Menu", icon: "list.bullet") }
                    }
                    if let tel = nonEmpty(place.phoneTel), let u = URL(string: "tel:\(tel)") {
                        Link(destination: u) { PlaceChip(label: "Call", icon: "phone") }
                    }
                    if let u = url(place.website) {
                        Link(destination: u) { PlaceChip(label: "Website", icon: "safari") }
                    }
                    if nonEmpty(place.address) != nil || nonEmpty(place.locality) != nil {
                        Button { Self.openDirections(place) } label: {
                            PlaceChip(label: "Directions", icon: "map")
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }
        }
    }

    /// Apple Maps via MKMapItem from the address; a name + locality query when
    /// there is no address (or it cannot be resolved).
    static func openDirections(_ place: LocalPlace) {
        let addr = place.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let loc = place.locality?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallback = [place.name, loc.isEmpty ? nil : loc].compactMap { $0 }.joined(separator: ", ")
        guard !addr.isEmpty else { MapsHelper.directions(toAddress: fallback); return }
        Task { @MainActor in
            if let mark = try? await CLGeocoder().geocodeAddressString(addr).first {
                let item = MKMapItem(placemark: MKPlacemark(placemark: mark))
                item.name = place.name
                item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
            } else {
                MapsHelper.directions(toAddress: "\(place.name), \(addr)")
            }
        }
    }
}

// MARK: - Chip

private struct PlaceChip: View {
    let label: String
    let icon: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.mlrScaled(13, weight: .semibold))
            Text(label)
                .font(.mlrScaled(14, weight: .semibold))
        }
        .foregroundStyle(Color.mlrPrimary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.mlrPrimary.opacity(0.10))
        .clipShape(Capsule())
    }
}
