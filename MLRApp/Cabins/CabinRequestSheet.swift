import SwiftUI

// MARK: - CabinRequestSheet
// Request a cabin stay: pick a cabin, choose check-in/check-out dates,
// set guest count, add a note, submit. Shows a confirmation on success.

struct CabinRequestSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    /// Optional pre-selected cabin.
    var preselected: Cabin?

    @State private var selectedCabin: Cabin?
    @State private var checkIn: Date = .now
    @State private var checkOut: Date = Calendar.current.date(byAdding: .day, value: 2, to: .now) ?? .now
    @State private var guests = 2
    @State private var note = ""
    @State private var selectedRoomIds: Set<UUID> = []
    @State private var notSureYet = false   // skip room pick even when the cabin has rooms
    // Admin book-on-behalf (migration 0087): place a booking under another member,
    // auto-approved, with an optional confirmation email.
    @State private var forUser: Profile?
    @State private var showMemberPicker = false
    @State private var emailForUser = true
    @State private var isSubmitting = false
    @State private var submitError: String?
    @State private var didSubmit = false
    @State private var loadingCabins = true

    // Live availability for the selected date range (cabinId → rooms free).
    @State private var availability: [UUID: Int] = [:]
    @State private var loadingAvailability = false

    private var cabins: [Cabin] { env.cabinService.cabins }
    private var roomAvailability: [CabinRoomAvailability] { env.cabinService.roomAvailability }
    private var hasRooms: Bool { !roomAvailability.isEmpty }

    private var nightCount: Int {
        max(0, Calendar.current.dateComponents([.day], from: checkIn, to: checkOut).day ?? 0)
    }

    // Include cabinId so room availability reloads when the cabin changes.
    private var availabilityKey: String { "\(selectedCabin?.id.uuidString ?? "")|\(checkIn.isoDateString)|\(checkOut.isoDateString)" }

    /// Rooms free in the selected cabin for the chosen dates (nil until loaded).
    private var selectedAvailable: Int? {
        guard let id = selectedCabin?.id else { return nil }
        return availability[id]
    }

    private var canSubmit: Bool {
        guard selectedCabin != nil, nightCount > 0, !isSubmitting else { return false }
        if hasRooms && !notSureYet { return !selectedRoomIds.isEmpty }
        return (selectedAvailable ?? 1) > 0
    }

    var body: some View {
        NavigationStack {
            Group {
                if didSubmit {
                    confirmation
                } else {
                    form
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(didSubmit ? "Request sent" : "Request a Cabin")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(didSubmit ? "Done" : "Cancel") { dismiss() }
                }
                if !didSubmit {
                    ToolbarItem(placement: .confirmationAction) {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Button("Submit") { Task { await submit() } }
                                .fontWeight(.semibold)
                                .disabled(!canSubmit)
                        }
                    }
                }
            }
            .task { await loadCabins() }
            .task(id: availabilityKey) { await loadAvailability() }
            .sheet(isPresented: $showMemberPicker) {
                FestMemberPicker { forUser = $0 }
            }
        }
    }

    // MARK: - Form

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Admin: book on behalf of another member (auto-approved).
                if env.isAdmin {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: "Booking for")
                        Button { showMemberPicker = true } label: {
                            HStack(spacing: 10) {
                                Image(systemName: forUser == nil ? "person.crop.circle.badge.plus" : "person.crop.circle.fill")
                                    .foregroundStyle(Color.mlrPrimary)
                                Text(forUser?.name ?? "Myself")
                                    .foregroundStyle(Color.mlrText)
                                Spacer()
                                if forUser != nil {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(Color.mlrTextSubtle)
                                        .onTapGesture { forUser = nil }
                                } else {
                                    Image(systemName: "chevron.right").font(.mlrScaled(13)).foregroundStyle(Color.mlrTextSubtle)
                                }
                            }
                            .padding(14).background(Color.mlrCard).clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        if forUser != nil {
                            Toggle("Email them a confirmation", isOn: $emailForUser)
                                .font(.mlrScaled(13)).tint(Color.mlrPrimary)
                            Text("Placed under their account and approved right away.")
                                .font(.mlrCaption).foregroundStyle(Color.mlrTextMuted)
                        }
                    }
                }

                // Cabin picker
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "Choose a cabin")
                    if loadingCabins {
                        SkeletonShape(height: 120, cornerRadius: 16)
                    } else if cabins.isEmpty {
                        Text("No cabins available right now.")
                            .font(.mlrCaption)
                            .foregroundStyle(Color.mlrTextMuted)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(cabins) { cabin in
                                    CabinPickCard(
                                        cabin: cabin,
                                        isSelected: selectedCabin?.id == cabin.id,
                                        available: availability[cabin.id]
                                    ) { selectedCabin = cabin }
                                }
                            }
                            .padding(.horizontal, 2)
                        }
                    }
                }

                // Dates
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(text: "Dates")
                    DatePicker("Check-in", selection: $checkIn, displayedComponents: .date)
                        .onChange(of: checkIn) { _, new in
                            if checkOut <= new {
                                checkOut = Calendar.current.date(byAdding: .day, value: 1, to: new) ?? new
                            }
                        }
                    DatePicker("Check-out", selection: $checkOut,
                               in: checkIn..., displayedComponents: .date)
                    HStack {
                        if nightCount > 0 {
                            Text("\(nightCount) night\(nightCount == 1 ? "" : "s")")
                                .font(.mlrScaled(13, weight: .medium))
                                .foregroundStyle(Color.mlrPrimary)
                        }
                        Spacer()
                        Button("All Family Fest days") { pickFamilyFestDates() }
                            .font(.mlrScaled(13, weight: .semibold))
                            .foregroundStyle(Color.mlrFest)
                    }
                    if let available = selectedAvailable {
                        Text(available > 0
                             ? "\(available) room\(available == 1 ? "" : "s") left for these dates"
                             : "No rooms left for these dates")
                            .font(.mlrCaption)
                            .foregroundStyle(available > 0 ? Color.mlrTextMuted : Color.mlrDanger)
                    } else if loadingAvailability {
                        Text("Checking availability…")
                            .font(.mlrCaption)
                            .foregroundStyle(Color.mlrTextMuted)
                    }
                }
                .padding(16)
                .cardStyle()

                // Room picker — shown when the selected cabin has named rooms.
                if hasRooms {
                    VStack(alignment: .leading, spacing: 10) {
                        SectionLabel(text: "Which room(s)?")
                        if !notSureYet {
                            VStack(spacing: 0) {
                                ForEach(roomAvailability) { room in
                                    RoomPickRow(
                                        room: room,
                                        isSelected: selectedRoomIds.contains(room.id),
                                        onToggle: {
                                            if selectedRoomIds.contains(room.id) {
                                                selectedRoomIds.remove(room.id)
                                            } else if room.available {
                                                selectedRoomIds.insert(room.id)
                                            }
                                        }
                                    )
                                    if room.id != roomAvailability.last?.id {
                                        Divider().padding(.leading, 16)
                                    }
                                }
                            }
                            .cardStyle()
                        }

                        // "Not sure yet" — submit without picking a room; an admin
                        // (or you, later) can assign one. Mirrors the web flow.
                        Toggle(isOn: $notSureYet.animation()) {
                            Text("Not sure yet — decide my room later")
                                .font(.mlrScaled(14))
                                .foregroundStyle(Color.mlrText)
                        }
                        .tint(Color.mlrPrimary)
                        .onChange(of: notSureYet) { _, on in
                            if on { selectedRoomIds.removeAll() }
                        }
                    }
                }

                // Guests — only show when no named rooms (rooms imply occupancy)
                if !hasRooms {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel(text: "Guests")
                        Stepper(value: $guests, in: 1...maxGuests) {
                            Text("\(guests) guest\(guests == 1 ? "" : "s")")
                                .foregroundStyle(Color.mlrText)
                        }
                        if let cabin = selectedCabin {
                            Text("Sleeps up to \(cabin.maxGuests ?? 12).")
                                .font(.mlrCaption)
                                .foregroundStyle(Color.mlrTextMuted)
                        }
                    }
                    .padding(16)
                    .cardStyle()
                }

                // Note
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: "Note for the resort (optional)")
                    TextField("Anything we should know?", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                        .fieldStyle()
                }

                if let submitError {
                    Text(submitError)
                        .font(.mlrCaption)
                        .foregroundStyle(Color.mlrDanger)
                }
            }
            .padding(20)
        }
    }

    private var maxGuests: Int {
        selectedCabin?.maxGuests ?? 12
    }

    // MARK: - Confirmation

    private var confirmation: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.mlrScaled(56))
                .foregroundStyle(Color.mlrSuccess)
            Text("Request sent!")
                .font(.mlrScaled(22, weight: .bold))
                .foregroundStyle(Color.mlrText)
            Text("An admin will review your stay and you'll get a notification when it's approved.")
                .font(.mlrBody)
                .foregroundStyle(Color.mlrTextMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Button("Done") { dismiss() }
                .primaryButton()
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data

    private func loadCabins() async {
        loadingCabins = cabins.isEmpty
        if cabins.isEmpty {
            await env.cabinService.fetchCabins()
        }
        if selectedCabin == nil {
            selectedCabin = preselected ?? cabins.first
        }
        loadingCabins = false
    }

    private func loadAvailability() async {
        guard nightCount > 0 else { availability = [:]; return }
        loadingAvailability = true
        defer { loadingAvailability = false }
        let rows = await env.cabinService.fetchAvailability(
            checkIn: checkIn.isoDateString, checkOut: checkOut.isoDateString
        )
        availability = Dictionary(rows.map { ($0.cabinId, $0.available) }, uniquingKeysWith: { a, _ in a })
        // Load per-room availability when a cabin is selected.
        if let cabinId = selectedCabin?.id {
            await env.cabinService.fetchRoomAvailability(
                cabinId: cabinId,
                checkIn: checkIn.isoDateString,
                checkOut: checkOut.isoDateString
            )
            // Clear selected rooms that are no longer available.
            selectedRoomIds = selectedRoomIds.filter { rid in
                env.cabinService.roomAvailability.first { $0.id == rid }?.available ?? false
            }
        } else {
            env.cabinService.roomAvailability = []
        }
    }

    private func pickFamilyFestDates() {
        let iso = DateFormatter()
        iso.dateFormat = "yyyy-MM-dd"
        iso.timeZone = TimeZone(identifier: "America/Chicago")
        guard let start = iso.date(from: FamilyFestConfig.startDate),
              let end = iso.date(from: FamilyFestConfig.endDate),
              let checkoutDay = Calendar.current.date(byAdding: .day, value: 1, to: end)
        else { return }
        withAnimation {
            checkIn = start
            checkOut = checkoutDay
        }
    }

    private func submit() async {
        guard env.isSignedIn else { env.authService.promptSignIn(); return }
        guard let cabin = selectedCabin else { return }
        isSubmitting = true
        submitError = nil
        defer { isSubmitting = false }

        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let roomIds = selectedRoomIds.isEmpty ? nil : Array(selectedRoomIds)
        do {
            let newId = try await env.cabinService.requestStay(
                cabinId: cabin.id,
                checkIn: checkIn.isoDateString,
                checkOut: checkOut.isoDateString,
                guests: guests,
                note: trimmedNote.isEmpty ? nil : trimmedNote,
                roomIds: roomIds,
                forUserId: forUser?.id
            )
            // Book-on-behalf: auto-approve the just-created booking (0087/0104).
            if forUser != nil, let newId {
                try await env.cabinService.approveBooking(bookingId: newId, adminNote: nil, notify: emailForUser)
            }
            if let userId = await env.authService.userId {
                await env.cabinService.fetchMyBookings(userId: userId)
            }
            withAnimation { didSubmit = true }
        } catch {
            submitError = "Couldn't submit your request. Check your connection and try again."
            print("[CabinRequest] submit error: \(error)")
        }
    }
}

