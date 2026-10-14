import AppKit
import SwiftUI

struct PopoverView: View {
    @ObservedObject var model: AppModel
    /// False when rendered offscreen (snapshots), where AppKit-backed menus cannot draw.
    var interactive = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.visibleAccounts.isEmpty {
                Text(model.accounts.isEmpty ? L.noAccounts : L.noneSelected)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                sections
            }
        }
        .padding(16)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(model.visibleAccounts.enumerated()), id: \.element.id) { index, account in
                if index > 0 { Divider() }
                AccountSection(account: account, state: model.state(account), isActive: index == 0)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("UsageBar").font(.headline)
            Spacer()
            if model.states.values.contains(where: \.isLoading) { ProgressView().controlSize(.small) }
            if interactive {
                settingsMenu
            } else {
                Image(systemName: "gearshape.fill").foregroundStyle(.secondary)
            }
        }
    }

    private var settingsMenu: some View {
        Menu {
            ForEach(Provider.allCases) { provider in
                let accounts = model.accounts.filter { $0.provider == provider }
                Section(provider.title) {
                    if accounts.isEmpty {
                        Text(L.notFound)
                    }
                    ForEach(accounts) { account in
                        Toggle(account.email.map { "\(account.name) · \($0)" } ?? account.name, isOn: Binding(
                            get: { model.isEnabled(account) },
                            set: { model.setEnabled(account, $0) }
                        ))
                    }
                    Button(L.openDashboard) { NSWorkspace.shared.open(provider.dashboardURL) }
                }
            }
            Divider()
            Button(L.refresh) { Task { await model.tick(force: true) } }
            Toggle(L.launchAtLogin, isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
            Divider()
            Button(L.quit) { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape.fill")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L.settings)
    }
}

private struct AccountSection: View {
    let account: Account
    let state: AccountState
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: isActive ? 12 : 8) {
            HStack(spacing: 7) {
                Circle().fill(Heat.color(state.ratio)).frame(width: 8, height: 8)
                Text(account.provider.title).font(.subheadline.weight(.semibold))
                Text(account.name == account.provider.title ? (account.email ?? "") : account.name)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if isActive {
                    Text(L.active)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                }
                Spacer(minLength: 4)
                if !isActive, let snapshot = state.snapshot {
                    if state.error != nil {
                        Image(systemName: "clock.arrow.circlepath").font(.caption).foregroundStyle(.secondary)
                            .help(state.error?.long ?? "")
                    }
                    Text(snapshot.headline).font(.subheadline.weight(.semibold)).monospacedDigit()
                }
            }
            .help(account.email ?? account.source)

            if let snapshot = state.snapshot {
                if isActive { amounts(snapshot) }
                VStack(alignment: .leading, spacing: isActive ? 12 : 7) {
                    ForEach(isActive ? snapshot.meters : Array(snapshot.meters.prefix(2))) {
                        MeterRow(meter: $0, compact: !isActive)
                    }
                }
            } else if state.error == nil {
                Text(L.loading).font(.callout).foregroundStyle(.secondary)
            }
            if let error = state.error, state.snapshot == nil {
                Label(error.long, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Heat.color(1))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isActive {
                HStack(spacing: 6) {
                    if let footnote = state.snapshot?.footnote { Text(footnote) }
                    Spacer()
                    if state.snapshot != nil, let error = state.error {
                        Image(systemName: "clock.arrow.circlepath").help(error.long)
                    }
                    if let updated = state.lastUpdated {
                        Text(L.updated(updated.formatted(date: .omitted, time: .shortened)))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func amounts(_ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            let big = snapshot.amounts.filter(\.emphasized)
            if !big.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    ForEach(big) { amount in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(amount.value)
                                .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                            Text(amount.label).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            ForEach(snapshot.amounts.filter { !$0.emphasized }) { amount in
                HStack {
                    Text(amount.label).foregroundStyle(.secondary)
                    Spacer()
                    Text(amount.value).monospacedDigit()
                }
                .font(.callout)
            }
        }
    }
}

private struct MeterRow: View {
    let meter: UsageMeter
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 5) {
            HStack {
                Text(meter.label).font(compact ? .caption : .callout)
                if compact, let detail = meter.detail {
                    Text("· " + detail).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer()
                Text(meter.percent.map { "\(Int($0.rounded()))%" } ?? "–")
                    .font((compact ? Font.caption : .callout).weight(.semibold)).monospacedDigit()
            }
            GeometryReader { geo in
                let p = min(100, max(0, meter.percent ?? 0)) / 100
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(Heat.color(p))
                        .frame(width: p > 0 ? max(compact ? 4 : 6, geo.size.width * p) : 0)
                }
            }
            .frame(height: compact ? 5 : 8)
            if !compact, let detail = meter.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
