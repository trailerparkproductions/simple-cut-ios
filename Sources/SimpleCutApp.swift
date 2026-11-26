import SwiftUI
import PhotosUI
import AVFoundation
import Photos
import UniformTypeIdentifiers

// MARK: - Model

enum ClipKind {
    case video
    case photo
}

struct ClipItem: Identifiable {
    let id = UUID()
    var kind: ClipKind
    var url: URL
    var thumbnail: UIImage?
    var duration: Double // video length in seconds, or photo display time
    var trimStart: Double = 0
    var trimEnd: Double = 0 // for video; 0 means use duration
    var photoSeconds: Double = 3
    var text: String = ""

    var playSeconds: Double {
        if kind == .photo { return photoSeconds }
        let end = trimEnd > 0 ? trimEnd : duration
        return max(0.1, end - trimStart)
    }
}

// MARK: - View model

@MainActor
final class EditorViewModel: ObservableObject {
    @Published var clips: [ClipItem] = []
    @Published var musicURL: URL?
    @Published var musicName: String = ""
    @Published var isExporting = false
    @Published var message: String = ""
    @Published var exportedURL: URL?

    func addPickerItems(_ items: [PhotosPickerItem]) async {
        for item in items {
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { continue }
                let ext = isVideo ? "mov" : "jpg"
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(ext)
                try data.write(to: url)
                if isVideo {
                    let asset = AVURLAsset(url: url)
                    let dur = CMTimeGetSeconds(asset.duration)
                    let seconds = dur.isFinite && dur > 0 ? dur : 5
                    let thumb = Self.videoThumbnail(url: url)
                    clips.append(ClipItem(kind: .video, url: url, thumbnail: thumb,
                                          duration: seconds, trimStart: 0, trimEnd: seconds))
                } else {
                    let img = UIImage(data: data)
                    clips.append(ClipItem(kind: .photo, url: url, thumbnail: img,
                                          duration: 3, trimStart: 0, trimEnd: 3, photoSeconds: 3))
                }
            } catch {
                message = "One file did not load. Try again."
            }
        }
    }

    static func videoThumbnail(url: URL) -> UIImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        if let cg = try? gen.copyCGImage(at: time, actualTime: nil) {
            return UIImage(cgImage: cg)
        }
        return nil
    }

    func setMusic(url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension.isEmpty ? "m4a" : url.pathExtension)
        try? FileManager.default.copyItem(at: url, to: copy)
        if ok { url.stopAccessingSecurityScopedResource() }
        musicURL = copy
        musicName = url.lastPathComponent
    }

    func exportVideo() async {
        guard !clips.isEmpty else { message = "Add a video or photo first."; return }
        isExporting = true
        exportedURL = nil
        message = "Making your video..."
        do {
            let out = try await Self.buildVideo(clips: clips, musicURL: musicURL)
            exportedURL = out
            try await Self.saveToPhotos(url: out)
            message = "Done. Saved to Photos."
        } catch {
            message = "Export failed: \(error.localizedDescription)"
        }
        isExporting = false
    }

    static func saveToPhotos(url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "SimpleCut", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Photos access is off. Turn it on in Settings."])
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }

    // MARK: Export engine

    static func buildVideo(clips: [ClipItem], musicURL: URL?) async throws -> URL {
        let renderSize = Self.renderSize(for: clips)
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw NSError(domain: "SimpleCut", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not start video."]) }

        var instructions: [AVMutableVideoCompositionInstruction] = []
        var textInfos: [(String, Double, Double)] = []
        var current = CMTime.zero

        for clip in clips {
            var clipURL = clip.url
            var range: CMTimeRange
            if clip.kind == .photo {
                guard let img = UIImage(contentsOfFile: clip.url.path) ?? clip.thumbnail,
                      let made = try? Self.makePhotoVideo(image: img, seconds: clip.photoSeconds, size: renderSize)
                else { continue }
                clipURL = made
                range = CMTimeRange(start: .zero, duration: CMTime(seconds: clip.photoSeconds, preferredTimescale: 600))
            } else {
                let end = clip.trimEnd > 0 ? clip.trimEnd : clip.duration
                range = CMTimeRange(start: CMTime(seconds: clip.trimStart, preferredTimescale: 600),
                                    duration: CMTime(seconds: max(0.1, end - clip.trimStart), preferredTimescale: 600))
            }

            let asset = AVURLAsset(url: clipURL)
            if let vTrack = asset.tracks(withMediaType: .video).first {
                try videoTrack.insertTimeRange(range, of: vTrack, at: current)
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = CMTimeRange(start: current, duration: range.duration)
                let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
                layerInstruction.setTransform(Self.fillTransform(track: vTrack, renderSize: renderSize), at: current)
                instruction.layerInstructions = [layerInstruction]
                instructions.append(instruction)
            }
            if let aTrack = asset.tracks(withMediaType: .audio).first {
                try? audioTrack.insertTimeRange(range, of: aTrack, at: current)
            }
            let startSec = CMTimeGetSeconds(current)
            if !clip.text.trimmingCharacters(in: .whitespaces).isEmpty {
                textInfos.append((clip.text, startSec, CMTimeGetSeconds(range.duration)))
            }
            current = CMTimeAdd(current, range.duration)
        }

        if let musicURL {
            let musicAsset = AVURLAsset(url: musicURL)
            if let mTrack = musicAsset.tracks(withMediaType: .audio).first,
               let musicTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let musicDur = musicAsset.duration
                let useDur = CMTimeMinimum(musicDur, current)
                if useDur.seconds > 0 {
                    try? musicTrack.insertTimeRange(CMTimeRange(start: .zero, duration: useDur), of: mTrack, at: .zero)
                }
            }
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = instructions

        if !textInfos.isEmpty {
            let parent = CALayer()
            parent.frame = CGRect(origin: .zero, size: renderSize)
            let videoLayer = CALayer()
            videoLayer.frame = CGRect(origin: .zero, size: renderSize)
            parent.addSublayer(videoLayer)
            for (text, start, dur) in textInfos {
                let layer = CATextLayer()
                layer.string = text
                layer.fontSize = 64
                layer.alignmentMode = .center
                layer.foregroundColor = UIColor.white.cgColor
                layer.backgroundColor = UIColor.black.withAlphaComponent(0.55).cgColor
                layer.cornerRadius = 12
                layer.frame = CGRect(x: 40, y: 70, width: renderSize.width - 80, height: 130)
                layer.contentsScale = 2
                layer.opacity = 0
                let anim = CABasicAnimation(keyPath: "opacity")
                anim.fromValue = 1
                anim.toValue = 1
                anim.beginTime = start
                anim.duration = dur
                anim.fillMode = .both
                anim.isRemovedOnCompletion = false
                layer.add(anim, forKey: "show")
                parent.addSublayer(layer)
            }
            videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)
        }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleCut-\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: outURL)

        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw NSError(domain: "SimpleCut", code: 3, userInfo: [NSLocalizedDescriptionKey: "Export could not start."])
        }
        session.outputURL = outURL
        session.outputFileType = .mp4
        session.videoComposition = videoComposition
        session.shouldOptimizeForNetworkUse = true

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }
        if session.status == .completed {
            return outURL
        }
        throw session.error ?? NSError(domain: "SimpleCut", code: 4, userInfo: [NSLocalizedDescriptionKey: "Export failed."])
    }

    static func renderSize(for clips: [ClipItem]) -> CGSize {
        for clip in clips where clip.kind == .video {
            let asset = AVURLAsset(url: clip.url)
            if let track = asset.tracks(withMediaType: .video).first {
                let size = track.naturalSize.applying(track.preferredTransform)
                var w = abs(size.width), h = abs(size.height)
                if w > 0, h > 0 {
                    let maxDim: CGFloat = 1920
                    let scale = min(1, maxDim / max(w, h))
                    w = (w * scale / 2).rounded() * 2
                    h = (h * scale / 2).rounded() * 2
                    return CGSize(width: w, height: h)
                }
            }
        }
        return CGSize(width: 1080, height: 1920)
    }

    static func fillTransform(track: AVAssetTrack, renderSize: CGSize) -> CGAffineTransform {
        let natural = track.naturalSize
        let t = track.preferredTransform
        let transformed = natural.applying(t)
        let w = abs(transformed.width), h = abs(transformed.height)
        guard w > 0, h > 0 else { return t }
        let scale = max(renderSize.width / w, renderSize.height / h)
        var result = t.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let rect = CGRect(origin: .zero, size: natural).applying(result)
        result.tx += (renderSize.width - rect.width) / 2 - rect.origin.x
        result.ty += (renderSize.height - rect.height) / 2 - rect.origin.y
        return result
    }

    static func makePhotoVideo(image: UIImage, seconds: Double, size: CGSize) throws -> URL {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        let writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        guard let buffer = Self.pixelBuffer(from: image, size: size) else {
            throw NSError(domain: "SimpleCut", code: 5, userInfo: [NSLocalizedDescriptionKey: "Photo could not be used."])
        }
        let fps: Int32 = 30
        let totalFrames = Int(seconds * Double(fps))
        for frame in 0..<max(1, totalFrames) {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
            let time = CMTime(value: CMTimeValue(frame), timescale: fps)
            adaptor.append(buffer, withPresentationTime: time)
        }
        input.markAsFinished()
        let sema = DispatchSemaphore(value: 0)
        writer.finishWriting { sema.signal() }
        sema.wait()
        return out
    }

    static func pixelBuffer(from image: UIImage, size: CGSize) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
                            kCVPixelFormatType_32ARGB, attrs as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                  width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        else { return nil }
        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        if let cg = image.cgImage {
            let imgSize = CGSize(width: cg.width, height: cg.height)
            let scale = max(size.width / imgSize.width, size.height / imgSize.height)
            let drawSize = CGSize(width: imgSize.width * scale, height: imgSize.height * scale)
            let rect = CGRect(x: (size.width - drawSize.width) / 2,
                              y: (size.height - drawSize.height) / 2,
                              width: drawSize.width, height: drawSize.height)
            ctx.draw(cg, in: rect)
        }
        return buffer
    }
}

