import Foundation

struct ModelProfile: Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let parameterCount: String
    let quantization: String
    let approximateSize: String
    let contextLimit: Int
    let languageNote: String
    let license: String

    static let qwenDefault = ModelProfile(
        id: "qwen3-1.7b-q4",
        displayName: "Qwen3 1.7B",
        parameterCount: "1.7B",
        quantization: "Q4",
        approximateSize: "约 1.2–1.4 GB",
        contextLimit: 4_096,
        languageNote: "中文、繁体中文与粤语优先",
        license: "Apache 2.0"
    )

}

struct MemoryBudget: Equatable, Sendable {
    let physicalMemoryGB: Int
    let modelWeightMB: Int
    let contextCacheMB: Int
    let workingBufferMB: Int

    var estimatedPeakMB: Int {
        modelWeightMB + contextCacheMB + workingBufferMB
    }

    var isEightGBSafe: Bool {
        estimatedPeakMB <= 3_300
    }

    static var currentMachine: MemoryBudget {
        let bytes = ProcessInfo.processInfo.physicalMemory
        let gigabytes = max(1, Int((Double(bytes) / 1_073_741_824).rounded()))
        return MemoryBudget(
            physicalMemoryGB: gigabytes,
            modelWeightMB: 1_400,
            contextCacheMB: 520,
            workingBufferMB: 780
        )
    }
}
