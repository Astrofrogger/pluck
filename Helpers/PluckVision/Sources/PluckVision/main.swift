import Foundation
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLMCommon
import MLXVLM
import Tokenizers

// pluck-vision <model folder>
// Loads the model once, prints {"ready":true}, then answers one JSON request per line on stdin:
//   {"image": "/path/frame.jpg", "prompt": "…", "instructions": "…", "maxTokens": 200}
// with {"text": "…", "seconds": 1.2} or {"error": "…"} on stdout.

struct Request: Decodable {
    var image: String
    var prompt: String
    var instructions: String?
    var maxTokens: Int?
}

func send(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          let line = String(data: data, encoding: .utf8) else { return }
    print(line)
    fflush(stdout)
}

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write("usage: pluck-vision <model folder>\n".data(using: .utf8)!)
    exit(2)
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

do {
    // Keep memory in check on smaller Macs: a modest GPU cache.
    MLX.GPU.set(cacheLimit: 512 * 1024 * 1024)
    let container = try await VLMModelFactory.shared.loadContainer(
        from: folder, using: #huggingFaceTokenizerLoader())
    send(["ready": true])
    while let line = readLine() {
        guard let data = line.data(using: .utf8), let request = try? JSONDecoder().decode(Request.self, from: data) else {
            send(["error": "bad request"])
            continue
        }
        let started = Date()
        do {
            // A fresh session per picture: every shot is judged on its own.
            let session = ChatSession(
                container, instructions: request.instructions,
                generateParameters: GenerateParameters(maxTokens: request.maxTokens ?? 200, temperature: 0.2),
                processing: UserInput.Processing(resize: CGSize(width: 768, height: 432)))
            // Straight to the answer: Qwen's reasoning first would triple the time per shot.
            session.additionalContext = ["enable_thinking": false]
            let text = try await session.respond(to: request.prompt, image: .url(URL(fileURLWithPath: request.image)))
            send(["text": text, "seconds": Date().timeIntervalSince(started)])
        } catch {
            send(["error": "\(error)"])
        }
    }
} catch {
    send(["error": "\(error)"])
    exit(1)
}
