import SwiftUI
import ClaudePulseCore

struct PopoverView: View {
    @Bindable var coord: UsageCoordinator
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if let snap = coord.snapshot {
                if let err = coord.lastError {
                    staleBanner(err)
                }
                content(snap)
            } else if let err = coord.lastError {
                errorView(err)
            } else {
                ProgressView("Loading…").controlSize(.small)
            }

            footer
        }
        .padding(12)
        .frame(width: 280)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Claude Pulse").font(.headline)
            Spacer()
            if coord.isLoading {
                ProgressView().controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func content(_ snap: UsageSnapshot) -> some View {
        MeterRow(meter: snap.session, resetStyle: .liveCountdown)

        if !snap.weekly.isEmpty {
            SectionHeader(title: "Weekly")
            ForEach(Array(snap.weekly.enumerated()), id: \.offset) { _, m in
                MeterRow(meter: m, resetStyle: .absoluteWeekday)
            }
        }

        // Hide the section until extra usage is actually being consumed.
        // Showing "€0.00 / €40.00" all the time is noise for users who
        // never overflow their plan.
        if let extra = snap.extraUsage,
           extra.isEnabled,
           extra.monthlyLimit > 0,
           extra.usedAmount > 0 {
            SectionHeader(title: "Extra usage")
            ExtraUsageRow(extra: extra)
        }
    }

    private func errorView(_ err: UsageError) -> some View {
        Label(errorMessage(err), systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// Compact banner shown above stale data when the most recent refresh
    /// failed but we still have a previous snapshot to display.
    private func staleBanner(_ err: UsageError) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Latest refresh failed: \(shortErrorMessage(err))")
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private func shortErrorMessage(_ err: UsageError) -> String {
        switch err {
        case .tokenUnavailable:           return "token unavailable"
        case .httpError(let s, _):        return "HTTP \(s)"
        case .rateLimited:                return "rate-limited"
        case .networkError:               return "network error"
        case .malformedResponse:          return "bad response"
        }
    }

    private func errorMessage(_ err: UsageError) -> String {
        switch err {
        case .tokenUnavailable(let why):  return "OAuth token unavailable: \(why)"
        case .httpError(let s, _):        return "Anthropic returned HTTP \(s)."
        case .rateLimited:                return "Rate-limited. Retrying in a few minutes."
        case .networkError(let w):        return "Network error: \(w)"
        case .malformedResponse(let w):   return "Couldn't parse response: \(w)"
        }
    }

    private var footer: some View {
        HStack {
            SpinningRefreshButton(isSpinning: coord.isLoading) {
                Task { await coord.refresh() }
            }

            if let captured = coord.snapshot?.capturedAt {
                Text(captured.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button("Quit", action: onQuit)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
        }
        .padding(.top, 4)
    }
}

/// Refresh button whose arrow spins while `isSpinning` is true.
/// macOS 14 doesn't have `.symbolEffect(.rotate)` — that's macOS 15+ —
/// so we drive a rotation angle from state.
private struct SpinningRefreshButton: View {
    let isSpinning: Bool
    let action: () -> Void

    @State private var angle: Double = 0

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .rotationEffect(.degrees(angle))
        }
        .buttonStyle(.borderless)
        .help("Refresh")
        .disabled(isSpinning)
        .onChange(of: isSpinning, initial: false) { _, spinning in
            if spinning {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            } else {
                // Snap back to 0 instantly so the icon doesn't drift.
                withAnimation(.linear(duration: 0)) { angle = 0 }
            }
        }
    }
}

/// Single source of truth for the green/orange/red palette across the
/// popover. Takes a 0...1 fraction so both percent-meters and absolute
/// spend can call it the same way.
func usageTint(fraction frac: Double) -> Color {
    if frac >= 0.75 { return .red }
    if frac >= 0.50 { return .orange }
    return .green
}

// MARK: - Sub-views

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.top, 4)
    }
}

private enum ResetStyle { case liveCountdown, absoluteWeekday }

private struct MeterRow: View {
    let meter: Meter
    let resetStyle: ResetStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(meter.label).font(.subheadline)
                Spacer()
                Text(String(format: "%.0f%%", meter.usedPct))
                    .font(.subheadline.bold())
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            ProgressView(value: max(0, min(1, meter.usedPct / 100)))
                .tint(tint)
                .scaleEffect(x: 1, y: 0.6, anchor: .center)
            resetLabel
        }
    }

    @ViewBuilder private var resetLabel: some View {
        if let r = meter.resetAt {
            switch resetStyle {
            case .liveCountdown:
                HStack(spacing: 3) {
                    Text("resets in")
                    Text(r, style: .relative)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            case .absoluteWeekday:
                // "Resets Tue 11:59 PM" beats "Wed 12:00 AM" for unambiguity.
                let display = r.addingTimeInterval(-60)
                Text("resets \(display.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } else if meter.usedPct == 0 {
            Text("not used yet")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var tint: Color { usageTint(fraction: meter.usedPct / 100) }
}

private struct ExtraUsageRow: View {
    let extra: ExtraUsage

    var body: some View {
        let frac = extra.monthlyLimit > 0 ? min(1, extra.usedAmount / extra.monthlyLimit) : 0
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Spend").font(.subheadline)
                Spacer()
                Text("\(currency(extra.usedAmount)) / \(currency(extra.monthlyLimit))")
                    .font(.subheadline.bold())
                    .monospacedDigit()
            }
            ProgressView(value: frac)
                .tint(usageTint(fraction: frac))
                .scaleEffect(x: 1, y: 0.6, anchor: .center)
            Text("resets \(extra.resetAt.formatted(.dateTime.month(.abbreviated).day()))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func currency(_ amount: Double) -> String {
        let code = extra.currency.isEmpty ? "USD" : extra.currency
        return amount.formatted(.currency(code: code).precision(.fractionLength(2)))
    }
}
