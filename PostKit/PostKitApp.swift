// PostKitApp.swift — open a post-pack .zip, save slides to Photos in order, copy captions, open TikTok/IG.
// Requires Swift package: https://github.com/weichsel/ZIPFoundation (0.9.x)
import SwiftUI
import Photos
import UniformTypeIdentifiers
import ZIPFoundation
import Combine

struct Post: Identifiable, Hashable {
    let id: String          // folder path inside the pack, e.g. "Gridy_Evergreen/01_Youre-Not-Lazy"
    let slides: [URL]       // sorted by file name (01.jpg, 02.jpg … or P01_S01.jpg …)
    let ttTitle: String
    let ttDescription: String
    let igCaption: String
    var shortName: String { id.components(separatedBy: "/").last ?? id }
    var packID: String { id.components(separatedBy: "/").first ?? id }
}

/// One imported zip = one project.
struct Pack: Identifiable, Hashable {
    let id: String          // folder name under Packs/ (the zip's file name)
    let posts: [Post]
    var displayName: String { id.replacingOccurrences(of: "_", with: " ") }
    var cover: URL? { posts.first?.slides.first }
}

@MainActor
final class Store: ObservableObject {
    @Published var posts: [Post] = []
    @Published var packs: [Pack] = []
    @Published var posted: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "posted") ?? [])
    let root: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Packs", isDirectory: true)

    init() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    func importZip(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dest = root.appendingPathComponent(url.deletingPathExtension().lastPathComponent, isDirectory: true)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try FileManager.default.unzipItem(at: url, to: dest)
        reload()
    }

    func deletePack(named name: String) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        reload()
    }

    func reload() {
        let fm = FileManager.default
        var found: [Post] = []
        if let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.lastPathComponent == "caption.txt" {
                let dir = url.deletingLastPathComponent()
                let slides = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                    .filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                let (t, d, ig) = Self.parse((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                let rel = String(dir.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
                found.append(Post(id: rel, slides: slides, ttTitle: t, ttDescription: d, igCaption: ig))
            }
        }
        posts = found.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        // Group by top-level folder (one per imported zip). Newest import first.
        let groups = Dictionary(grouping: posts, by: \.packID)
        let date: (String) -> Date = { name in
            (try? fm.attributesOfItem(atPath: self.root.appendingPathComponent(name).path)[.creationDate] as? Date) ?? .distantPast
        }
        packs = groups.map { Pack(id: $0.key, posts: $0.value) }
            .sorted { date($0.id) > date($1.id) }
    }

    func pack(_ id: String) -> Pack? { packs.first { $0.id == id } }
    func postedCount(_ pack: Pack) -> Int { pack.posts.filter { posted.contains($0.id) }.count }

    /// caption.txt format:
    /// === TIKTOK ===\nTITLE:\n…\n\nDESCRIPTION:\n…(incl. tags)\n\n=== INSTAGRAM ===\n…
    static func parse(_ s: String) -> (String, String, String) {
        let parts = s.components(separatedBy: "=== INSTAGRAM ===")
        let tt = parts.first ?? ""
        let ig = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        guard let tr = tt.range(of: "TITLE:"), let dr = tt.range(of: "DESCRIPTION:") else {
            return ("", tt.replacingOccurrences(of: "=== TIKTOK ===", with: "").trimmingCharacters(in: .whitespacesAndNewlines), ig)
        }
        let title = String(tt[tr.upperBound..<dr.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let desc = String(tt[dr.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (title, desc, ig)
    }

    func togglePosted(_ p: Post) {
        if posted.contains(p.id) { posted.remove(p.id) } else { posted.insert(p.id) }
        UserDefaults.standard.set(Array(posted), forKey: "posted")
    }

    /// Saves slides as new assets 1 second apart (so Photos & TikTok pickers show them in order)
    /// and, with full access, into an album named after the post.
    func saveToPhotos(_ p: Post) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "PostKit", code: 1, userInfo: [NSLocalizedDescriptionKey: "Allow Photos access in Settings"])
        }
        try await Self.writeAssets(p.slides, album: status == .authorized ? p.shortName : nil)
    }

    // nonisolated so the change block isn't main-actor isolated (Photos runs it on a background queue).
    nonisolated static func writeAssets(_ slides: [URL], album: String?) async throws {
        let base = Date()
        try await PHPhotoLibrary.shared().performChanges {
            var placeholders: [PHObjectPlaceholder] = []
            for (i, url) in slides.enumerated() {
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .photo, fileURL: url, options: nil)
                req.creationDate = base.addingTimeInterval(Double(i))
                if let ph = req.placeholderForCreatedAsset { placeholders.append(ph) }
            }
            if let album {
                let req = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: album)
                req.addAssets(placeholders as NSArray)
            }
        }
    }
}

@main
struct PostKitApp: App {
    @StateObject private var store = Store()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .onOpenURL { url in try? store.importZip(url) }   // AirDrop / "Open in PostKit"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var importing = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Group {
                if store.packs.count > 1 {
                    PackGrid()
                } else if let only = store.packs.first {
                    PostListView(packID: only.id)
                } else {
                    ContentUnavailableView("No packs yet", systemImage: "tray",
                                           description: Text("AirDrop a .zip here or tap the import button."))
                }
            }
            .navigationDestination(for: String.self) { PostListView(packID: $0) }
            .navigationDestination(for: Post.self) { PostDetail(post: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { importing = true } label: { Image(systemName: "square.and.arrow.down") }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.zip]) { result in
                do { try store.importZip(result.get()) } catch { errorText = error.localizedDescription }
            }
            .alert("Import failed", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK") { errorText = nil }
            } message: { Text(errorText ?? "") }
        }
    }
}

