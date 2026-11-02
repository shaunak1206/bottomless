import SwiftUI
import BottomlessCore

struct LibraryView: View {
    enum Mode { case all, favorites }
    let mode: Mode
    @Environment(AppModel.self) private var model
    @Namespace private var zoom
    @State private var viewer: ViewerSelection?
    /// The photo the open viewer is showing, so closing it zooms back into the right thumbnail.
    @State private var viewerCurrent: String?
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var shareItems: ShareItems?
    @State private var linkFor: LinkRequest?
    @State private var busy = false
    /// 3 or 5 across, like Photos; pinch the grid to switch.
    @AppStorage("bottomless.gridColumns") private var columnCount = 3

    private var items: [LibraryEntry] {
        mode == .all ? model.items : model.favorites.map(LibraryEntry.remote)
    }

    /// Grouped by month once per catalog change (in AppModel), not on every redraw.
    private var sections: [LibrarySection] {
        mode == .all ? model.librarySections : model.favoriteSections
    }

    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 1.5), count: columnCount) }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    if model.isOffline { OfflineBanner().padding(.top, 4) }
                    if items.isEmpty {
                        empty.padding(.top, 80)
                    } else {
                        summary
                        LazyVGrid(columns: columns, spacing: 1.5, pinnedViews: [.sectionHeaders]) {
                            ForEach(sections) { section in
                                Section {
                                    ForEach(section.items) { item in
                                        cell(item).id(item.id)
                                            .onAppear { if mode == .all { model.prefetch(after: item) } }
                                    }
                                } header: {
                                    MonthHeader(title: section.title, count: section.items.count)
                                }
                            }
                        }
                        .animation(.snappy, value: columnCount)
                    }
                }
                .simultaneousGesture(MagnifyGesture().onEnded { value in
                    if value.magnification < 0.8, columnCount < 5 { columnCount = 5 }
                    else if value.magnification > 1.25, columnCount > 3 { columnCount = 3 }
                })
                .onChange(of: viewerCurrent) { _, id in
                    // Keep the photo being viewed on screen behind the viewer, so closing it lands in the right place.
                    if let id { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .refreshable { await model.refresh(backup: mode == .all) }
            .navigationTitle(mode == .all ? "Library" : "Favorites")
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) { if selecting { selectionBar } }
            .fullScreenCover(item: $viewer) { sel in
                let page = PhotoViewer(items: sel.items, start: sel.index) { viewerCurrent = $0 }
                if #available(iOS 18.0, *) {
                    // Zooms out of the thumbnail; swipe down to fling it back, like Photos.
                    page.navigationTransition(.zoom(sourceID: viewerCurrent ?? sel.startId, in: zoom))
                } else {
                    page
                }
            }
            .sheet(item: $shareItems) { s in ShareSheet(items: s.urls) }
            .sheet(item: $linkFor) { req in ShareLinkSheet(ids: req.ids) }
        }
    }

    /// "13,387 photos and videos" plus how the backup is doing.
    private var summary: some View {
        HStack(spacing: 8) {
            Text(mode == .all ? "\(items.count.formatted()) photos and videos" : "\(items.count.formatted()) favorites")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            if mode == .all { BackupPill() }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    @ViewBuilder private var empty: some View {
        if mode == .favorites {
            ContentUnavailableView("No favorites yet", systemImage: "heart", description: Text("Tap the heart on a photo to keep it here, and always available offline."))
        } else if model.photoAccess == .denied || model.photoAccess == .restricted {
            ContentUnavailableView {
                Label("Photos access is off", systemImage: "lock")
            } description: {
                Text("Allow Bottomless to read your photo library in Settings to back it up.")
            } actions: {
                Button("Open Settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
            }
        } else {
            ContentUnavailableView("Nothing here yet", systemImage: "photo", description: Text(model.isWorking ? "Backing up your library…" : "Pull down to refresh."))
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(selecting ? "Done" : "Select") {
                withAnimation(.snappy) { selecting.toggle() }
                selected.removeAll()
            }
            .fontWeight(selecting ? .semibold : .regular)
            .disabled(items.isEmpty)
            .accessibilityIdentifier("selectButton")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Grid", selection: $columnCount) {
                    Label("Large", systemImage: "square.grid.2x2").tag(3)
                    Label("Small", systemImage: "square.grid.3x3").tag(5)
                }
            } label: {
                Image(systemName: "square.grid.2x2")
            }
            .accessibilityLabel("Grid size")
        }
        ToolbarItem(placement: .topBarLeading) {
            if model.isWorking { ProgressView().accessibilityIdentifier("syncing") }
        }
    }

    @ViewBuilder private func cell(_ item: LibraryEntry) -> some View {
        let isSelected: Bool = { if case .remote(let a) = item { return selected.contains(a.id) }; return false }()
        let button = Button {
            if selecting {
                if case .remote(let a) = item {
                    if selected.contains(a.id) { selected.remove(a.id) } else { selected.insert(a.id) }
                }
            } else {
                let list = items
                viewerCurrent = nil
                viewer = ViewerSelection(items: list, index: list.firstIndex(of: item) ?? 0, startId: item.id)
            }
        } label: {
            ThumbnailCell(item: item, selected: isSelected, compact: columnCount > 3)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("cell-\(item.id)")
        if #available(iOS 18.0, *) {
            button.matchedTransitionSource(id: item.id, in: zoom)
        } else {
            button
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 28) {
            Button { Task { await share(originals: false) } } label: { Label("Share", systemImage: "square.and.arrow.up") }
            Button { linkFor = LinkRequest(ids: Array(selected)) } label: { Label("Link", systemImage: "link") }
            Button { Task { await model.setFavorite(Array(selected), true); selected.removeAll() } } label: { Label("Favorite", systemImage: "heart") }
            Button(role: .destructive) { Task { await model.trash(Array(selected)); selected.removeAll() } } label: { Label("Trash", systemImage: "trash") }
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .disabled(selected.isEmpty || busy || model.isOffline)
        .padding(.vertical, 14).padding(.horizontal, 30)
        .glassCapsule()
        .overlay(alignment: .top) {
            Text(selected.isEmpty ? "Select items" : "\(selected.count) selected")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .glassCapsule()
                .offset(y: -30)
        }
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func share(originals: Bool) async {
        busy = true
        defer { busy = false }
        do { shareItems = ShareItems(urls: try await model.shareFiles(Array(selected), originals: originals)) }
        catch { model.message = "Could not prepare files: \(error)" }
    }
}

/// Month title pinned to the top while its photos scroll by.
private struct MonthHeader: View {
    let title: String
    let count: Int
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.bold))
            Spacer()
            Text(count.formatted()).font(.footnote.weight(.medium)).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

/// "Backed up", "12,104 to back up" or "Paused until 7:05 PM", next to the item count.
private struct BackupPill: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        let (text, icon, tint): (String, String, Color) = {
            if model.isOffline { return ("Offline", "wifi.slash", .orange) }
            if let until = model.backupPausedUntil, model.waitingCount > 0 {
                return ("Paused until \(until.formatted(date: .omitted, time: .shortened))", "pause.circle.fill", .orange)
            }
            if model.waitingCount > 0 { return ("\(model.waitingCount.formatted()) to back up", "arrow.up.circle.fill", .blue) }
            if model.failedCount > 0 { return ("\(model.failedCount) need attention", "exclamationmark.circle.fill", .red) }
            return ("Backed up", "checkmark.circle.fill", .green)
        }()
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(tint.opacity(0.15), in: Capsule())
    }
}

