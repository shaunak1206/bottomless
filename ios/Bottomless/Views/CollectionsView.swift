import SwiftUI
import MapKit
import BottomlessCore

/// Favorites, Recently Added, Videos, Live Photos, Screenshots and Places, plus the albums made on this iPhone.
/// Everything here is built from what is stored in the cloud, so it stays after photos are freed up from the phone.
struct CollectionsView: View {
    @Environment(AppModel.self) private var model
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    enum Route: Hashable {
        case collection(Catalog.Collection)
        case album(id: String, title: String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Catalog.Collection.allCases) { c in
                        let s = model.collections[c]
                        NavigationLink(value: Route.collection(c)) {
                            GroupTile(title: c.title, icon: c.icon, tint: c.tint, count: s?.count ?? 0, coverId: s?.coverId)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("collection-\(c.rawValue)")
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text("Albums").font(.title2.weight(.bold))
                    Spacer()
                    if !model.albums.isEmpty { Text(model.albums.count.formatted()).foregroundStyle(.secondary) }
                }
                .padding(.top, 22).padding(.bottom, 2)
                if model.albums.isEmpty {
                    Text("Albums you make in Photos on this iPhone appear here once their photos are backed up, and stay even after you free up space.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(model.albums) { a in
                            NavigationLink(value: Route.album(id: a.id, title: a.title)) {
                                GroupTile(title: a.title, icon: "rectangle.stack", tint: .blue, count: a.count, coverId: a.coverId)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .navigationTitle("Collections")
            .refreshable { await model.refresh(backup: false) }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .collection(.places):
                    PlacesView()
                case .collection(let c):
                    AssetGridView(title: c.title, emptyText: c.emptyText) { $0.assets(in: c) }
                case .album(let id, let title):
                    AssetGridView(title: title, emptyText: "This album is empty.") { $0.albumAssets(id) }
                }
            }
        }
    }
}

extension Catalog.Collection {
    var title: String {
        switch self {
        case .favorites: return "Favorites"
        case .recentlyAdded: return "Recently Added"
        case .videos: return "Videos"
        case .livePhotos: return "Live Photos"
        case .screenshots: return "Screenshots"
        case .places: return "Places"
        }
    }
    var icon: String {
        switch self {
        case .favorites: return "heart.fill"
        case .recentlyAdded: return "clock.fill"
        case .videos: return "video.fill"
        case .livePhotos: return "livephoto"
        case .screenshots: return "camera.viewfinder"
        case .places: return "map.fill"
        }
    }
    var tint: Color {
        switch self {
        case .favorites: return .pink
        case .recentlyAdded: return .blue
        case .videos: return .purple
        case .livePhotos: return .orange
        case .screenshots: return .teal
        case .places: return .green
        }
    }
    var emptyText: String {
        switch self {
        case .favorites: return "Tap the heart on a photo to keep it here."
        case .recentlyAdded: return "Nothing added in the last \(Catalog.recentlyAddedDays) days."
        default: return "Nothing here yet."
        }
    }
}

/// A square cover photo with the group's name and size on a soft gradient.
struct GroupTile: View {
    let title: String
    let icon: String
    let tint: Color
    let count: Int
    let coverId: String?
    @State private var cover: UIImage?

    var body: some View {
        Color(.secondarySystemFill)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let cover {
                    Image(uiImage: cover).resizable().scaledToFill().allowsHitTesting(false).transition(.opacity)
                } else {
                    Image(systemName: icon).font(.system(size: 34, weight: .semibold)).foregroundStyle(tint.opacity(0.8))
                }
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 1) {
                    Label(title, systemImage: icon).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(count.formatted()).font(.caption).opacity(0.85).monospacedDigit()
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 3)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .task(id: coverId) {
                guard let coverId else { cover = nil; return }
                let img = await ImageLoader.shared.thumbnail(coverId)
                withAnimation(.easeOut(duration: 0.2)) { cover = img }
            }
    }
}

/// A month-by-month grid of some photos (a collection, an album, a place), opening into the photo viewer.
struct AssetGridView: View {
    let title: String
    var emptyText = "Nothing here yet."
    let load: @Sendable (Catalog) -> [CatalogAsset]
    @Environment(AppModel.self) private var model
    @Namespace private var zoom
    @State private var sections: [LibrarySection] = []
    @State private var entries: [LibraryEntry] = []
    @State private var loaded = false
    @State private var viewer: ViewerSelection?
    @State private var viewerCurrent: String?
    @AppStorage("bottomless.gridColumns") private var columnCount = 3

    private var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 1.5), count: columnCount) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if loaded && entries.isEmpty {
                    ContentUnavailableView(title, systemImage: "photo.on.rectangle", description: Text(emptyText)).padding(.top, 80)
                } else {
                    Text("\(entries.count.formatted()) photos and videos")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.bottom, 6)
                    LazyVGrid(columns: columns, spacing: 1.5, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections) { section in
                            Section {
                                ForEach(section.items) { item in cell(item).id(item.id) }
                            } header: {
                                HStack {
                                    Text(section.title).font(.headline)
                                    Spacer()
                                    Text(section.items.count.formatted()).font(.footnote).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .background(.bar)
                            }
                        }
                    }
                }
            }
            .onChange(of: viewerCurrent) { _, id in if let id { proxy.scrollTo(id, anchor: .center) } }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .task(id: model.changeRevision) { await reload() }
        .onChange(of: model.items.count) { _, _ in Task { await reload() } }
        .fullScreenCover(item: $viewer) { sel in
            let page = PhotoViewer(items: sel.items, start: sel.index) { viewerCurrent = $0 }
            if #available(iOS 18.0, *) {
                page.navigationTransition(.zoom(sourceID: viewerCurrent ?? sel.startId, in: zoom))
            } else {
                page
            }
        }
    }

    private func reload() async {
        guard let s = model.services else { return }
        let load = self.load
        let (e, sec) = await Task.detached(priority: .userInitiated) { () -> ([LibraryEntry], [LibrarySection]) in
            let e = load(s.catalog).map(LibraryEntry.remote)
            return (e, LibrarySection.group(e))
        }.value
        entries = e
        sections = sec
        loaded = true
    }

    @ViewBuilder private func cell(_ item: LibraryEntry) -> some View {
        let button = Button {
            viewerCurrent = nil
            viewer = ViewerSelection(items: entries, index: entries.firstIndex(of: item) ?? 0, startId: item.id)
        } label: {
            ThumbnailCell(item: item, compact: columnCount > 3)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("cell-\(item.id)")
        if #available(iOS 18.0, *) { button.matchedTransitionSource(id: item.id, in: zoom) } else { button }
    }
}