/// Shown when there are 2+ imported projects: 2 per row.
struct PackGrid: View {
    @EnvironmentObject var store: Store
    @State private var confirmDelete: Pack?
    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(store.packs) { pack in
                    NavigationLink(value: pack.id) {
                        VStack(alignment: .leading, spacing: 8) {
                            Thumb(url: pack.cover)
                                .aspectRatio(9 / 16, contentMode: .fit)
                                .overlay(alignment: .topTrailing) {
                                    let done = store.postedCount(pack)
                                    if done == pack.posts.count {
                                        Image(systemName: "checkmark.circle.fill").font(.title2)
                                            .foregroundStyle(.white, .green).padding(8)
                                    }
                                }
                            Text(pack.displayName).font(.headline).lineLimit(2)
                                .multilineTextAlignment(.leading).foregroundStyle(.primary)
                            Text("\(store.postedCount(pack)) / \(pack.posts.count) posted")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) { confirmDelete = pack } label: { Label("Delete project", systemImage: "trash") }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Projects")
        .confirmationDialog("Delete \(confirmDelete?.displayName ?? "")?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let p = confirmDelete { store.deletePack(named: p.id) }
                confirmDelete = nil
            }
        }
    }
}

/// The post list for one project (also the home screen when there's only one project).
struct PostListView: View {
    @EnvironmentObject var store: Store
    let packID: String
    @State private var hidePosted = false
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let pack = store.pack(packID)
        let posts = pack?.posts ?? []
        let visible = hidePosted ? posts.filter { !store.posted.contains($0.id) } : posts
        List(visible) { p in
            NavigationLink(value: p) {
                HStack(spacing: 12) {
                    Thumb(url: p.slides.first).frame(width: 48, height: 85)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(p.ttTitle.isEmpty ? p.shortName : p.ttTitle).font(.headline).lineLimit(2)
                        Text("\(p.slides.count) slides · \(p.shortName)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.posted.contains(p.id) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
            }
        }
        .overlay {
            if !posts.isEmpty && visible.isEmpty {
                ContentUnavailableView("All posted 🎉", systemImage: "checkmark.seal",
                                       description: Text("Turn off \"Hide posted\" to see them again."))
            }
        }
        .navigationTitle(pack?.displayName ?? "Posts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Toggle("Hide posted", isOn: $hidePosted).toggleStyle(.button)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete project", systemImage: "trash") }
            }
        }
        .confirmationDialog("Delete this project?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.deletePack(named: packID)
                dismiss()
            }
        }
    }
}

struct PostDetail: View {
    @EnvironmentObject var store: Store
    let post: Post
    @State private var toast: String?
    @State private var saving = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(post.slides.enumerated()), id: \.offset) { i, url in
                            Thumb(url: url).frame(width: 124, height: 220)
                                .overlay(alignment: .topLeading) {
                                    Text("\(i + 1)").font(.caption.bold()).foregroundStyle(.white)
                                        .frame(width: 24, height: 24).background(.black.opacity(0.65), in: Circle()).padding(6)
                                }
                        }
                    }
                }

                Button {
                    saving = true
                    Task {
                        do { try await store.saveToPhotos(post); flash("Saved \(post.slides.count) slides in order") }
                        catch { flash(error.localizedDescription) }
                        saving = false
                    }
                } label: {
                    Label(saving ? "Saving…" : "1. Save slides to Photos", systemImage: "photo.on.rectangle.angled")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(saving)

                CopyBox(label: "2. TikTok title", text: post.ttTitle, flash: flash)
                CopyBox(label: "3. TikTok description", text: post.ttDescription, flash: flash)
                HStack {
                    Button { open("tiktok://") } label: { Label("Open TikTok", systemImage: "arrow.up.forward.app") }
                    Button { open("instagram://") } label: { Label("Open Instagram", systemImage: "arrow.up.forward.app") }
                }
                .buttonStyle(.bordered)
                CopyBox(label: "Instagram caption", text: post.igCaption, flash: flash)

                Button(store.posted.contains(post.id) ? "Mark as NOT posted" : "Mark as posted ✓") { store.togglePosted(post) }
                    .buttonStyle(.bordered).tint(.green)
            }
            .padding()
        }
        .navigationTitle(post.shortName)
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let t = toast {
                Text(t).font(.subheadline.bold()).padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.thinMaterial, in: Capsule()).padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring, value: toast)
    }

    func flash(_ s: String) {
        toast = s
        Task { try? await Task.sleep(for: .seconds(2)); if toast == s { toast = nil } }
    }
    func open(_ s: String) { if let u = URL(string: s) { UIApplication.shared.open(u) } }
}

struct CopyBox: View {
    let label: String
    let text: String
    let flash: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.subheadline.bold())
                Spacer()
                Button {
                    UIPasteboard.general.string = text
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    flash("Copied \(label.lowercased())")
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                .font(.subheadline)
            }
            Text(text.isEmpty ? "—" : text).font(.callout).textSelection(.enabled)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

/// Downsampled thumbnail so long lists of 1080×1920 slides stay light.
struct Thumb: View {
    let url: URL?
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color(.tertiarySystemFill))
            if let image { Image(uiImage: image).resizable().scaledToFill() }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: url) {
            guard let url else { return }
            image = await Task.detached(priority: .userInitiated) { Thumb.downsample(url, maxPixel: 600) }.value
        }
    }
    nonisolated static func downsample(_ url: URL, maxPixel: Int) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
