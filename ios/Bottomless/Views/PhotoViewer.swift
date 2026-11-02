import SwiftUI
import AVKit
import MapKit
import Photos
import BottomlessCore

struct PhotoViewer: View {
    let items: [LibraryEntry]
    private let positions: [String: Int]
    private let onCurrentChange: ((String) -> Void)?
    @State private var currentId: String?
    @State private var zoomed = false
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var shareItems: ShareItems?
    @State private var linkFor: LinkRequest?
    @State private var showInfo = false
    @State private var confirmTrash = false
    @State private var working = false
    @State private var chromeHidden = false
    @State private var settleTask: Task<Void, Never>?

    init(items: [LibraryEntry], start: Int, onCurrentChange: ((String) -> Void)? = nil) {
        self.items = items
        self.onCurrentChange = onCurrentChange
        var p = [String: Int](minimumCapacity: items.count)
        for (i, e) in items.enumerated() { p[e.id] = i }
        positions = p
        let s = items.indices.contains(start) ? start : 0
        _currentId = State(initialValue: items.isEmpty ? nil : items[s].id)
    }

    private var index: Int { currentId.flatMap { positions[$0] } ?? 0 }
    private var current: LibraryEntry? { items.indices.contains(index) ? items[index] : nil }
    private var currentAsset: CatalogAsset? {
        guard case .remote(let a) = current else { return nil }
        // Reading changeRevision redraws the heart and Live state the moment a change is made on the phone.
        _ = model.changeRevision
        return model.services?.catalog.asset(a.id) ?? a
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // A paging scroll view over the whole library. It only builds the pages on screen, so it opens instantly
            // with tens of thousands of photos, and it snaps cleanly (the page TabView it replaces could stop half way
            // between two photos when its pages changed during a swipe).
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(items) { item in
                        PageView(item: item, onZoom: { zoomed = $0 })
                            .containerRelativeFrame([.horizontal, .vertical])
                            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() } }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $currentId)
            .scrollIndicators(.hidden)
            .scrollDisabled(zoomed)
            .ignoresSafeArea()
            .onChange(of: currentId) { _, id in
                guard let id else { return }
                // Tell the grid (so closing zooms into the right thumbnail) once swiping settles.
                settleTask?.cancel()
                settleTask = Task {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    if !Task.isCancelled { onCurrentChange?(id) }
                }
            }
            if !chromeHidden { chrome.transition(.opacity) }
            if working { ProgressView().tint(.white).scaleEffect(1.4) }
        }
        .statusBarHidden(chromeHidden)
        .preferredColorScheme(.dark)
        .sheet(item: $shareItems) { ShareSheet(items: $0.urls) }
        .sheet(item: $linkFor) { ShareLinkSheet(ids: $0.ids) }
        .sheet(isPresented: $showInfo) { if let a = currentAsset { InfoSheet(asset: a).presentationDetents([.medium, .large]) } }
        .confirmationDialog("This photo moves to Recently Deleted for 30 days.", isPresented: $confirmTrash, titleVisibility: .visible) {
            Button("Delete Photo", role: .destructive) {
                if let a = currentAsset { Task { await model.trash([a.id]) } }
                dismiss()
            }
        }
    }

    /// "Today", "Yesterday", a weekday this week, "October 12" this year, otherwise "October 12, 2024".
    static func dayTitle(_ d: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: now)).day, days > 0, days < 7 {
            return d.formatted(.dateTime.weekday(.wide))
        }
        if cal.isDate(d, equalTo: now, toGranularity: .year) { return d.formatted(.dateTime.month(.wide).day()) }
        return d.formatted(.dateTime.month(.wide).day().year())
    }

    private var chrome: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left").font(.body.weight(.semibold)).frame(width: 44, height: 44).glassCircle()
                    }
                    .accessibilityIdentifier("closeViewer")
                    .accessibilityLabel("Close")
                    Spacer()
                    if let a = currentAsset, a.kind == .live, a.hasPaired, model.settings.playLivePhotos {
                        liveMenu(a)
                    }
                }
                if let d = current?.date {
                    VStack(spacing: 1) {
                        Text(Self.dayTitle(d)).font(.headline)
                        Text(d.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                    .lineLimit(1)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, 14).padding(.top, 2)
            .background(alignment: .top) {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 150).ignoresSafeArea().allowsHitTesting(false)
            }
            Spacer()
            Group {
                if let a = currentAsset { actionBar(a) }
                else if case .local(_, _, _, let state) = current {
                    Label(state == .failed ? "Backup failed; will retry" : "Not backed up yet", systemImage: "icloud.slash")
                        .font(.footnote.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 10).glassCapsule()
                }
            }
            .padding(.bottom, 6)
            .background(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 150).ignoresSafeArea().allowsHitTesting(false)
            }
        }
        .foregroundStyle(.white)
        .tint(.white)
    }

    /// Share · Favorite · Info · More · Trash, like the bar under a photo in Photos.
    private func actionBar(_ a: CatalogAsset) -> some View {
        HStack(spacing: 0) {
            Menu {
                Button { Task { await share(a, originals: false) } } label: { Label("Share photo", systemImage: "square.and.arrow.up") }
                Button { Task { await share(a, originals: true) } } label: { Label("Share original", systemImage: "doc.richtext") }
                Button { linkFor = LinkRequest(ids: [a.id]) } label: { Label("Create link", systemImage: "link") }
            } label: { barIcon("square.and.arrow.up") }
                .accessibilityIdentifier("shareMenu")
            Button { Task { await model.toggleFavorite(a) } } label: {
                barIcon(a.favorite ? "heart.fill" : "heart").foregroundStyle(a.favorite ? .pink : .white)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityIdentifier("favoriteButton")
            .accessibilityLabel(a.favorite ? "Remove from favorites" : "Add to favorites")
            .accessibilityValue(a.favorite ? "on" : "off")
            Button { showInfo = true } label: { barIcon("info.circle") }
                .accessibilityLabel("Info")
            Menu {
                Button { Task { await saveOriginal(a) } } label: { Label("Save original to Photos", systemImage: "square.and.arrow.down") }
            } label: { barIcon("ellipsis.circle") }
                .accessibilityLabel("More")
            Button { confirmTrash = true } label: { barIcon("trash") }
                .accessibilityLabel("Delete")
        }
        .padding(.horizontal, 8)
        .glassCapsule()
        .padding(.horizontal, 20)
        .disabled(model.isOffline || working)
    }

    private func barIcon(_ name: String) -> some View {
        Image(systemName: name).font(.title3).frame(maxWidth: .infinity, minHeight: 50)
    }

    /// Like the LIVE menu in Photos: play the motion, or turn Live off so this photo stays still (the clip is kept).
    private func liveMenu(_ a: CatalogAsset) -> some View {
        let on = model.playsLive(a)
        return Menu {
            Button { model.livePlayRequest = a.id } label: { Label("Play", systemImage: "play.fill") }
                .disabled(!on).accessibilityIdentifier("livePlay")
            Button { Task { await model.setLiveOff(a, false) } } label: { Label("Live", systemImage: on ? "checkmark" : "livephoto") }
                .accessibilityIdentifier("liveOn")
            Button { Task { await model.setLiveOff(a, true) } } label: { Label("Off", systemImage: on ? "livephoto.slash" : "checkmark") }
                .accessibilityIdentifier("liveOff")
        } label: {
            Label(on ? "LIVE" : "OFF", systemImage: on ? "livephoto" : "livephoto.slash")
                .font(.caption.weight(.bold))
                .padding(.horizontal, 12).frame(height: 36)
                .glassCapsule()
        }
        .accessibilityIdentifier("liveMenu")
        .accessibilityValue(on ? "on" : "off")
        .disabled(model.isOffline)
    }

    private func share(_ a: CatalogAsset, originals: Bool) async {
        working = true
        defer { working = false }
        do { shareItems = ShareItems(urls: try await model.shareFiles([a.id], originals: originals)) }
        catch { model.message = "Could not prepare the file: \(error)" }
    }

    private func saveOriginal(_ a: CatalogAsset) async {
        working = true
        defer { working = false }
        await model.saveToPhotos(a)
    }
}

