import SwiftUI

// MARK: - HouseStayDetail
// A stay's details: dates, who's coming (the member + everyone they added), and
// any note. The author (or an admin) gets Edit + Cancel controls.

struct HouseStayDetail: View {
    @Environment(\.dismiss) private var dismiss

    let stay: HouseStay
    let canEdit: Bool
    let onEdit: () -> Void
    let onDelete: () async -> Void

    @State private var confirmingDelete = false
    @State private var deleting = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("🏡 \(stay.label)").font(.mlrScaled(20, weight: .bold))
                        Text(stay.dateRangeLabel).font(.mlrBody).foregroundStyle(Color.mlrTextMuted)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("WHO'S COMING (\(stay.headCount))")
                            .font(.mlrScaled(11, weight: .bold)).foregroundStyle(Color.mlrTextSubtle)
                        HStack(spacing: 10) {
                            AvatarView(url: stay.authorAvatarUrl, size: .small)
                            Text(stay.authorName).font(.mlrScaled(15, weight: .semibold)).foregroundStyle(Color.mlrText)
                            Text("organizing").font(.mlrCaption).foregroundStyle(Color.mlrTextSubtle)
                        }
                        if !stay.guestNames.isEmpty {
                            FlowChips(items: stay.guestNames)
                        }
                    }

                    if let note = stay.note, !note.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("NOTES").font(.mlrScaled(11, weight: .bold)).foregroundStyle(Color.mlrTextSubtle)
                            Text(note).font(.mlrBody).foregroundStyle(Color.mlrText)
                        }
                    }

                    if canEdit {
                        VStack(spacing: 10) {
                            Button { onEdit() } label: {
                                Text("Edit").font(.mlrScaled(15, weight: .semibold))
                                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                                    .background(Color.mlrPrimary).foregroundStyle(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                            Button(role: .destructive) { confirmingDelete = true } label: {
                                Text(deleting ? "Removing…" : "Cancel this stay")
                                    .font(.mlrScaled(15, weight: .semibold))
                                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                            }
                            .disabled(deleting)
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(20)
            }
            .background(Color.mlrSurface)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Cancel this stay?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Cancel stay", role: .destructive) {
                    Task { deleting = true; await onDelete(); dismiss() }
                }
                Button("Keep it", role: .cancel) {}
            }
        }
    }
}

// MARK: - HouseDaySheet
// A single day's roster — who's up + which resort event falls that day.

struct HouseDaySheet: View {
    @Environment(\.dismiss) private var dismiss

    let day: String
    let stays: [HouseStay]
    /// ⚠️ Everyone here on this day — real stays AND people derived from event
    /// RSVPs, from the one shared `HousePresence.occupants`. This sheet used to
    /// count `stays` alone and say "STAYING (0) · Nobody's marked a stay for
    /// this day yet" while the agenda on the screen behind it listed five people
    /// for the same date.
    let occupants: [DayOccupant]
    let events: [ResortEvent]
    let onOpenStay: (HouseStay) -> Void
    let onOpenEvent: (ResortEvent) -> Void
    let onAdd: () -> Void

    private var heading: String {
        guard let d = HouseStay.iso.date(from: day) else { return day }
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        f.timeZone = TimeZone(identifier: "America/Chicago")
        return f.string(from: d)
    }

    /// Says HOW someone is here, which is different for each of the four cases —
    /// a real stay, a member RSVP'd to an event, an account-less housemate a
    /// host added, and someone's guest.
    private func subtitle(for person: DayOccupant, stay: HouseStay?) -> String {
        if let stay {
            return stay.headCount > 1
                ? "\(stay.authorName) · \(stay.headCount) people"
                : stay.authorName
        }
        let reason = person.eventTitle.map { "for \($0)" } ?? "coming up"
        switch person.via {
        case .guest:
            return person.sponsorName.map { "Guest of \($0) · \(reason)" } ?? "Guest · \(reason)"
        case .roster:
            return "Not on the app · \(reason)"
        default:
            return reason.prefix(1).uppercased() + reason.dropFirst()
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !events.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("RESORT EVENTS").font(.mlrScaled(11, weight: .bold)).foregroundStyle(Color.mlrTextSubtle)
                            ForEach(events) { e in
                                Button { onOpenEvent(e) } label: {
                                    HStack(spacing: 8) {
                                        Text(e.emoji ?? "🌲")
                                        Text(e.title).font(.mlrScaled(15, weight: .medium)).foregroundStyle(Color.mlrText)
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.mlrScaled(12)).foregroundStyle(Color.mlrTextSubtle)
                                    }
                                    .padding(12).cardStyle()
                                }
                                .buttonStyle(.pressable)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("STAYING (\(occupants.count))").font(.mlrScaled(11, weight: .bold)).foregroundStyle(Color.mlrTextSubtle)
                        if occupants.isEmpty {
                            Text("Nobody's marked a stay for this day yet.")
                                .font(.mlrBody).foregroundStyle(Color.mlrTextMuted)
                        } else {
                            ForEach(occupants) { person in
                                let stay = person.isImplied
                                    ? nil
                                    : stays.first { "stay:\($0.id.uuidString)" == person.id }
                                Button {
                                    // A derived row has no `house_stays` row to
                                    // open — it isn't editable or deletable, so
                                    // it deliberately isn't tappable either.
                                    if let stay { onOpenStay(stay) }
                                } label: {
                                    HStack(spacing: 10) {
                                        AvatarView(url: person.avatarUrl, size: .small)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(stay?.label ?? person.name)
                                                .font(.mlrScaled(15, weight: .medium))
                                                .foregroundStyle(Color.mlrText)
                                            Text(subtitle(for: person, stay: stay))
                                                .font(.mlrCaption).foregroundStyle(Color.mlrTextSubtle)
                                        }
                                        Spacer()
                                    }
                                    .padding(12).cardStyle()
                                }
                                .buttonStyle(.pressable)
                                .disabled(stay == nil)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .background(Color.mlrSurface)
            .navigationTitle(heading)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { onAdd() } label: { Image(systemName: "plus") }
                }
            }
        }
    }
}

// MARK: - FlowChips
// A simple wrapping row of pill chips (guest names). Uses a lightweight flow
// layout so any number of names wrap cleanly.

private struct FlowChips: View {
    let items: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, name in
                Text(name)
                    .font(.mlrCaption)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.mlrGroupedCard)
                    .foregroundStyle(Color.mlrText)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.mlrBorder, lineWidth: 1))
            }
        }
    }
}

// A minimal flow layout (iOS 16+) so chips wrap without a dependency.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x - bounds.minX + size.width > maxWidth && x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
