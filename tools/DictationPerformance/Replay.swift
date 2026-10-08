import Foundation
import FluidAudio
import CryptoKit

// Provider-only replay of Murmur's Parakeet scheduling, linked to its existing
// optimized FluidAudio objects. No microphone, clipboard, settings, or network.
@main struct DictationBenchmark {
    static func now() -> Double { ProcessInfo.processInfo.systemUptime }
    static func emit(_ event: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
    static func sleepUntil(_ deadline: Double) async throws {
        let remaining = deadline - now()
        if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1e9)) }
    }
    static func replay(_ pcm: [Float], manager: AsrManager, policy: String, round: Int,
                       reference: String, fixtureID: String = "stock") async throws {
        let duration = Double(pcm.count) / 16000
        let interval = policy == "current" ? 0.6 : 0.2
        let start = now()
        var due = start
        var cadence = DictationPreviewCadence()
        var session: ParakeetIncrementalSession?
        var accepted = 0
        var events: [[String: Any]] = []
        var workMs = 0.0
        var count = 0
        while due < start + duration {
            try await sleepUntil(due)
            let elapsed = now() - start
            if elapsed >= duration { break }
            let sampleCount = min(pcm.count, Int(elapsed * 16000))
            if sampleCount >= 16000 {
                let began = now()
                let result: ASRResult
                if sampleCount > 240000 {
                    if session == nil { session = try await manager.makeIncrementalSession(source: .microphone) }
                    try await session!.append(Array(pcm[accepted..<sampleCount]))
                    accepted = sampleCount
                    result = try await session!.preview()
                } else {
                    result = try await manager.transcribe(Array(pcm.prefix(sampleCount)), source: .microphone)
                }
                let ended = now()
                workMs += (ended - began) * 1000
                cadence.recordDecode(duration: ended - began)
                count += 1
                events.append(["sampleCount": sampleCount, "audioMs": Double(sampleCount)/16,
                    "readyMs": (ended-start)*1000, "decodeMs": (ended-began)*1000, "text": result.text])
            }
            if policy == "current" { due = now() + interval }
            else if policy == "adaptive" {
                let thermal = ProcessInfo.processInfo.thermalState
                due = now() + cadence.delaySeconds(
                    enabled: thermal != .serious && thermal != .critical,
                    availableSamples: min(pcm.count, Int((now()-start)*16000)),
                    minimumSamples: 16000, fallbackInterval: 0.6)
            } else { due = start + (floor((now()-start)/interval) + 1) * interval }
        }
        try await sleepUntil(start + duration)
        let finalBegan = now()
        let final: ASRResult
        if let session {
            if accepted < pcm.count { try await session.append(Array(pcm[accepted...])) }
            final = try await session.finish(finalAudioSamples: pcm)
        } else { final = try await manager.transcribe(pcm, source: .microphone) }
        let end = now()
        emit(["kind":"replay", "fixtureID":fixtureID, "policy":policy, "round":round, "audioSeconds":duration,
            "previewCount":count, "previewWorkMs":workMs, "events":events,
            "stopToFinalMs":(end-start-duration)*1000,
            "inFlightDrainMs":max(0,finalBegan-start-duration)*1000,
            "finalDecodeMs":(end-finalBegan)*1000,
            "finalText":final.text, "exactMatchBatch":final.text == reference,
            "thermalState":ProcessInfo.processInfo.thermalState.rawValue])
    }
    static func main() async throws {
        guard CommandLine.arguments.count >= 2 else {
            FileHandle.standardError.write(Data(
                "Usage: DictationPerformanceReplay <16kHz-mono-s16le.pcm> [manifest.json]\n".utf8
            ))
            exit(64)
        }
        let path = CommandLine.arguments[1]
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard !data.isEmpty, data.count.isMultiple(of: 2) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let pcm: [Float] = data.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 2).map { i in
                Float(Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i+1]) << 8)) / 32768
            }
        }
        emit(["kind":"metadata", "date":ISO8601DateFormatter().string(from:Date()),
            "scope":"provider-only; fixture replay; no human WER or rendered UI measurement",
            "fixtureSHA256":SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined(),
            "fixtureSamples":pcm.count, "fixtureSeconds":Double(pcm.count)/16000,
            "os":ProcessInfo.processInfo.operatingSystemVersionString,
            "thermalState":ProcessInfo.processInfo.thermalState.rawValue,
            "lowPowerMode":ProcessInfo.processInfo.isLowPowerModeEnabled])
        let start = now()
        let models = try await AsrModels.loadLocalOnly(from: AsrModels.defaultCacheDirectory(for:.v2),version:.v2)
        let manager = AsrManager(config:ASRConfig.default)
        try await manager.initialize(models:models)
        emit(["kind":"modelLoad", "elapsedMs":(now()-start)*1000])
        let warmStart = now()
        let reference = try await manager.transcribe(pcm,source:.microphone)
        emit(["kind":"firstInference", "elapsedMs":(now()-warmStart)*1000,"text":reference.text])
        if CommandLine.arguments.count > 2 {
            let manifestData = try Data(contentsOf: URL(fileURLWithPath:CommandLine.arguments[2]))
            let fixtures = try JSONSerialization.jsonObject(with:manifestData) as! [[String:Any]]
            for (index, fixture) in fixtures.enumerated() {
                let fixtureData = try Data(contentsOf: URL(fileURLWithPath:fixture["path"] as! String))
                guard !fixtureData.isEmpty, fixtureData.count.isMultiple(of: 2) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let input: [Float] = fixtureData.withUnsafeBytes { bytes in
                    stride(from:0,to:bytes.count,by:2).map { i in
                        Float(Int16(bitPattern:UInt16(bytes[i]) | UInt16(bytes[i+1]) << 8))/32768
                    }
                }
                let repetitions = fixture["repetitions"] as? Int ?? 1
                let base = Array(repeating:input,count:repetitions).flatMap{$0}
                let rounds = fixture["rounds"] as? Int ?? 3
                for round in 0..<rounds {
                    // Vary the endpoint phase so stop-drain measurements are not
                    // accidentally aligned to either scheduler's favorite tick.
                    let tail = [0.137, 0.287, 0.571][round % 3]
                    let audio = base + Array(repeating:Float(0),count:Int(tail*16000))
                    let gold = try await manager.transcribe(audio,source:.microphone)
                    let id = fixture["id"] as! String
                    emit(["kind":"fixture", "id":id,"round":round,"expectedText":fixture["text"] ?? "",
                        "sha256":SHA256.hash(data:fixtureData).map{String(format:"%02x",$0)}.joined(),
                        "referenceText":gold.text,"audioSeconds":Double(audio.count)/16000])
                    for policy in ((index+round)%2 == 0 ? ["current","adaptive"] : ["adaptive","current"]) {
                        try await replay(audio,manager:manager,policy:policy,round:round,
                            reference:gold.text,fixtureID:id)
                    }
                }
            }
            await manager.cleanup()
            emit(["kind":"done"])
            return
        }
        var references: [Int:String] = [1:reference.text]
        for repetitions in [1,5,15] {
            let audio = Array(repeating:pcm,count:repetitions).flatMap{$0}
            for round in 0..<5 {
                let began = now()
                let result = try await manager.transcribe(audio,source:.microphone)
                if references[repetitions] == nil { references[repetitions] = result.text }
                emit(["kind":"batch", "repetitions":repetitions, "round":round,
                    "audioSeconds":Double(audio.count)/16000,"elapsedMs":(now()-began)*1000,
                    "exactMatchReference":result.text == references[repetitions],"text":result.text])
            }
        }
        for round in 0..<5 {
            for policy in (round % 2 == 0 ? ["current","deadline200"] : ["deadline200","current"]) {
                try await replay(pcm,manager:manager,policy:policy,round:round,reference:reference.text)
            }
        }
        let longAudio = Array(repeating:pcm,count:5).flatMap{$0}
        for policy in ["deadline200","current"] {
            try await replay(longAudio,manager:manager,policy:policy,round:5,reference:references[5]!)
        }
        // Exact-cache test: same sample count, same model/config, no new audio.
        let session = try await manager.makeIncrementalSession(source:.microphone)
        try await session.append(longAudio)
        let preview = try await session.preview()
        let began = now()
        let final = try await session.finish(finalAudioSamples:longAudio)
        emit(["kind":"exactCache", "elapsedMs":(now()-began)*1000,
            "exactMatchPreview":final.text == preview.text,"exactMatchBatch":final.text == references[5]!])
        await manager.cleanup()
        emit(["kind":"done"])
    }
}
