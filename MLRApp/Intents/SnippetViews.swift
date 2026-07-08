import SwiftUI

// MARK: - Intent snippet views (Siri / Shortcuts visual results)
//
// Small cards Siri/Shortcuts show alongside the spoken answer for the richer
// query intents. Kept dependency-free (plain SwiftUI + SF Symbols) so they render
// in the system's snippet surface.

struct DinnerSnippet: View {
    let day: String
    let title: String
    let chef: String
    let time: String
    let menu: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "fork.knife")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(day) · \(title)").font(.headline)
                if chef != "TBD" { Text("Chef: \(chef)").font(.subheadline).foregroundStyle(.secondary) }
                if time != "TBD" { Text(time).font(.subheadline).foregroundStyle(.secondary) }
                if !menu.isEmpty {
                    Text(menu.prefix(4).joined(separator: " • "))
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding()
    }
}

struct WeatherSnippet: View {
    struct Day: Identifiable {
        let id = UUID()
        let weekday: String
        let symbol: String
        let high: String
        let precip: Int
    }
    let title: String
    let days: [Day]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            HStack(spacing: 16) {
                ForEach(days.prefix(5)) { d in
                    VStack(spacing: 3) {
                        Text(d.weekday).font(.caption).foregroundStyle(.secondary)
                        Image(systemName: d.symbol).font(.title3).symbolRenderingMode(.multicolor)
                        Text(d.high).font(.subheadline.weight(.semibold))
                        if d.precip > 0 {
                            Text("\(d.precip)%").font(.caption2).foregroundStyle(.blue)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding()
    }
}

struct SimpleInfoSnippet: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding()
    }
}