// MARK: - Views

@main
struct SimpleCutApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @StateObject private var vm = EditorViewModel()
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPicker = false
    @State private var showMusicPicker = false
    @State private var editing: ClipItem?

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                if vm.clips.isEmpty {
                    Spacer()
                    Text("Simple Cut").font(.largeTitle).bold()
                    Text("Pick videos and photos.\nPut them in order. Save.")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                    Spacer()
                } else {
                    List {
                        ForEach(vm.clips) { clip in
                            Button { editing = clip } label: {
                                HStack(spacing: 12) {
                                    if let img = clip.thumbnail {
                                        Image(uiImage: img)
                                            .resizable().scaledToFill()
                                            .frame(width: 64, height: 64).clipped().cornerRadius(8)
                                    } else {
                                        Color.gray.frame(width: 64, height: 64).cornerRadius(8)
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(clip.kind == .photo ? "Photo" : "Video").bold()
                                        Text(String(format: "%.1f seconds", clip.playSeconds))
                                            .foregroundColor(.secondary)
                                        if !clip.text.isEmpty {
                                            Text(clip.text).lineLimit(1).foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Text("Edit").foregroundColor(.blue)
                                }
                            }
                        }
                        .onDelete { vm.clips.remove(atOffsets: $0) }
                        .onMove { vm.clips.move(fromOffsets: $0, toOffset: $1) }
                    }
                    .listStyle(.plain)
                }

                if !vm.musicName.isEmpty {
                    Text("Music: \(vm.musicName)").font(.footnote).foregroundColor(.secondary).lineLimit(1)
                }
                if !vm.message.isEmpty {
                    Text(vm.message).font(.footnote).foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                if vm.isExporting { ProgressView() }

                HStack(spacing: 10) {
                    Button("Add clips") { showPicker = true }
                        .buttonStyle(.borderedProminent)
                    Button("Add music") { showMusicPicker = true }
                        .buttonStyle(.bordered)
                }
                Button("Make video") { Task { await vm.exportVideo() } }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(vm.clips.isEmpty || vm.isExporting)

                if let url = vm.exportedURL {
                    ShareLink(item: url) { Text("Share finished video") }
                }
            }
            .padding()
            .navigationTitle("Simple Cut")
            .toolbar { EditButton() }
            .photosPicker(isPresented: $showPicker, selection: $pickerItems,
                          maxSelectionCount: 20, matching: .any(of: [.videos, .images]))
            .onChange(of: pickerItems) { items in
                guard !items.isEmpty else { return }
                Task {
                    await vm.addPickerItems(items)
                    pickerItems = []
                }
            }
            .fileImporter(isPresented: $showMusicPicker, allowedContentTypes: [.audio]) { result in
                if case .success(let url) = result { vm.setMusic(url: url) }
            }
            .sheet(item: $editing) { clip in
                EditClipView(clip: clip) { updated in
                    if let i = vm.clips.firstIndex(where: { $0.id == updated.id }) {
                        vm.clips[i] = updated
                    }
                }
            }
        }
    }
}

