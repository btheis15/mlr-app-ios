import SwiftUI
import Kingfisher

// MARK: - FestScheduleDetailView

struct FestScheduleDetailView: View {
    private let initialItem: ScheduleItem
    @Environment(AppEnvironment.self) private var env
    @State private var showEditSheet = false
    @State private var showLightbox = false

    init(item: ScheduleItem) { initialItem = item }

    /// The live row: after an edit the service reloads, and this screen shows the
    /// new values at once instead of the snapshot it was pushed with.
    private var item: ScheduleItem {
        env.festContentService.schedule.first { $0.id == initialItem.id } ?? initialItem
    }

    /// Same predicate as web's Edit button and EventSignupSection's canManage:
    /// admin/fest-editor OR this item's own lead/crew (hidden while previewing).
    private var canManage: Bool { env.canEditFestEvent(item) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // Photo banner
                if let url = item.imageUrl.flatMap(URL.init(string:)) {
                    KFImage(url)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 200)
                        .clipped()
                        .contentShape(Rectangle())
                        .onTapGesture { showLightbox = true }
                        .accessibilityLabel("\(item.title) photo")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("Opens the photo full screen")
                }

                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title)
                        .font(.festSerif(26, weight: .bold))
                        .foregroundStyle(Color.mlrFestReadable)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 16) {
                        Label(item.day, systemImage: "calendar")
                            .font(.mlrScaled(14))
                            .foregroundStyle(Color.mlrFest.opacity(0.7))
                        Label(MLRFormat.time(item.time), systemImage: "clock")
                            .font(.mlrScaled(14))
                            .foregroundStyle(Color.mlrFest.opacity(0.7))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 20)

                Divider()
                    .background(Color.mlrFest.opacity(0.15))

                // Location
                if let location = item.location {
                    DetailSection(icon: "mappin.and.ellipse", title: "Location") {
                        if env.isSignedIn {
                            Text(location)
                                .font(.mlrScaled(15))
                                .foregroundStyle(Color.mlrFest.opacity(0.85))
                        } else {
                            ProtectedField(message: "Sign in to see location")
                        }
                    }

                    Divider()
                        .background(Color.mlrFest.opacity(0.15))
                }

                // Description
                if let description = item.description {
                    DetailSection(icon: "text.alignleft", title: "About") {
                        Text(description)
                            .font(.mlrScaled(15))
                            .foregroundStyle(Color.mlrText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()
                        .background(Color.mlrFest.opacity(0.15))
                }

                // What to bring
                if let bring = item.bring {
                    DetailSection(icon: "bag.fill", title: "What to bring") {
                        Text(bring)
                            .font(.mlrScaled(15))
                            .foregroundStyle(Color.mlrText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider().background(Color.mlrFest.opacity(0.15))
                }

                // Links (migration 0142) — e.g. a sign-up form + a separate info doc.
                // Ordered ahead of Leads to match web's FestScheduleDetail (links →
                // signup → tournament → lead/contact last).
                if !item.links.isEmpty {
                    DetailSection(icon: "link", title: "Links") {
                        ScheduleLinkButtons(links: item.links)
                    }
                    Divider().background(Color.mlrFest.opacity(0.15))
                }

                // Sign-ups (migrations 0135/0136/0143) — self-hides when disabled.
                if item.signupEnabled {
                    EventSignupSection(item: item)
                    Divider().background(Color.mlrFest.opacity(0.15))
                }

                // Tournament (migrations 0144–0154) — self-hides when disabled.
                if item.tournamentEnabled {
                    TournamentEntryCard(item: item, canManage: canManage)
                        .padding(.horizontal, 20).padding(.vertical, 16)
                    Divider().background(Color.mlrFest.opacity(0.15))
                }

                // Leads — last, matching web's "In charge" contact card position.
                if !item.leads.isEmpty {
                    DetailSection(icon: "person.fill", title: "Leads") {
                        if env.isSignedIn {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(item.leads, id: \.self) { lead in
                                    LeadRow(name: lead)
                                }
                            }
                        } else {
                            ProtectedField(message: "Sign in to see leads & contacts")
                        }
                    }
                }

                Spacer(minLength: 32)
            }
        }
        .background(Color.mlrFestParchment.ignoresSafeArea())
        .mlrEditToggle(canEdit: canManage)
        .navigationTitle(item.day)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.mlrFestParchment, for: .navigationBar)
        .toolbar {
            if canManage {
                ToolbarItem(placement: .topBarTrailing) {
                    EditPencil("event", tint: .mlrFest) { showEditSheet = true }
                }
            }
        }
        .task { if env.isSignedIn && !env.isPreviewing { _ = await env.festContentService.canEditFest() } }
        .sheet(isPresented: $showEditSheet) {
            FestScheduleEditSheet(item: item) { await env.festContentService.reload() }
        }
        .fullScreenCover(isPresented: $showLightbox) {
            if let url = item.imageUrl { LightboxView(imageUrl: url) }
        }
    }
}

