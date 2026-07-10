import SwiftUI

/// Popover shown when clicking the Codex status item. Reuses UsageRow so the
/// 5-hour / weekly bars look identical in style to the Claude popover, while
/// the header makes the provider unmistakable.
struct CodexPopoverView: View {
    @ObservedObject var controller: CodexMenuBarController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Divider()

            if let usage = controller.usage {
                UsageRow(
                    title: "codex.session_usage".localized,
                    subtitle: nil,
                    usedPercentage: usage.primaryPercentage,
                    showRemaining: false,
                    resetTime: usage.primaryResetTime,
                    periodDuration: usage.primaryWindowSeconds ?? 5 * 3600
                )

                UsageRow(
                    title: "codex.weekly_usage".localized,
                    subtitle: nil,
                    usedPercentage: usage.weeklyPercentage,
                    showRemaining: false,
                    resetTime: usage.weeklyResetTime,
                    periodDuration: usage.weeklyWindowSeconds ?? 7 * 24 * 3600
                )
            } else if let error = controller.lastError {
                errorContent(error)
            } else {
                loadingContent
            }

            Divider()

            footer
        }
        .padding(14)
        .frame(width: 280)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)

            Text("codex.title".localized)
                .font(.system(size: 13, weight: .semibold))

            Spacer()

            if let plan = controller.usage?.planType, !plan.isEmpty {
                Text(plan.capitalized)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(0.08))
                    )
            }
        }
    }

    // MARK: - States

    private func errorContent(_ error: CodexUsageError) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 13))
            Text(error.errorDescription ?? "codex.error.parse".localized)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    private var loadingContent: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("codex.loading".localized)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let updated = controller.usage?.lastUpdated {
                Text("codex.last_updated".localized(with: updatedTimeString(updated)))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: { controller.refresh() }) {
                if controller.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("common.refresh".localized)
        }
    }

    private func updatedTimeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}
