import Foundation
import whisper

enum SpeechTranscriptionError: LocalizedError {
    case assetsMissing
    case conversionFailed(String)
    case invalidAudio
    case modelLoadFailed
    case recognitionFailed
    case transcriptTooShort

    var errorDescription: String? {
        switch self {
        case .assetsMissing: "应用包里缺少本地语音识别模型。请重新运行资源引导脚本后构建 APP。"
        case .conversionFailed(let detail): "视频音轨转换失败：\(detail)"
        case .invalidAudio: "下载到的音轨无法识别。"
        case .modelLoadFailed: "无法载入本地语音识别模型。"
        case .recognitionFailed: "本地语音识别没有成功完成。"
        case .transcriptTooShort: "没有从视频中识别出足够的口播内容，因此已停止改写，避免根据标题编造。"
        }
    }
}

protocol SpeechTranscribing: Sendable {
    func transcribe(audioURL: URL, expectedDuration: Int?) async throws -> String
}

/// Runs whisper.cpp in-process with a compact multilingual model. Audio is
/// converted by the macOS system tool first, so the app does not depend on
/// ffmpeg, Python, Ollama, a server, or an account.
actor LocalSpeechTranscriber: SpeechTranscribing {
    nonisolated static let defaultSpokenLanguage = "auto"
    private let modelURL: URL?

    init(modelURL: URL? = LocalSpeechTranscriber.discoverModel()) {
        self.modelURL = modelURL
    }

    nonisolated static func discoverModel(bundle: Bundle = .main) -> URL? {
        guard let resources = bundle.resourceURL else { return nil }
        let url = resources.appending(path: "Models/ggml-small-q5_1.bin")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func transcribe(audioURL: URL, expectedDuration: Int?) async throws -> String {
        guard let modelURL else { throw SpeechTranscriptionError.assetsMissing }
        let wavURL = FileManager.default.temporaryDirectory
            .appending(path: "chenggao-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }

        try await Self.convertToWhisperWAV(input: audioURL, output: wavURL)
        try Task.checkCancellation()
        let samples = try Self.decodePCM16Wave(wavURL)
        guard !samples.isEmpty else { throw SpeechTranscriptionError.invalidAudio }

        var contextParameters = whisper_context_default_params()
        contextParameters.use_gpu = true
        contextParameters.flash_attn = true
        guard let context = whisper_init_from_file_with_params(modelURL.path, contextParameters) else {
            throw SpeechTranscriptionError.modelLoadFailed
        }
        defer { whisper_free(context) }

        var parameters = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        parameters.print_realtime = false
        parameters.print_progress = false
        parameters.print_timestamps = false
        parameters.print_special = false
        parameters.translate = false
        parameters.n_threads = Int32(max(1, min(6, ProcessInfo.processInfo.processorCount - 2)))
        parameters.no_context = false
        parameters.single_segment = false

        let cancellation = WhisperCancellationBox()
        parameters.abort_callback = { pointer in
            guard let pointer else { return false }
            return Unmanaged<WhisperCancellationBox>.fromOpaque(pointer).takeUnretainedValue().isCancelled
        }
        parameters.abort_callback_user_data = Unmanaged.passUnretained(cancellation).toOpaque()
        let status: Int32 = await withTaskCancellationHandler {
            Self.defaultSpokenLanguage.withCString { language in
                parameters.language = language
                return samples.withUnsafeBufferPointer { buffer in
                    whisper_full(context, parameters, buffer.baseAddress, Int32(buffer.count))
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()
        guard status == 0 else { throw SpeechTranscriptionError.recognitionFailed }

        var segments: [String] = []
        for index in 0..<whisper_full_n_segments(context) {
            let value = String(cString: whisper_full_get_segment_text(context, index))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { segments.append(value) }
        }
        let transcript = Self.cleanTranscript(segments.joined(separator: "\n"))
        let minimum = Self.minimumTranscriptCharacters(expectedDuration: expectedDuration)
        guard transcript.count >= minimum else { throw SpeechTranscriptionError.transcriptTooShort }
        return transcript
    }

    nonisolated static func minimumTranscriptCharacters(expectedDuration: Int?) -> Int {
        guard let expectedDuration else { return 40 }
        if expectedDuration <= 30 { return max(8, expectedDuration / 3) }
        return min(200, max(40, expectedDuration / 2))
    }

    nonisolated static func convertToWhisperWAV(input: URL, output: URL) async throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        process.arguments = [input.path, output.path, "-f", "WAVE", "-d", "LEI16@16000", "-c", "1"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        do {
            let box = SpeechProcessBox(process)
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = { _ in continuation.resume(returning: ()) }
                    do { try process.run() }
                    catch {
                        process.terminationHandler = nil
                        continuation.resume(throwing: error)
                    }
                }
            } onCancel: {
                if box.process.isRunning { box.process.terminate() }
            }
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SpeechTranscriptionError.conversionFailed(error.localizedDescription)
        }
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SpeechTranscriptionError.conversionFailed(detail.isEmpty ? "退出码 \(process.terminationStatus)" : detail)
        }
    }

    nonisolated static func decodePCM16Wave(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count > 44,
              String(decoding: data[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: data[8..<12], as: UTF8.self) == "WAVE" else {
            throw SpeechTranscriptionError.invalidAudio
        }

        var cursor = 12
        var payload: Range<Int>?
        while cursor + 8 <= data.count {
            let id = String(decoding: data[cursor..<(cursor + 4)], as: UTF8.self)
            let size = Int(data[cursor + 4])
                | (Int(data[cursor + 5]) << 8)
                | (Int(data[cursor + 6]) << 16)
                | (Int(data[cursor + 7]) << 24)
            let start = cursor + 8
            let end = min(start + size, data.count)
            if id == "data" { payload = start..<end; break }
            cursor = start + size + (size % 2)
        }
        guard let payload else { throw SpeechTranscriptionError.invalidAudio }

        var samples: [Float] = []
        samples.reserveCapacity(payload.count / 2)
        var index = payload.lowerBound
        while index + 1 < payload.upperBound {
            let bits = UInt16(data[index]) | (UInt16(data[index + 1]) << 8)
            let value = Int16(bitPattern: bits)
            samples.append(max(-1, min(Float(value) / 32768, 1)))
            index += 2
        }
        return samples
    }

    nonisolated static func cleanTranscript(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\[(音乐|掌声|笑声|Music|Applause).*?\]"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class SpeechProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

private final class WhisperCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}