// MARK: - Room Pick Row

/// Shared selectable room row (used by the request sheet and the admin edit
/// sheet's room-reassignment section).
struct RoomPickRow: View {
    let room: CabinRoomAvailability
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.mlrScaled(18))
                    .foregroundStyle(isSelected ? Color.mlrPrimary : (room.available ? Color.mlrTextSubtle : Color.mlrDanger))

                VStack(alignment: .leading, spacing: 2) {
                    Text(room.name)
                        .font(.mlrScaled(14, weight: .medium))
                        .foregroundStyle(room.available ? Color.mlrText : Color.mlrTextMuted)
                    Text("\(room.beds) bed\(room.beds == 1 ? "" : "s")")
                        .font(.mlrScaled(12))
                        .foregroundStyle(Color.mlrTextMuted)
                }

                Spacer()

                if !room.active {
                    Text("Closed")
                        .font(.mlrScaled(11, weight: .semibold))
                        .foregroundStyle(Color.mlrDanger)
                } else if !room.available {
                    Text("Booked")
                        .font(.mlrScaled(11, weight: .semibold))
                        .foregroundStyle(Color.mlrWarning)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .opacity(room.available ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!room.available)
    }
}

// MARK: - Cabin Pick Card

private struct CabinPickCard: View {
    let cabin: Cabin
    let isSelected: Bool
    var available: Int? = nil
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    if let urlString = cabin.imageUrl, let url = URL(string: urlString) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFill()
                            default:
                                placeholderImage
                            }
                        }
                    } else {
                        placeholderImage
                    }
                }
                .frame(width: 180, height: 110)
                .clipped()

                VStack(alignment: .leading, spacing: 3) {
                    Text(cabin.name)
                        .font(.mlrScaled(15, weight: .semibold))
                        .foregroundStyle(Color.mlrText)
                    Text("\(cabin.roomCount) rooms · sleeps \(cabin.maxGuests ?? 12)")
                        .font(.mlrScaled(12))
                        .foregroundStyle(Color.mlrTextMuted)
                    if let available {
                        Text(available > 0 ? "\(available) left" : "Full")
                            .font(.mlrScaled(11, weight: .semibold))
                            .foregroundStyle(available > 0 ? Color.mlrSuccess : Color.mlrDanger)
                    }
                }
                .frame(width: 180, alignment: .leading)
                .padding(10)
            }
            .background(Color.mlrCard)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? Color.mlrPrimary : Color.clear, lineWidth: 2.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var placeholderImage: some View {
        Color.mlrPrimaryLight
            .overlay(
                Image(systemName: "house.fill")
                    .font(.mlrScaled(30))
                    .foregroundStyle(Color.mlrPrimary)
            )
    }
}