// MARK: - Detail Section Wrapper

/// Shared section wrapper (icon + uppercase label) used by the schedule/dinner
/// detail views and the inline expandable Fest rows.
struct DetailSection<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.mlrScaled(12, weight: .semibold))
                    .foregroundStyle(Color.mlrFest.opacity(0.6))
                Text(title.uppercased())
                    .font(.mlrScaled(11, weight: .semibold))
                    .foregroundStyle(Color.mlrFest.opacity(0.6))
                    .tracking(0.8)
            }
            content()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }
}

// MARK: - Schedule link buttons (migration 0142)

/// Renders a schedule event's ordered links as tappable buttons — e.g. a
/// sign-up form and a separate info doc as two distinct pills.
struct ScheduleLinkButtons: View {
    let links: [ScheduleLink]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(links) { link in
                if let url = URL(string: link.href) {
                    Link(destination: url) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.mlrScaled(13, weight: .semibold))
                            Text(link.display)
                                .font(.mlrScaled(14, weight: .semibold))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                        }
                        .foregroundStyle(Color.mlrFestReadable)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.mlrFest.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
        }
    }
}

// MARK: - Lead Row

struct LeadRow: View {
    let name: String

    var body: some View {
        HStack(spacing: 12) {
            // Avatar placeholder
            Circle()
                .fill(Color.mlrFest.opacity(0.15))
                .frame(width: 36, height: 36)
                .overlay(
                    Text(String(name.prefix(1)).uppercased())
                        .font(.mlrScaled(15, weight: .bold))
                        .foregroundStyle(Color.mlrFestReadable)
                )

            Text(name)
                .font(.mlrScaled(15, weight: .medium))
                .foregroundStyle(Color.mlrFestReadable)

            Spacer()

            // Contact buttons
            HStack(spacing: 8) {
                Button {
                    // Phone action — requires real phone data from profiles
                } label: {
                    Image(systemName: "phone.fill")
                        .font(.mlrScaled(13))
                        .foregroundStyle(Color.mlrFestReadable)
                        .padding(8)
                        .background(Color.mlrFest.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.pressable)

                Button {
                    // Message action
                } label: {
                    Image(systemName: "message.fill")
                        .font(.mlrScaled(13))
                        .foregroundStyle(Color.mlrFestReadable)
                        .padding(8)
                        .background(Color.mlrFest.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.pressable)
            }
        }
    }
}

// MARK: - Protected Field

struct ProtectedField: View {
    let message: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.mlrScaled(12))
            Text(message)
                .font(.mlrScaled(14))
        }
        .foregroundStyle(Color.mlrFest.opacity(0.5))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.mlrFest.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - ExpandableScheduleRow
//
// A schedule item that shows its gist collapsed (time • title • location hint)
// and expands IN PLACE to the full detail (location, about, leads) — reusing the
// DetailSection / LeadRow / ProtectedField above so the inline and pushed views
// never drift. Animation is gated on Reduce Motion and a selection haptic fires
// on toggle, matching the app's AttendanceControl idiom.

struct ExpandableScheduleRow: View {
    let item: ScheduleItem
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var showEditSheet = false

    /// Web's rule: full editor, or this event's lead/crew (migration 0110). Hidden while previewing.
    private var canEditItem: Bool { env.canEditFestEvent(item) }

    private var hasDetail: Bool {
        (item.description?.isEmpty == false) || item.location != nil || !item.leads.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggle) { header }
                .buttonStyle(.pressable)
                .disabled(!hasDetail && !canEditItem)

