import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CoreAudio
import Accelerate

// Claude Code hooks write "working" / "done" to this file.
let statusPath = NSHomeDirectory() + "/.claude/island-status"
let musicPink = Color(red: 0.98, green: 0.34, blue: 0.42)
let spring = Animation.spring(response: 0.5, dampingFraction: 0.75)
let hoverSpring = Animation.spring(response: 0.42, dampingFraction: 0.84)

// Fades and un-blurs content in, like the real Dynamic Island.
struct BlurFade: ViewModifier {
    let radius: CGFloat
    func body(content: Content) -> some View { content.blur(radius: radius).opacity(radius == 0 ? 1 : 0) }
}
let blurFade = AnyTransition.modifier(active: BlurFade(radius: 8), identity: BlurFade(radius: 0))

enum Status: String { case idle, working, done }

final class Model: ObservableObject {
    @Published var status: Status = .idle
    @Published var playing = false
    @Published var title = ""
    @Published var artist = ""
    @Published var artwork: NSImage?
    @Published var tint = musicPink
    @Published var mouse = CGPoint.zero
    @Published var files: [URL] = []
    @Published var dragging = false
    let levels = AudioLevels()
    private var dragCount = 0
    private var timers: [Timer] = []
    private let musicQueue = DispatchQueue(label: "music")

    init() {
        timers = [
            .scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() },
            .scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.pollMusic() },
        ]

        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] e in
            self?.mouseEvent(e)
        }
    }

    // A drag with something in hand bumps the drag pasteboard, so that's how we spot a file being carried.
    private func mouseEvent(_ e: NSEvent) {
        let count = NSPasteboard(name: .drag).changeCount
        switch e.type {
        case .leftMouseDown: dragCount = count
        case .leftMouseDragged: if count != dragCount && !dragging { dragging = true }
        default: if dragging { dragging = false }
        }
        mouse = NSEvent.mouseLocation
    }

    func add(_ url: URL) {
        withAnimation(hoverSpring) { if !files.contains(url) { files.append(url) } }
    }

    func remove(_ url: URL) {
        withAnimation(hoverSpring) { files.removeAll { $0 == url } }
    }

    private func poll() {
        let raw = (try? String(contentsOfFile: statusPath, encoding: .utf8)) ?? ""
        let new = Status(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .idle
        guard new != status else { return }

        withAnimation(spring) { status = new }

        // Tuck back into the notch a few seconds after finishing.
        if new == .done {
            // Double tap on the Force Touch trackpad (only felt while a finger is resting on it).
            let haptics = NSHapticFeedbackManager.defaultPerformer
            haptics.perform(.levelChange, performanceTime: .now)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                haptics.perform(.levelChange, performanceTime: .now)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if self.status == .done { try? "idle".write(toFile: statusPath, atomically: true, encoding: .utf8) }
            }
        }
    }

    // Ask Music directly; its change notifications aren't reliable.
    private func pollMusic() {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty else {
            return musicChanged(nil)
        }
        musicQueue.async {
            let script = NSAppleScript(source: """
                tell application "Music"
                    if player state is not playing then return ""
                    return name of current track & linefeed & artist of current track
                end tell
                """)
            let out = script?.executeAndReturnError(nil).stringValue ?? ""
            DispatchQueue.main.async { self.musicChanged(out.isEmpty ? nil : out.components(separatedBy: "\n")) }
        }
    }

    private func musicChanged(_ track: [String]?) {
        let newTitle = track?.first ?? title
        let trackChanged = newTitle != title
        guard (track != nil) != playing || trackChanged else { return }

        withAnimation(spring) {
            playing = track != nil
            title = newTitle
            artist = track?.last ?? artist
        }
        playing ? levels.start() : levels.stop()
        if trackChanged { fetchArtwork() }
    }

    private func fetchArtwork() {
        musicQueue.async {
            let script = NSAppleScript(source: "tell application \"Music\" to get data of artwork 1 of current track")
            let data = script?.executeAndReturnError(nil).data
            let image = data.flatMap { NSImage(data: $0) }
            DispatchQueue.main.async {
                withAnimation(spring) {
                    self.artwork = image
                    self.tint = image.map(averageColor) ?? musicPink
                }
            }
        }
    }
}

