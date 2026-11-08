//
//  OnDeviceModel.swift
//  Sedge
//

import Foundation
import Observation
import SedgeCore

/// The on-device model's files and the model itself: whether its weights are on this device,
/// downloading them once on request, and loading them to answer. The weights live in Application
/// Support (iOS never purges it, unlike Caches) and are left out of backups.
@Observable final class OnDeviceModel {
    /// One store for the whole app, so a download keeps its progress when Ask is rebuilt.
    static let shared = OnDeviceModel()

    enum State: Equatable {
        /// Not on this device, and the person hasn't been asked yet.
        case missing
        /// The person picked "Not now". Ask shows the screen that offers the download.
        case declined
        /// Downloading; the fraction done, 0 to 1.
        case downloading(Double)
        /// The download stopped before every file arrived.
        case failed
        case ready
    }

    private(set) var state = State.missing
    /// The download's size in whole gigabytes (3), worked out from the files' sizes.
    let gigabytes = Int((Double(QwenModel.files.map(\.value).reduce(0, +)) / 1e9).rounded())

    static let folder = URL.applicationSupportDirectory.appending(path: "Qwen3.5-4B-MLX-4bit")
    /// Bytes written so far for each file being downloaded.
    @ObservationIgnored private var written: [String: Int64] = [:]
    @ObservationIgnored private var loading: Task<QwenModel, Error>?
    @ObservationIgnored private lazy var downloader = Downloader(folder: Self.folder, progress: { [weak self] name, bytes in
        Task { @MainActor in self?.wrote(bytes, of: name) }
    }, finished: { [weak self] name, ok in
        Task { @MainActor in self?.finished(name, ok: ok) }
    })

    private init() {
        state = Self.missingFiles.isEmpty ? .ready : .missing
        #if DEBUG
        // UI tests launch with `-modelReady YES` to start as if the weights were already here.
        if UserDefaults.standard.bool(forKey: "modelReady") { state = .ready }
        #endif
    }

    /// The files not yet in the folder. A file only lands there once it downloaded whole.
    private static var missingFiles: [String] {
        QwenModel.files.map(\.key).filter { !FileManager.default.fileExists(atPath: folder.appending(path: $0).path(percentEncoded: false)) }
    }

    func decline() { state = .declined }

    /// Starts (or, after a failure, restarts) downloading every file that isn't here yet.
    func download() {
        state = .downloading(0)
        written = [:]
        #if DEBUG
        // UI tests launch with `-stubDownload ok` or `fail` to see the download without fetching 3 GB.
        if let stub = UserDefaults.standard.string(forKey: "stubDownload") {
            Task {
                for step in 1...4 {
                    try? await Task.sleep(for: .seconds(0.5))
                    state = .downloading(Double(step) / 5)
                }
                state = stub == "ok" ? .ready : .failed
            }
            return
        }
        #endif
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            var folder = Self.folder
            var values = URLResourceValues()
            values.isExcludedFromBackup = true // 3 GB that can be downloaded again has no place in a backup
            try folder.setResourceValues(values)
        } catch {
            state = .failed
            return
        }
        let missing = Self.missingFiles
        let session = downloader.session
        // A download left running by an earlier launch carries on; only the rest are started.
        session.getAllTasks { tasks in
            let running = Set(tasks.filter { $0.state == .running }.compactMap(\.taskDescription))
            for name in missing where !running.contains(name) {
                let url = URL(string: "https://huggingface.co/\(QwenModel.repo)/resolve/\(QwenModel.revision)/\(name)")!
                let task = session.downloadTask(with: url)
                task.taskDescription = name
                task.resume()
            }
            Task { @MainActor in self.finished(nil, ok: true) }
        }
    }

    private func wrote(_ bytes: Int64, of name: String) {
        guard case .downloading = state else { return }
        written[name] = bytes
        let files = Dictionary(uniqueKeysWithValues: QwenModel.files.map { ($0.key, $0.value) })
        let missing = Set(Self.missingFiles)
        let done = files.filter { !missing.contains($0.key) }.values.reduce(0, +) + written.filter { missing.contains($0.key) }.values.reduce(0, +)
        state = .downloading(min(Double(done) / Double(files.values.reduce(0, +)), 1))
    }

    /// One file finished (or nil after the tasks were started): ready once all are here, failed if one broke.
    private func finished(_ name: String?, ok: Bool) {
        guard case .downloading = state else { return }
        // A file that arrived but couldn't be moved into the folder is a failure too, or the download never ends.
        if !ok || name.map(Self.missingFiles.contains) == true {
            // Stop the rest, so Try again starts clean from the files that did arrive.
            downloader.session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
            state = .failed
        } else if Self.missingFiles.isEmpty {
            state = .ready
        }
    }

    /// The model that answers `question`. The iOS Simulator can't run MLX, so it (and UI tests
    /// launched with `-fakeModel YES`) gets a scripted stand-in; everywhere else it is the real
    /// model, loaded once from the folder and kept.
    func model(for question: String) async throws -> any AssistantModel {
        #if targetEnvironment(simulator)
        return Self.fake(for: question)
        #else
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "fakeModel") { return Self.fake(for: question) }
        #endif
        // One load shared by every question: a second copy of the 3 GB model would run the phone out of memory.
        let loading = loading ?? Task { try await QwenModel.load(from: Self.folder) }
        self.loading = loading
        do {
            return try await loading.value
        } catch {
            self.loading = nil // a later question tries again
            throw error
        }
        #endif
    }

    /// The scripted stand-in: it looks up the balances (or, for a food question, asks which food
    /// first), then answers with a fixed line.
    static func fake(for question: String) -> ScriptedModel {
        var delay = Duration.seconds(0.3)
        #if DEBUG
        // A UI test on a busy machine can miss a short thinking row, so `-slowThinking YES` holds each step longer.
        if UserDefaults.standard.bool(forKey: "slowThinking") { delay = .seconds(3) }
        #endif
        let first = question.lowercased().contains("food")
            ? ScriptedModel.call("ask_user", ["question": "Should food include groceries?",
                                              "options": #"["Groceries too", "Eating out only"]"#, "fact_key": "food_includes_groceries"])
            : ScriptedModel.call("account_balances")
        let answer = ScriptedModel.call("final_answer", ["answer_type": "text", "value": "This answer comes from the test model.",
                                                         "note": "The Simulator can't run the on-device model."])
        return ScriptedModel([first, answer], delay: delay)
    }
}

/// Downloads the model's files with a background URLSession, so a download keeps going while the
/// app is in the background, and moves each one into the folder once it arrived whole.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let folder: URL
    let progress: @Sendable (String, Int64) -> Void
    let finished: @Sendable (String, Bool) -> Void
    lazy var session = URLSession(configuration: .background(withIdentifier: "sedge.model-download"), delegate: self, delegateQueue: nil)

    init(folder: URL, progress: @escaping @Sendable (String, Int64) -> Void, finished: @escaping @Sendable (String, Bool) -> Void) {
        self.folder = folder
        self.progress = progress
        self.finished = finished
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(downloadTask.taskDescription ?? "", totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this returns, so it is moved now. An error page is never kept.
        guard let name = downloadTask.taskDescription, (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else { return }
        let destination = folder.appending(path: name)
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.moveItem(at: location, to: destination)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // A task cancelled after another one failed says nothing new, and must not fail a later Try again.
        if (error as? URLError)?.code == .cancelled { return }
        let ok = error == nil && (task.response as? HTTPURLResponse)?.statusCode == 200
        finished(task.taskDescription ?? "", ok)
    }
}