// MARK: Places

/// Photos on a map. Nearby photos are grouped into one bubble (finer as you zoom in); tap a bubble to see them.
struct PlacesView: View {
    @Environment(AppModel.self) private var model
    @State private var points: [(id: String, lat: Double, lon: Double)] = []
    @State private var position: MapCameraPosition = .automatic
    @State private var clusters: [PlaceCluster] = []
    @State private var open: PlaceCluster?

    var body: some View {
        Map(position: $position) {
            ForEach(clusters) { c in
                Annotation("", coordinate: c.center, anchor: .center) {
                    Button { open = c } label: { ClusterBubble(cluster: c) }
                        .buttonStyle(.plain)
                }
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .onMapCameraChange(frequency: .onEnd) { ctx in clusters = PlaceCluster.make(points, in: ctx.region) }
        .navigationTitle("Places")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .overlay {
            if points.isEmpty { ContentUnavailableView("No places yet", systemImage: "map", description: Text("Photos taken with location on appear here.")) }
        }
        .task {
            guard let s = model.services, points.isEmpty else { return }
            points = await Task.detached { s.catalog.locatedPoints() }.value
            if let region = PlaceCluster.bounds(points) {
                position = .region(region)
                clusters = PlaceCluster.make(points, in: region)
            }
        }
        .navigationDestination(item: $open) { c in
            AssetGridView(title: c.count == 1 ? "1 photo" : "\(c.count.formatted()) photos") { [ids = c.ids] in $0.assets(ids: ids) }
        }
    }
}

struct PlaceCluster: Identifiable, Hashable {
    let id: String
    let center: CLLocationCoordinate2D
    let ids: [String]
    var count: Int { ids.count }
    var coverId: String { ids[0] }

    static func == (a: PlaceCluster, b: PlaceCluster) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    /// Groups points on a grid about a sixth of the visible map wide; only groups on screen (plus a margin) are kept.
    static func make(_ points: [(id: String, lat: Double, lon: Double)], in region: MKCoordinateRegion) -> [PlaceCluster] {
        let cellLat = max(region.span.latitudeDelta / 6, 0.0005), cellLon = max(region.span.longitudeDelta / 6, 0.0005)
        let minLat = region.center.latitude - region.span.latitudeDelta, maxLat = region.center.latitude + region.span.latitudeDelta
        let minLon = region.center.longitude - region.span.longitudeDelta, maxLon = region.center.longitude + region.span.longitudeDelta
        var cells: [String: (lat: Double, lon: Double, ids: [String])] = [:]
        for p in points where p.lat >= minLat && p.lat <= maxLat && p.lon >= minLon && p.lon <= maxLon {
            let key = "\(Int((p.lat / cellLat).rounded(.down))):\(Int((p.lon / cellLon).rounded(.down)))"
            var c = cells[key] ?? (0, 0, [])
            c.lat += p.lat; c.lon += p.lon; c.ids.append(p.id)
            cells[key] = c
        }
        return cells.map { key, c in
            PlaceCluster(id: key + ":\(c.ids.count)", center: .init(latitude: c.lat / Double(c.ids.count), longitude: c.lon / Double(c.ids.count)), ids: c.ids)
        }
    }

    /// A region showing all the points (with some room around them).
    static func bounds(_ points: [(id: String, lat: Double, lon: Double)]) -> MKCoordinateRegion? {
        guard let f = points.first else { return nil }
        var minLat = f.lat, maxLat = f.lat, minLon = f.lon, maxLon = f.lon
        for p in points { minLat = min(minLat, p.lat); maxLat = max(maxLat, p.lat); minLon = min(minLon, p.lon); maxLon = max(maxLon, p.lon) }
        return MKCoordinateRegion(center: .init(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
                                  span: .init(latitudeDelta: min(170, max(0.05, (maxLat - minLat) * 1.3)), longitudeDelta: min(360, max(0.05, (maxLon - minLon) * 1.3))))
    }
}

/// A photo in a white rounded frame with the number of photos it stands for.
private struct ClusterBubble: View {
    let cluster: PlaceCluster
    @State private var image: UIImage?
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(.secondarySystemFill)
                .frame(width: 52, height: 52)
                .overlay { if let image { Image(uiImage: image).resizable().scaledToFill() } }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white, lineWidth: 2.5))
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
            if cluster.count > 1 {
                Text(cluster.count < 1000 ? cluster.count.formatted() : "\(cluster.count / 1000)k")
                    .font(.caption2.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.blue, in: Capsule())
                    .offset(x: 8, y: -8)
            }
        }
        .task(id: cluster.coverId) { image = await ImageLoader.shared.thumbnail(cluster.coverId) }
    }
}