/// One page: a zoomable photo (preview, or the on-phone original), or a video player. A Live Photo plays its motion
/// while it is pressed (or from the LIVE menu) unless Live is turned off for it or for the whole library.
private struct PageView: View {
    let item: LibraryEntry
    var onZoom: (Bool) -> Void = { _ in }
    @Environment(AppModel.self) private var model
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var failed = false
    @State private var clip: AVPlayer?
    @State private var clipLoading = false
    @State private var livePlays = 0
    @State private var clipEnded: NSObjectProtocol?
    @State private var holding = false

    private var liveAsset: CatalogAsset? {
        if case .remote(let a) = item, model.playsLive(a) { return a }
        return nil
    }

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player).onDisappear { player.pause() }
            } else if let image {
                ZoomableImage(image: image, onZoom: onZoom)
                    .accessibilityIdentifier("photo-\(item.id)")
                    .accessibilityValue(liveAsset == nil ? "" : "live plays: \(livePlays)")
                    .overlay { if let clip { ClipView(player: clip).allowsHitTesting(false) } }
                    .overlay {
                        if clipLoading { ProgressView().tint(.white).frame(width: 44, height: 44).glassCircle() }
                    }
                    .holdToPlay(began: {
                        guard !holding, let a = liveAsset else { return }
                        holding = true
                        Task { await playLive(a, once: false) }
                    }, ended: {
                        holding = false
                        stopLive()
                    })
            } else if failed {
                VStack(spacing: 8) {
                    Image(systemName: "icloud.slash").font(.largeTitle)
                    Text(model.isOffline ? "Not saved on this iPhone. Connect to view it." : "Could not load this photo.")
                        .font(.footnote)
                }.foregroundStyle(.secondary)
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: item.id) { await load() }
        .onChange(of: model.livePlayRequest) { _, id in
            guard let a = liveAsset, id == a.id else { return }
            model.livePlayRequest = nil
            Task { await playLive(a, once: true) }
        }
        .onDisappear { stopLive() }
    }

    private func playLive(_ a: CatalogAsset, once: Bool) async {
        clipLoading = true
        let url = await model.liveClip(a)
        clipLoading = false
        guard let url else { model.message = "Could not load the motion of this Live Photo. Check your connection and try again."; return }
        if !once && !holding { return }     // the finger was lifted while the clip was loading
        stopLive()
        let p = AVPlayer(url: url)
        clip = p
        p.play()
        livePlays += 1
        // Back to the still photo when the clip ends.
        clipEnded = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { _ in
            Task { @MainActor in if clip === p { stopLive() } }
        }
    }

    private func stopLive() {
        clip?.pause()
        clip = nil
        if let clipEnded { NotificationCenter.default.removeObserver(clipEnded) }
        clipEnded = nil
    }

    private var isVideo: Bool {
        switch item {
        case .remote(let a): return a.kind == .video
        case .local(_, _, let k, _): return k == .video
        }
    }

    private func load() async {
        switch item {
        case .remote(let a):
            if let cached = await ImageLoader.shared.thumbnail(a.id) { image = cached }      // instant low-res first
            if isVideo {
                if let localId = a.localId, let p = await localPlayer(localId) { player = p; return }
                if !model.isOffline, let s = model.services, let url = try? await s.api.originalURL(a.id) {
                    player = AVPlayer(url: url); return
                }
            }
            // Still on this iPhone: the Photos library is faster than the cloud and full quality.
            if let localId = a.localId, let img = await ImageLoader.shared.local(localId, size: CGSize(width: 2048, height: 2048)) {
                image = img; return
            }
            if let full = await ImageLoader.shared.preview(a.id) { image = full } else if image == nil { failed = true }
        case .local(let localId, _, _, _):
            if isVideo, let p = await localPlayer(localId) { player = p; return }
            if let img = await ImageLoader.shared.local(localId, size: CGSize(width: 2048, height: 2048)) { image = img } else { failed = true }
        }
    }

    private func localPlayer(_ localId: String) async -> AVPlayer? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localId], options: nil).firstObject else { return nil }
        let opts = PHVideoRequestOptions()
        opts.isNetworkAccessAllowed = true
        let item: AVPlayerItem? = await withCheckedContinuation { c in
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: opts) { item, _ in c.resume(returning: item) }
        }
        return item.map(AVPlayer.init(playerItem:))
    }
}