// Shrink the cover to one pixel, then brighten it so it pops on black.
func averageColor(_ image: NSImage) -> Color {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return musicPink }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
    let c = NSColor(red: CGFloat(p[0]) / 255, green: CGFloat(p[1]) / 255, blue: CGFloat(p[2]) / 255, alpha: 1)
    return Color(hue: c.hueComponent, saturation: max(c.saturationComponent, 0.45), brightness: max(c.brightnessComponent, 0.9))
}

// The Claude Code mascot GIF, bundled in Island.app or kept next to the binary. Shown while Claude is working.
let gifURL = Bundle.main.url(forResource: "claude", withExtension: "gif")
    ?? URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().appendingPathComponent("claude.gif")

struct ClaudeGIF: NSViewRepresentable {
    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(contentsOf: gifURL)
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.animates = true
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {}
}

// Taps Music's audio output and splits it into four bands, bass to treble, for the bars.
final class AudioLevels: ObservableObject {
    // Empty until real audio arrives, so the bars can fall back to a fake wiggle.
    @Published var bands: [Float] = []
    private let queue = DispatchQueue(label: "audio")
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private var rate: Float = 48000
    private var heard = false

    private let n = 1024
    private lazy var samples = [Float](repeating: 0, count: n)
    private lazy var fft = vDSP.FFT(log2n: vDSP_Length(log2(Float(n))), radix: .radix2, ofType: DSPSplitComplex.self)!
    private lazy var hann = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
    private let edges: [Float] = [40, 250, 1000, 4000, 14000]
    private var peaks: [Float] = [1e-3, 1e-3, 1e-3, 1e-3]
    private var shown: [Float] = [0, 0, 0, 0]

    func start() { queue.async { if self.proc == nil { self.setUp() } } }

    func stop() {
        queue.async {
            self.tearDown()
            DispatchQueue.main.async { self.bands = [] }
        }
    }

    private func setUp() {
        let processes = musicProcesses()
        guard !processes.isEmpty, let output = defaultOutputUID() else { return }

        let desc = CATapDescription(stereoMixdownOfProcesses: processes)
        desc.isPrivate = true
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr else { return }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = address(kAudioTapPropertyFormat)
        if AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &format) == noErr, format.mSampleRate > 0 {
            rate = Float(format.mSampleRate)
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Island Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device) == noErr,
              AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue, { [weak self] _, input, _, _, _ in self?.process(input) }) == noErr,
              AudioDeviceStart(device, proc) == noErr
        else { return tearDown() }
    }

    private func tearDown() {
        if let proc {
            AudioDeviceStop(device, proc)
            AudioDeviceDestroyIOProcID(device, proc)
        }
        if device != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(device) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        proc = nil
        device = AudioObjectID(kAudioObjectUnknown)
        tap = AudioObjectID(kAudioObjectUnknown)
        heard = false
    }

    private func process(_ input: UnsafePointer<AudioBufferList>) {
        guard let buffer = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)).first,
              let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { return }
        // Keep the newest `n` samples of the left channel.
        let channels = Int(max(buffer.mNumberChannels, 1))
        let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
        let fresh = (max(frames - n, 0)..<frames).map { data[$0 * channels] }
        samples.removeFirst(fresh.count)
        samples.append(contentsOf: fresh)

        // Taps hand back silence until audio capture is allowed, so stay on the fake bars until we hear something.
        if !heard { heard = fresh.contains { $0 != 0 } }
        guard heard else { return }

        let power = spectrum()
        let bin = Float(n) / rate
        for i in 0..<4 {
            let lo = Int(edges[i] * bin), hi = min(Int(edges[i + 1] * bin), power.count)
            let level = sqrt(power[lo..<max(hi, lo + 1)].reduce(0, +) / Float(max(hi - lo, 1)))
            // Auto-gain against a slowly falling peak, so quiet and loud songs both fill the bars.
            peaks[i] = max(level, peaks[i] * 0.997, 1e-3)
            let target = min(sqrt(level / peaks[i]), 1)
            // Jump up fast, fall back gently.
            shown[i] += (target - shown[i]) * (target > shown[i] ? 0.6 : 0.15)
        }
        let out = shown
        DispatchQueue.main.async { self.bands = out }
    }

    private func spectrum() -> [Float] {
        let windowed = vDSP.multiply(samples, hann)
        var real = [Float](repeating: 0, count: n / 2), imag = real, power = real
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                windowed.withUnsafeBytes { vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(n / 2)) }
                let input = split
                fft.forward(input: input, output: &split)
                vDSP.squareMagnitudes(split, result: &power)
            }
        }
        return power
    }

    // Music and any helpers it plays through.
    private func musicProcesses() -> [AudioObjectID] {
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { (string($0, kAudioProcessPropertyBundleID) ?? "").hasPrefix("com.apple.Music") }
    }

    private func defaultOutputUID() -> String? {
        var addr = address(kAudioHardwarePropertyDefaultSystemOutputDevice)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
        return string(id, kAudioDevicePropertyDeviceUID)
    }

    private func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}

