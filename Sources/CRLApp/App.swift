import AppKit
import CRLKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct CRLMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Complete Reference Library", id: "main") {
            RootView().environmentObject(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 640 * defaultScale, height: 480 * defaultScale)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import Disc Image…") { chooseDisc(model) }.keyboardShortcut("o")
            }
            CommandMenu("Library") {
                Button("Index") { model.panel = .index }.keyboardShortcut("f")
                Button("Table of Contents") { model.panel = .contents }.keyboardShortcut("t")
                Button("Reference Trails") { model.panel = .trails }.keyboardShortcut("y")
                Button("Bookmark Article") { model.addBookmark() }.keyboardShortcut("d")
                Button("Media Library") { model.screen = .mediaLibrary }.keyboardShortcut("m", modifiers: [.command, .shift])
                Divider()
                Toggle("Button Sounds", isOn: $model.buttonSounds)
            }
        }
        Settings {
            Form { Toggle("Button sounds", isOn: $model.buttonSounds) }.padding().frame(width: 280)
                .environmentObject(model)
        }
    }

    var defaultScale: CGFloat {
        let h = NSScreen.main?.visibleFrame.height ?? 960
        return max(1, min(2, (h - 40) / 480))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor
func chooseDisc(_ model: AppModel) {
    let p = NSOpenPanel()
    p.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .data, .data]
    p.message = "Choose the Complete Reference Library (1995) disc image"
    if p.runModal() == .OK, let u = p.url { model.importDisc(u) }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width / 640, g.size.height / 480)
            ZStack {
                Color.black
                switch model.screen {
                case .welcome, .importing: WelcomeView(s: s)
                case .room: RoomView(s: s)
                case .mediaLibrary: MediaLibraryView(s: s)
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
        .frame(minWidth: 640, minHeight: 480)
        .ignoresSafeArea()
        .background(WindowConfigurator(active: $model.windowActive))
        .onAppear { Art.directory = AppModel.libraryURL; Snapshot.runIfRequested(model) }
    }
}

/// Keeps the window at 4:3 and hides the title-bar buttons: the room bitmap draws its own
/// system-menu box and minimize arrow in the corners.
struct WindowConfigurator: NSViewRepresentable {
    @Binding var active: Bool
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.contentAspectRatio = NSSize(width: 640, height: 480)
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = false
            for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { w.standardWindowButton(b)?.isHidden = true }
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { active = true }
            }
            NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { active = false }
            }
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// First run: the original splash (once a library exists) or a plain prompt to import the disc.
struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    let s: CGFloat
    @State private var dropping = false

    var body: some View {
        VStack(spacing: 18 * s) {
            if let splash = Art.image(477) {
                Image(nsImage: splash).resizable().interpolation(.none).frame(width: 500 * s * 0.8, height: 375 * s * 0.8)
            } else {
                Text("Complete Reference Library").font(.custom("Times New Roman", size: 30 * s)).foregroundStyle(.white)
                Text("for macOS").font(.custom("Times New Roman", size: 16 * s)).foregroundStyle(.gray)
            }
            if model.screen == .importing {
                VStack(spacing: 6 * s) {
                    ProgressView(value: model.importFraction).frame(width: 360 * s)
                    Text(model.importStatus).font(.system(size: 11 * s)).foregroundStyle(.white)
                }
            } else {
                Text("Drop the Complete Reference Library (1995) disc image here")
                    .font(.system(size: 13 * s)).foregroundStyle(.white)
                Button("Choose Disc Image…") { chooseDisc(model) }.controlSize(.large)
                if LibraryBuilder.findFFmpeg() == nil {
                    Text("Tip: install ffmpeg (brew install ffmpeg) before importing to play the videos and animations.")
                        .font(.system(size: 10 * s)).foregroundStyle(.gray)
                }
                if let e = model.importError { Text(e).font(.system(size: 11 * s)).foregroundStyle(.red) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dropping ? Color(white: 0.15) : .black)
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in model.importDisc(url) } }
            }
            return true
        }
    }
}
