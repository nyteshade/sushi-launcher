import SwiftUI

// MARK: - Shared visual bits

extension LogLevel {
    var color: Color {
        switch self {
        case .info:    return .primary
        case .warning: return Color(red: 0.95, green: 0.65, blue: 0.15)
        case .error:   return Color(red: 0.86, green: 0.36, blue: 0.30)
        case .debug:   return .secondary
        }
    }

    var symbol: String {
        switch self {
        case .info:    return "circle"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.octagon.fill"
        case .debug:   return "ant"
        }
    }

    /// Console badge and Copy/Save label. Level-based, because sushi logs
    /// everything to stderr — the pipe says nothing useful.
    var badge: String {
        switch self {
        case .info:    return "INF"
        case .warning: return "WRN"
        case .error:   return "ERR"
        case .debug:   return "DBG"
        }
    }
}

/// Stable per-subsystem chip colors: the same tag keeps the same color
/// across launches (deliberately a plain unicode-scalar fold, not
/// hashValue, which is seeded randomly per process).
enum SubsystemPalette {
    private static let colors: [Color] = [
        Color(red: 0.55, green: 0.80, blue: 1.00),   // sky
        Color(red: 0.75, green: 0.65, blue: 1.00),   // lavender
        Color(red: 1.00, green: 0.60, blue: 0.75),   // rose
        Color(red: 0.50, green: 0.90, blue: 0.80),   // mint
        Color(red: 0.70, green: 0.95, blue: 0.55),   // lime
        Color(red: 1.00, green: 0.80, blue: 0.45),   // amber
        Color(red: 1.00, green: 0.65, blue: 0.45),   // coral
        Color(red: 0.60, green: 0.70, blue: 1.00),   // periwinkle
    ]

    static func color(for tag: String) -> Color {
        var h = 7
        for scalar in tag.unicodeScalars { h = (h &* 31) &+ Int(scalar.value) }
        let index = ((h % colors.count) + colors.count) % colors.count
        return colors[index]
    }
}

extension ServerController.Status {
    var color: Color {
        switch self {
        case .stopped:        return .gray
        case .starting:       return .orange
        case .running:        return .green
        case .exited(let c):  return c == 0 ? .gray : .red
        case .failed:         return .red
        }
    }
}

struct StatusChip: View {
    let status: ServerController.Status

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.color)
                .frame(width: 9, height: 9)
            Text(status.label)
                .font(.callout.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(status.color.opacity(0.14)))
    }
}

func uptimeText(since: Date, now: Date = Date()) -> String {
    let total = max(0, Int(now.timeIntervalSince(since)))
    let minutes = total / 60
    let seconds = total % 60
    if minutes < 60 { return String(format: "%dm %02ds", minutes, seconds) }
    return String(format: "%dh %02dm", minutes / 60, minutes % 60)
}