struct Bars: View {
    @ObservedObject var levels: AudioLevels
    let color: Color

    var body: some View {
        TimelineView(.animation(paused: !levels.bands.isEmpty)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<4) { i in
                    let level = levels.bands.isEmpty ? abs(sin(t * 5 + Double(i) * 1.3)) : Double(levels.bands[i])
                    Capsule()
                        .fill(color)
                        .frame(width: 2.5, height: 4 + 9 * level)
                }
            }
            .frame(height: 13)
        }
    }
}

struct Artwork: View {
    let image: NSImage?
    let tint: Color
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                tint.opacity(0.25).overlay(Image(systemName: "music.note").foregroundStyle(tint))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

// Notch silhouette: rounded bottom corners, and top corners that flare outward into the screen edge.
struct NotchShape: Shape {
    var flare: CGFloat
    var radius: CGFloat
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        let f = flare, b = radius
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + f, y: r.minY + f), control: CGPoint(x: r.minX + f, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + f, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + f + b, y: r.maxY), control: CGPoint(x: r.minX + f, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - f - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - f, y: r.maxY - b), control: CGPoint(x: r.maxX - f, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - f, y: r.minY + f))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - f, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct ShelfItem: View {
    let url: URL
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 32, height: 32)
            Text(url.lastPathComponent)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(width: 52)
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button(action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .gray) }
                    .buttonStyle(.plain)
                    .transition(.opacity)
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        // Dragging out hands over the file but keeps it on the shelf.
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
    }
}

struct IslandView: View {
    @ObservedObject var model: Model
    let notch: CGSize
    let screen: CGRect
    let panel: NSPanel
    @State private var hovered = false
    @State private var targeted = false

    private let flare: CGFloat = 6
    private let pop = AnyTransition.scale.combined(with: .opacity)
    // The black shape does the morphing. Old content vanishes fast, new content un-blurs once there's room.
    private let swap = AnyTransition.asymmetric(
        insertion: blurFade.animation(.easeOut(duration: 0.25).delay(0.15)),
        removal: .opacity.animation(.easeOut(duration: 0.08)))
    private var claude: Bool { model.status != .idle }
    private var music: Bool { model.playing }
    // `targeted` counts too, so a drop still opens the shelf when drag detection misses it.
    private var shelf: Bool { !model.files.isEmpty || model.dragging || targeted }
    private var open: Bool { hovered && (claude || music || shelf) }