struct ViewerSelection: Identifiable {
    let id = UUID()
    let items: [LibraryEntry]
    let index: Int
    let startId: String
}

struct ShareItems: Identifiable {
    let id = UUID()
    let urls: [URL]
}

struct LinkRequest: Identifiable {
    let id = UUID()
    let ids: [String]
}

struct ThumbnailCell: View {
    let item: LibraryEntry
    var selected = false
    var compact = false
    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemFill)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    // A tall or wide photo filling the square overflows it; that overflow must not catch taps meant
                    // for the neighbouring cell (it is clipped from view but not from touches).
                    Image(uiImage: image).resizable().scaledToFill().allowsHitTesting(false).transition(.opacity)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { if !compact { badges } }
            .overlay {
                if selected {
                    ZStack(alignment: .bottomTrailing) {
                        Color.black.opacity(0.25)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3).symbolRenderingMode(.palette).foregroundStyle(.white, .blue)
                            .padding(5)
                    }
                }
            }
            .task(id: item.id) {
                if case .remote(let a) = item, let ready = ImageLoader.shared.cachedThumbnail(a.id) {
                    image = ready           // already in memory (scrolled back, or prefetched): no fade, no wait
                    return
                }
                let img = await load()
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.18)) { image = img }
            }
    }

    /// Favorite heart on the left; video length, or the waiting-for-backup cloud, on the right.
    private var badges: some View {
        HStack(spacing: 4) {
            if case .remote(let a) = item, a.favorite { Image(systemName: "heart.fill") }
            Spacer(minLength: 0)
            switch item {
            case .remote(let a):
                if a.kind == .video {
                    if let d = a.duration { Text(Self.duration(d)).monospacedDigit() } else { Image(systemName: "video.fill") }
                }
            case .local(_, _, let kind, let state):
                if kind == .video { Image(systemName: "video.fill") }
                Image(systemName: state == .failed ? "exclamationmark.icloud.fill" : "icloud.slash.fill")
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 2)
        .padding(.horizontal, 5).padding(.bottom, 4)
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom).frame(height: 24)
        }
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    private func load() async -> UIImage? {
        switch item {
        case .remote(let a): return await ImageLoader.shared.thumbnail(a.id)
        case .local(let localId, _, _, _): return await ImageLoader.shared.local(localId, size: CGSize(width: 300, height: 300))
        }
    }
}

extension View {
    /// Liquid Glass on iOS 26, a blurred capsule before that.
    @ViewBuilder func glassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: Capsule())
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }

    @ViewBuilder func glassCircle() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: Circle())
        } else {
            self.background(.ultraThinMaterial, in: Circle())
        }
    }
}