            if isExpanded { expanded }
        }
        .background(Color.mlrFestCard)
        .sensoryFeedback(.selection, trigger: isExpanded)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(hasDetail ? "Double tap to \(isExpanded ? "collapse" : "expand") details" : "")
        .sheet(isPresented: $showEditSheet) {
            FestScheduleEditSheet(item: item) {
                await env.festContentService.reload()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(MLRFormat.time(item.time))
                .font(.mlrScaled(14, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.mlrFestInk.opacity(0.6))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(width: 78, alignment: .leading)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.festSerif(18, weight: .bold))
                    .foregroundStyle(Color.mlrFestReadable)
                    .multilineTextAlignment(.leading)

                if let location = item.location, !isExpanded {
                    if env.isSignedIn {
                        Label(location, systemImage: "mappin.and.ellipse")
                            .font(.mlrScaled(14))
                            .foregroundStyle(Color.mlrFest.opacity(0.6))
                            .lineLimit(1)
                    } else {
                        Label("Sign in to see location", systemImage: "lock.fill")
                            .font(.mlrScaled(12))
                            .foregroundStyle(Color.mlrFest.opacity(0.4))
                    }
                }
            }

            Spacer(minLength: 8)

            if hasDetail {
                Image(systemName: "chevron.right")
                    .font(.mlrScaled(12, weight: .semibold))
                    .foregroundStyle(Color.mlrFest.opacity(0.4))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var expanded: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let url = item.imageUrl.flatMap(URL.init(string:)) {
                KFImage(url)
                    .resizable().scaledToFill()
                    .frame(maxWidth: .infinity).frame(height: 150).clipped()
            }
            if let location = item.location {
                Divider().background(Color.mlrFest.opacity(0.12))
                DetailSection(icon: "mappin.and.ellipse", title: "Location") {
                    if env.isSignedIn {
                        Text(location)
                            .font(.mlrScaled(15))
                            .foregroundStyle(Color.mlrFest.opacity(0.85))
                    } else {
                        ProtectedField(message: "Sign in to see location")
                    }
                }
            }

            if let description = item.description, !description.isEmpty {
                Divider().background(Color.mlrFest.opacity(0.12))
                DetailSection(icon: "text.alignleft", title: "About") {
                    Text(description)
                        .font(.mlrScaled(15))
                        .foregroundStyle(Color.mlrText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let bring = item.bring, !bring.isEmpty {
                Divider().background(Color.mlrFest.opacity(0.12))
                DetailSection(icon: "bag.fill", title: "What to bring") {
                    Text(bring)
                        .font(.mlrScaled(15))
                        .foregroundStyle(Color.mlrText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Links → signup → tournament → leads, matching web's
            // FestScheduleDetail/FestWeek ordering (lead/contact renders last).
            if !item.links.isEmpty {
                Divider().background(Color.mlrFest.opacity(0.12))
                DetailSection(icon: "link", title: "Links") {
                    ScheduleLinkButtons(links: item.links)
                }
            }

            if item.signupEnabled {
                Divider().background(Color.mlrFest.opacity(0.12))
                EventSignupSection(item: item)
            }

            if item.tournamentEnabled {
                Divider().background(Color.mlrFest.opacity(0.12))
                TournamentEntryCard(item: item, canManage: canEditItem)
                    .padding(.horizontal, 20).padding(.vertical, 16)
            }

            // Leads — last, matching web's "In charge" contact card position.
            if !item.leads.isEmpty {
                Divider().background(Color.mlrFest.opacity(0.12))
                DetailSection(icon: "person.fill", title: "Leads") {
                    if env.isSignedIn {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(item.leads, id: \.self) { lead in
                                LeadRow(name: lead)
                            }
                        }
                    } else {
                        ProtectedField(message: "Sign in to see leads & contacts")
                    }
                }
            }

            if canEditItem {
                Divider().background(Color.mlrFest.opacity(0.12))
                Button { showEditSheet = true } label: {
                    Label("Edit event", systemImage: "pencil")
                        .font(.mlrScaled(13, weight: .medium))
                        .foregroundStyle(Color.mlrFestReadable)
                }
                .buttonStyle(.pressable)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    private func toggle() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { isExpanded.toggle() }
    }
}

// MARK: - ExpandableDinnerRow
//
// That night's dinner, rendered inline at the bottom of a day. Collapsed shows
// the chef + served time; expanded reveals chef, menu, location, and crew —
// reusing the same DetailSection layout as FestDinnersDetailView.

struct ExpandableDinnerRow: View {
    let dinner: FestDinner
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var showEditSheet = false
    @State private var showCrewSheet = false

    private var canEditDinner: Bool {
        env.canEditFestDinner(chefUserId: dinner.chefUserId, crewUserIds: dinner.crewUserIds)
    }

    /// Full editors assign crew inside their editor; a head chef without full
    /// rights keeps the separate crew sheet (existing behaviour, not widened).
    private var canManageCrew: Bool {
        guard env.isSignedIn, !env.isPreviewing, !env.isFullFestEditor,
              let uid = env.currentProfile?.id else { return false }
        return dinner.chefUserId == uid
    }

    /// "Head chef — what's on the menu" (menu omitted while still TBD).
    private var chefMenuLine: String {
        let menu = dinner.menuLines.joined(separator: ", ")
        return menu.isEmpty || dinner.menu == "TBD" ? dinner.chef : "\(dinner.chef) — \(menu)"
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggle) { header }
                .buttonStyle(.pressable)

            if isExpanded { expanded }
        }
        .sensoryFeedback(.selection, trigger: isExpanded)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint("Double tap to \(isExpanded ? "collapse" : "expand") the dinner")
        .sheet(isPresented: $showEditSheet) {
            FestDinnerEditSheet(dinner: dinner, onSaved: { await env.festContentService.reload() })
        }
        .sheet(isPresented: $showCrewSheet) {
            FestCrewAssignSheet(dinner: dinner, onSaved: { await env.festContentService.reload() })
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            // Serving time in the left column, exactly like every other event row.
            Text(MLRFormat.time(dinner.time))
                .font(.mlrScaled(14, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.mlrFestInk.opacity(0.6))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .frame(width: 78, alignment: .leading)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text("Dinner")
                    .font(.festSerif(18, weight: .bold))
                    .foregroundStyle(Color.mlrFestReadable)
                // Head chef — what's on the menu.
                Text(chefMenuLine)
                    .font(.mlrScaled(14))
                    .foregroundStyle(Color.mlrFestInk.opacity(0.7))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.mlrScaled(12, weight: .semibold))
                .foregroundStyle(Color.mlrFest.opacity(0.4))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var expanded: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().background(Color.mlrFest.opacity(0.12))
            DetailSection(icon: "person.fill", title: "Chef") {
                Text(dinner.chef)
                    .font(.mlrScaled(15, weight: .medium))
                    .foregroundStyle(Color.mlrFestReadable)
            }

            if !dinner.menuLines.isEmpty {
                Divider().background(Color.mlrFest.opacity(0.12))
                DetailSection(icon: "fork.knife", title: "On the Menu") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(dinner.menuLines, id: \.self) { line in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color.mlrFest.opacity(0.4))
                                    .frame(width: 5, height: 5)
                                Text(line)
                                    .font(.mlrScaled(15))
                                    .foregroundStyle(Color.mlrText)
                            }
                        }
                    }
                }
            }

            Divider().background(Color.mlrFest.opacity(0.12))
            DetailSection(icon: "mappin.and.ellipse", title: "Location") {
                if env.isSignedIn {
                    Text(dinner.location ?? "TBD")
                        .font(.mlrScaled(15))
                        .foregroundStyle(Color.mlrFest.opacity(dinner.location == nil ? 0.5 : 0.85))
                } else {
                    ProtectedField(message: "Sign in to see location")
                }
            }

            if !dinner.crew.isEmpty {
                Divider().background(Color.mlrFest.opacity(0.12))
                DetailSection(icon: "person.3.fill", title: "Crew") {
                    if env.isSignedIn {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(dinner.crew, id: \.self) { member in
                                Text(member)
                                    .font(.mlrScaled(14, weight: .medium))
                                    .foregroundStyle(Color.mlrFestReadable)
                            }
                        }
                    } else {
                        ProtectedField(message: "Sign in to see crew")
                    }
                }
            }

            if canEditDinner {
                Divider().background(Color.mlrFest.opacity(0.12))
                HStack(spacing: 0) {
                    Button { showEditSheet = true } label: {
                        Label(env.isFullFestEditor ? "Edit dinner" : "Edit menu & details", systemImage: "pencil")
                            .font(.mlrScaled(13, weight: .medium))
                            .foregroundStyle(Color.mlrFestReadable)
                    }
                    .buttonStyle(.pressable)
                    if canManageCrew {
                        Spacer()
                        Button { showCrewSheet = true } label: {
                            Label("Manage crew", systemImage: "person.badge.plus")
                                .font(.mlrScaled(13, weight: .medium))
                                .foregroundStyle(Color.mlrFestReadable)
                        }
                        .buttonStyle(.pressable)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
    }

    private func toggle() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { isExpanded.toggle() }
    }
}