    // Both sides always match: Claude (or the album cover) on the left, music bars on the right.
    private var ear: CGFloat { claude || music ? 36 : 0 }
    private var width: CGFloat { open ? notch.width + 120 : notch.width + ear * 2 }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                ZStack {
                    if !open { compact.transition(swap) }
                }
                .frame(height: notch.height)
                if open {
                    details.transition(swap)
                }
            }
            .frame(width: width)
            .background(NotchShape(flare: flare, radius: open ? 18 : 10).fill(.black).padding(.horizontal, -flare))
            .contextMenu { Button("Quit Island") { NSApp.terminate(nil) } }
            .scaleEffect(targeted ? 1.03 : 1, anchor: .top)
            .animation(hoverSpring, value: targeted)
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url { DispatchQueue.main.async { model.add(url) } }
                    }
                }
                model.dragging = false
                return true
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .onChange(of: model.mouse) { updateHover() }
    }

    private func updateHover() {
        // Use the target size, not the mid-animation one, so hover doesn't flicker while growing.
        let m = model.mouse
        let rows = [claude, music, shelf].filter { $0 }.count
        let openZone = CGSize(width: notch.width + 120, height: notch.height + CGFloat(rows) * 56 + 16)
        let zone = hovered || model.dragging ? openZone : CGSize(width: width, height: notch.height)
        let inside = abs(m.x - screen.midX) < zone.width / 2 + flare && m.y >= screen.maxY - zone.height
        // Only catch the mouse while it's over the island, so the menu bar stays clickable.
        panel.ignoresMouseEvents = !inside
        if inside != hovered { withAnimation(hoverSpring) { hovered = inside } }
    }

    private var compact: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                if claude {
                    claudeIcon.transition(pop)
                } else if music {
                    cover.transition(pop)
                }
            }
            .frame(width: ear)
            Color.clear.frame(width: notch.width)
            HStack(spacing: 6) {
                if music {
                    Bars(levels: model.levels, color: model.tint).transition(pop)
                }
            }
            .frame(width: ear)
        }
        .frame(height: notch.height)
    }

    private var cover: some View {
        Artwork(image: model.artwork, tint: model.tint, size: 18)
    }

    private var details: some View {
        VStack(spacing: 10) {
            if music {
                HStack(spacing: 10) {
                    Artwork(image: model.artwork, tint: model.tint, size: 34)
                        .shadow(color: model.tint.opacity(0.5), radius: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        Text(model.artist).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    Bars(levels: model.levels, color: model.tint)
                }
            }
            if claude {
                HStack(spacing: 10) {
                    claudeIcon.frame(width: 34)
                    Text(model.status == .working ? "Claude is working…" : "Claude is done")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer(minLength: 0)
                }
            }
            if shelf { shelfRow }
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }

    @ViewBuilder private var shelfRow: some View {
        if model.files.isEmpty {
            Label("Drop files here", systemImage: "tray.and.arrow.down")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(targeted ? 1 : 0.6))
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4])))
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.files, id: \.self) { url in
                        ShelfItem(url: url) { model.remove(url) }.transition(pop)
                    }
                }
            }
        }
    }

    // The working GIF, swapped for a checkmark once Claude is done.
    private var claudeIcon: some View {
        ZStack {
            if model.status == .working {
                ClaudeGIF().frame(width: 26, height: 26).transition(pop)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.green)
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
            }
        }
        .frame(width: 26, height: 26)
    }
}

// Private SkyLight calls: a dedicated top-level space keeps the island pinned while you swipe between desktops.
@_silgen_name("_CGSDefaultConnection") func _CGSDefaultConnection() -> Int32
@_silgen_name("CGSSpaceCreate") func CGSSpaceCreate(_ cid: Int32, _ flag: Int, _ options: NSDictionary?) -> Int
@_silgen_name("CGSSpaceSetAbsoluteLevel") func CGSSpaceSetAbsoluteLevel(_ cid: Int32, _ space: Int, _ level: Int)
@_silgen_name("CGSShowSpaces") func CGSShowSpaces(_ cid: Int32, _ spaces: NSArray)
@_silgen_name("CGSAddWindowsToSpaces") func CGSAddWindowsToSpaces(_ cid: Int32, _ windows: NSArray, _ spaces: NSArray)

func pinAboveSpaces(_ window: NSWindow) {
    let cid = _CGSDefaultConnection()
    let space = CGSSpaceCreate(cid, 1, nil)
    CGSSpaceSetAbsoluteLevel(cid, space, Int(Int32.max))
    CGSShowSpaces(cid, [space] as NSArray)
    CGSAddWindowsToSpaces(cid, [window.windowNumber] as NSArray, [space] as NSArray)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel!

    func applicationDidFinishLaunching(_ note: Notification) {
        let screen = NSScreen.main!
        let notchHeight = max(screen.safeAreaInsets.top, 32)
        let left = screen.auxiliaryTopLeftArea?.width ?? 0
        let right = screen.auxiliaryTopRightArea?.width ?? 0
        let notchWidth = left > 0 ? screen.frame.width - left - right : 190

        // Big enough for the hovered state. It only takes the mouse while you're over the island.
        let size = CGSize(width: notchWidth + 160, height: notchHeight + 200)
        let frame = CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)

        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        let model = Model()
        panel.contentView = NSHostingView(rootView: IslandView(model: model, notch: CGSize(width: notchWidth, height: notchHeight),
                                                               screen: screen.frame, panel: panel))
        panel.orderFrontRegardless()
        pinAboveSpaces(panel)

        // Tuck the card away when switching desktops.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil, queue: .main) { _ in model.mouse = .zero }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