/// Press and hold to play a Live Photo, like in Photos. It is UIKit's long-press recognizer set to work alongside the
/// pager: a still finger for 0.3 s starts the motion and lifting it stops it, while a finger that moves first is a
/// swipe to the next photo and never plays anything. (A SwiftUI long-press gesture here swallowed the page swipes.)
@available(iOS 18.0, *)
private struct HoldGesture: UIGestureRecognizerRepresentable {
    let began: () -> Void
    let ended: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let g = UILongPressGestureRecognizer()
        g.minimumPressDuration = 0.3
        g.allowableMovement = 12
        g.delegate = context.coordinator
        return g
    }

    func handleUIGestureRecognizerAction(_ g: UILongPressGestureRecognizer, context: Context) {
        switch g.state {
        case .began: began()
        case .ended, .cancelled, .failed: ended()
        default: break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

private extension View {
    @ViewBuilder func holdToPlay(began: @escaping () -> Void, ended: @escaping () -> Void) -> some View {
        if #available(iOS 18.0, *) {
            self.gesture(HoldGesture(began: began, ended: ended))
        } else {
            self.onLongPressGesture(minimumDuration: 0.3, maximumDistance: 12, perform: began, onPressingChanged: { if !$0 { ended() } })
        }
    }
}

/// A bare video layer (no controls) for playing a Live Photo's motion on top of the still.
private struct ClipView: UIViewRepresentable {
    let player: AVPlayer
    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.playerLayer.videoGravity = .resizeAspect
        v.backgroundColor = .clear
        v.isAccessibilityElement = true
        v.accessibilityIdentifier = "livePlaying"
        v.accessibilityLabel = "Live Photo playing"
        return v
    }
    func updateUIView(_ v: LayerView, context: Context) { v.playerLayer.player = player }
}

