import SwiftUI
import BottomlessCore

/// The Backup tab: how much of this iPhone is in the cloud, the library at a glance, and freeing up space.
/// Settings live on their own screen (gear button) so this stays uncluttered.
struct StatusView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmFreeUp = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    hero
                    if let n = notice { n }
                    statsCard
                    NavigationLink { TrashView() } label: {
                        CardRow(icon: "trash", tint: .secondary, title: "Recently Deleted", value: model.trashed.count.formatted())
                    }
                    .buttonStyle(.plain)
                    freeUpCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Backup")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }
                        .accessibilityIdentifier("settingsButton")
                        .accessibilityLabel("Settings")
                }
            }
            .refreshable { await model.refresh(backup: true) }
            .confirmationDialog("Remove \(model.freeUpCount) backed-up item(s) from this iPhone?", isPresented: $confirmFreeUp, titleVisibility: .visible) {
                Button("Remove from iPhone", role: .destructive) { Task { await model.freeUpSpace() } }
            } message: {
                Text("They stay in Bottomless. iOS asks you to confirm and keeps them in Recently Deleted for 30 days. iCloud Photos must be off, or this also deletes them from iCloud.")
            }
            .onChange(of: model.openFreeUp) { _, open in if open { confirmFreeUp = model.freeUpCount > 0; model.openFreeUp = false } }
        }
    }

    // MARK: hero

    /// Share of this iPhone's photos that are safely in the cloud.
    private var fraction: Double {
        let total = model.backedUpCount + model.waitingCount + model.failedCount
        return total == 0 ? 1 : Double(model.backedUpCount) / Double(total)
    }

    private var paused: Bool { model.backupPausedUntil != nil && model.waitingCount > 0 }

    private var tint: Color {
        if model.isOffline || paused { return .orange }
        if model.waitingCount == 0 && model.failedCount > 0 { return .red }
        return model.waitingCount == 0 ? .green : .blue
    }

    private var hero: some View {
        VStack(spacing: 12) {
            ProgressRing(fraction: fraction, tint: tint, done: model.waitingCount == 0 && model.failedCount == 0)
                .frame(width: 116, height: 116)
                .padding(.top, 8)
            VStack(spacing: 4) {
                Text(model.waitingCount == 0 ? "Everything is backed up" : "\(model.waitingCount.formatted()) left to back up")
                    .font(.title3.weight(.semibold))
                    .accessibilityIdentifier("backupHeadline")
                Text(subline).font(.subheadline).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            Button {
                Task { await model.refresh(backup: true) }
            } label: {
                HStack(spacing: 8) {
                    if model.isWorking { ProgressView(); Text("Backing up…") } else { Text("Back up now") }
                }
                .font(.body.weight(.semibold))
                .frame(maxWidth: 260, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(model.isWorking || model.isOffline)
            .accessibilityIdentifier("backupNow")
            if model.failedCount > 0 {
                Button("Retry \(model.failedCount) failed") { Task { await model.retryFailed() } }
                    .font(.subheadline.weight(.medium))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    /// One short line: progress while backing up, otherwise when it last synced.
    private var subline: String {
        let total = model.backedUpCount + model.waitingCount + model.failedCount
        if model.waitingCount > 0 { return "\(model.backedUpCount.formatted()) of \(total.formatted()) photos from this iPhone" }
        if let last = model.lastRun { return "Synced \(last.formatted(.relative(presentation: .named)))" }
        return "Photos you take are backed up automatically"
    }

    /// At most one short line, and only when something needs saying.
    private var notice: AnyView? {
        if model.isOffline { return AnyView(NoticeLine(text: "Offline. Backup resumes when you reconnect.", icon: "wifi.slash", tint: .orange)) }
        if let until = model.backupPausedUntil, model.waitingCount > 0 {
            let when = Calendar.current.isDateInToday(until) ? until.formatted(date: .omitted, time: .shortened) : until.formatted(date: .abbreviated, time: .shortened)
            return AnyView(NoticeLine(text: "Paused until \(when) (daily cloud limit). Resumes by itself.", icon: "pause.circle.fill", tint: .orange)
                .accessibilityIdentifier("backupPaused"))
        }
        if model.photoAccess == .limited {
            return AnyView(NoticeLine(text: "Only selected photos are shared with Bottomless. Allow full access in Settings.", icon: "exclamationmark.triangle.fill", tint: .yellow))
        }
        return nil
    }

    // MARK: library

    private var statsCard: some View {
        HStack(spacing: 0) {
            Stat(value: (model.stats?.ready ?? model.items.count).formatted(), label: "In the cloud")
            Divider().frame(height: 34)
            Stat(value: model.stats.map { ByteCountFormatter.string(fromByteCount: $0.bytes, countStyle: .file) } ?? "–", label: "Stored")
            Divider().frame(height: 34)
            Stat(value: model.favorites.count.formatted(), label: "Favorites")
        }
        .padding(.vertical, 14)
        .card()
    }

    // MARK: free up space

    private var freeUpCard: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            Label("Free up space", systemImage: "externaldrive.badge.minus").font(.headline)
            Text("Removes backed-up photos older than \(model.settings.keepOnPhoneDays) days from this iPhone. Favorites always stay.")
                .font(.footnote).foregroundStyle(.secondary)
            Toggle("iCloud Photos is turned off", isOn: $model.settings.iCloudPhotosOffConfirmed)
                .font(.subheadline)
            Button {
                confirmFreeUp = true
            } label: {
                Text(model.freeUpCount > 0 ? "Free up \(model.freeUpCount.formatted()) items" : "Nothing to free up")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 26)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .disabled(model.freeUpCount == 0 || !model.settings.iCloudPhotosOffConfirmed || model.isOffline)
            .accessibilityIdentifier("freeUpButton")
        }
        .padding(16)
        .card()
    }
}

/// Everything adjustable, out of the way of the Backup tab.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Backup") {
                Toggle("Back up automatically", isOn: $model.settings.autoBackup)
                Toggle("Wi‑Fi only", isOn: $model.settings.wifiOnly)
            }
            Section("Viewing") {
                Toggle("Play Live Photos", isOn: $model.settings.playLivePhotos)
                    .accessibilityIdentifier("playLivePhotos")
                Stepper("Offline previews: \(model.settings.offlinePreviewCount)", value: $model.settings.offlinePreviewCount, in: 0...5000, step: 50)
                Stepper("Originals cache: \(model.settings.originalsCacheMB) MB", value: $model.settings.originalsCacheMB, in: 256...20480, step: 256)
            }
            Section {
                Stepper("Keep last \(model.settings.keepOnPhoneDays) days", value: $model.settings.keepOnPhoneDays, in: 1...365, step: 1)
            } header: {
                Text("On this iPhone")
            } footer: {
                Text("Free up space never removes photos newer than this, or favorites.")
            }
            if !model.shares.isEmpty {
                Section("Share links") {
                    ForEach(model.shares) { link in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(link.title ?? "\(link.count ?? 0) item(s)")
                            Text("Expires \(Date(ms: link.expiresAt).formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { Task { await model.deleteShare(link) } }
                            Button("Copy") { UIPasteboard.general.url = link.url }.tint(.blue)
                        }
                    }
                }
            }
            Section {
                LabeledContent("Server", value: model.services?.config.baseURL.host() ?? "-")
                LabeledContent("Shortcuts action", value: "Sync Photos")
            } header: {
                Text("About")
            } footer: {
                Text("For a dependable daily backup, add a Personal Automation in Shortcuts (for example “When charger connects”) that runs Sync Photos.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct Stat: View {
    let value: String
    let label: String
    var body: some View {
        VStack(spacing: 3) {
            Text(value).font(.title3.weight(.bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CardRow: View {
    let icon: String
    let tint: Color
    let title: String
    let value: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 22)
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16).frame(minHeight: 50)
        .card()
        .contentShape(Rectangle())
    }
}

private struct NoticeLine: View {
    let text: String
    let icon: String
    let tint: Color
    var body: some View {
        Label(text, systemImage: icon)
            .font(.footnote.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private extension View {
    func card() -> some View {
        background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct TrashView: View {
    @Environment(AppModel.self) private var model
    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 2)]

    var body: some View {
        ScrollView {
            if model.trashed.isEmpty {
                ContentUnavailableView("Trash is empty", systemImage: "trash", description: Text("Deleted items stay here for 30 days."))
                    .padding(.top, 80)
            } else {
                Text("Items are permanently deleted 30 days after you trash them.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(model.trashed) { a in
                        ThumbnailCell(item: .remote(a))
                            .contextMenu {
                                Button { Task { await model.restore(a.id) } } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
                            }
                    }
                }
            }
        }
        .navigationTitle("Recently Deleted")
    }
}

/// A ring that fills as the iPhone's photos reach the cloud, with a checkmark when it is done.
private struct ProgressRing: View {
    let fraction: Double
    let tint: Color
    let done: Bool
    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.18), lineWidth: 12)
            Circle()
                .trim(from: 0, to: max(0.002, min(1, fraction)))
                .stroke(tint.gradient, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.6), value: fraction)
            if done {
                Image(systemName: "checkmark").font(.system(size: 44, weight: .bold)).foregroundStyle(tint)
            } else {
                VStack(spacing: 0) {
                    Text(fraction.formatted(.percent.precision(.fractionLength(0)))).font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("backed up").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(done ? "Everything is backed up" : "\(Int(fraction * 100)) percent backed up")
    }
}

