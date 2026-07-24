import SwiftUI

// MARK: - LocalPlacesView
// Nearby golf, food & drink, and coffee. Mirrors /local-places on the web:
// collapsible category sections (each a tappable "card"), with per-place quick
// actions — tee-time booking / rates, menu, online order, call, website, and
// Apple Maps directions.

struct LocalPlacesView: View {

    private var golfPlaces: [LocalPlace]   { LocalPlace.all.filter { $0.category == .golf } }
    private var diningPlaces: [LocalPlace] { LocalPlace.all.filter { $0.category == .dining } }
    private var coffeePlaces: [LocalPlace] { LocalPlace.all.filter { $0.category == .coffee } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !golfPlaces.isEmpty {
                    PlacesSection(title: "Golf", emoji: "⛳", places: golfPlaces)
                }
                if !diningPlaces.isEmpty {
                    PlacesSection(title: "Food & Drink", emoji: "🍽️", places: diningPlaces)
                }
                if !coffeePlaces.isEmpty {
                    PlacesSection(title: "Coffee", emoji: "☕", places: coffeePlaces)
                }
            }
            .padding(16)
        }
        .background(Color.mlrSurface)
        .navigationTitle("Local Places")
        .navigationBarTitleDisplayMode(.large)
    }
}

// MARK: - Collapsible section (a tappable category card)

private struct PlacesSection: View {
    let title: String
    let emoji: String
    let places: [LocalPlace]

    @State private var expanded = false

    var body: some View {
        VStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Text(emoji).font(.mlrScaled(20))
                    Text(title)
                        .font(.mlrScaled(17, weight: .bold))
                        .foregroundStyle(Color.mlrText)
                    Text("\(places.count)")
                        .font(.mlrScaled(12, weight: .semibold))
                        .foregroundStyle(Color.mlrTextMuted)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Color.mlrPrimaryLight)
                        .clipShape(Capsule())
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.mlrScaled(13, weight: .semibold))
                        .foregroundStyle(Color.mlrTextSubtle)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .cardStyle()

            if expanded {
                ForEach(places) { place in
                    LocalPlaceCard(place: place)
                }
            }
        }
    }
}

// MARK: - Card

private struct LocalPlaceCard: View {
    let place: LocalPlace

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name)
                    .font(.mlrScaled(16, weight: .semibold))
                    .foregroundStyle(Color.mlrText)
                if let locality = place.address {
                    Text(locality)
                        .font(.mlrScaled(12))
                        .foregroundStyle(Color.mlrTextMuted)
                }
            }

            if let blurb = place.description {
                Text(blurb)
                    .font(.mlrScaled(14))
                    .foregroundStyle(Color.mlrTextMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Quick-action chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    let isGolf = place.category == .golf
                    if place.id == "inshalla" {
                        // Inshalla gets the in-app Tee Times page (quick-book day
                        // chips + call + Daily Deals) — web parity.
                        NavigationLink(destination: TeeTimesView()) {
                            PlaceChip(label: "Tee Times", icon: "calendar")
                        }
                    } else if let raw = place.orderUrl, let url = URL(string: raw) {
                        Link(destination: url) {
                            PlaceChip(label: isGolf ? "Tee Times" : "Order",
                                      icon:  isGolf ? "calendar"  : "cart")
                        }
                    }
                    if let raw = place.ratesUrl, let url = URL(string: raw) {
                        Link(destination: url) { PlaceChip(label: "See Rates", icon: "dollarsign.circle") }
                    }
                    if let raw = place.menuUrl, let url = URL(string: raw) {
                        Link(destination: url) { PlaceChip(label: "Menu", icon: "list.bullet") }
                    }
                    if let phone = place.phone, let url = URL(string: "tel:\(phone)") {
                        Link(destination: url) { PlaceChip(label: "Call", icon: "phone") }
                    }
                    if let raw = place.website, let url = URL(string: raw) {
                        Link(destination: url) { PlaceChip(label: "Website", icon: "safari") }
                    }
                    if let address = place.address {
                        Button {
                            MapsHelper.directions(toAddress: "\(place.name), \(address)")
                        } label: {
                            PlaceChip(label: "Directions", icon: "map")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

// MARK: - Chip

private struct PlaceChip: View {
    let label: String
    let icon: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.mlrScaled(11, weight: .semibold))
            Text(label)
                .font(.mlrScaled(13, weight: .semibold))
        }
        .foregroundStyle(Color.mlrPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.mlrPrimaryLight)
        .clipShape(Capsule())
    }
}