struct ZoomableImage: View {
    let image: UIImage
    /// Called when the photo is zoomed in or back out (paging is paused while zoomed so a pan moves the photo).
    var onZoom: (Bool) -> Void = { _ in }
    @State private var scale: CGFloat = 1
    @State private var last: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .offset(offset)
            .gesture(MagnifyGesture()
                .onChanged { scale = max(1, last * $0.magnification) }
                .onEnded { _ in last = scale; if scale == 1 { withAnimation { offset = .zero; lastOffset = .zero } } })
            .simultaneousGesture(scale > 1 ? DragGesture()
                .onChanged { offset = CGSize(width: lastOffset.width + $0.translation.width, height: lastOffset.height + $0.translation.height) }
                .onEnded { _ in lastOffset = offset } : nil)
            .onTapGesture(count: 2) {
                withAnimation(.spring) {
                    if scale > 1 { scale = 1; last = 1; offset = .zero; lastOffset = .zero } else { scale = 2.5; last = 2.5 }
                }
            }
            .onChange(of: scale > 1) { _, zoomedIn in onZoom(zoomedIn) }
            .onDisappear { if scale > 1 { onZoom(false) } }
    }
}

private struct InfoSheet: View {
    let asset: CatalogAsset
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(asset.takenAt.formatted(.dateTime.weekday(.wide).month(.wide).day().year())).font(.headline)
                        Text(asset.takenAt.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                if let lat = asset.lat, let lon = asset.lon {
                    let spot = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                    Section {
                        Map(initialPosition: .region(MKCoordinateRegion(center: spot, latitudinalMeters: 1200, longitudinalMeters: 1200)),
                            interactionModes: []) {
                            Marker("", systemImage: "photo", coordinate: spot)
                        }
                        .frame(height: 190)
                        .listRowInsets(EdgeInsets())
                        Link(destination: URL(string: "https://maps.apple.com/?ll=\(lat),\(lon)")!) {
                            Label("Open in Maps", systemImage: "map")
                        }
                    }
                }
                Section {
                    if let f = asset.filename { LabeledContent("File", value: f) }
                    LabeledContent("Kind", value: asset.kind == .live ? "Live Photo" : asset.kind.rawValue.capitalized)
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: asset.size, countStyle: .file))
                    if let w = asset.width, let h = asset.height { LabeledContent("Dimensions", value: "\(w) × \(h)") }
                    if let d = asset.duration { LabeledContent("Length", value: Duration.seconds(d).formatted(.time(pattern: .minuteSecond))) }
                    LabeledContent("On this iPhone", value: asset.localId == nil ? "No, in the cloud" : "Yes")
                }
            }
            .navigationTitle("Info").navigationBarTitleDisplayMode(.inline)
        }
    }
}