struct EditClipView: View {
    @Environment(\.dismiss) private var dismiss
    @State var clip: ClipItem
    var onSave: (ClipItem) -> Void

    var body: some View {
        NavigationView {
            Form {
                if let img = clip.thumbnail {
                    Image(uiImage: img).resizable().scaledToFit().frame(maxHeight: 220)
                }
                if clip.kind == .video {
                    Section("Trim video") {
                        Text("Start: \(clip.trimStart, specifier: "%.1f")s")
                        Slider(value: $clip.trimStart, in: 0...max(0.1, clip.duration - 0.1))
                        Text("End: \(clip.trimEnd, specifier: "%.1f")s")
                        Slider(value: $clip.trimEnd, in: 0.1...max(0.2, clip.duration))
                    }
                } else {
                    Section("Photo time") {
                        Picker("Show for", selection: $clip.photoSeconds) {
                            Text("2 seconds").tag(2.0)
                            Text("3 seconds").tag(3.0)
                            Text("5 seconds").tag(5.0)
                            Text("8 seconds").tag(8.0)
                        }
                        .pickerStyle(.segmented)
                    }
                }
                Section("Text on this clip") {
                    TextField("Type text (optional)", text: $clip.text)
                }
            }
            .navigationTitle(clip.kind == .photo ? "Edit photo" : "Edit video")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if clip.kind == .video {
                            if clip.trimEnd <= clip.trimStart { clip.trimEnd = min(clip.duration, clip.trimStart + 0.5) }
                        }
                        onSave(clip)
                        dismiss()
                    }
                }
            }
        }
    }
}
