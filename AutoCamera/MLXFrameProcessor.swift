import CoreImage
import CoreMedia
import CoreVideo
import Foundation
#if canImport(MLX) && canImport(MLXHuggingFace) && canImport(MLXLMCommon) && canImport(MLXVLM) && canImport(Tokenizers)
import HuggingFace
import MLX
import MLXHuggingFace
import MLXLMCommon
import MLXVLM
import Tokenizers
#endif

actor MLXFrameProcessor {
    private let targetSize = CGSize(width: 384, height: 384)
    #if canImport(MLX) && canImport(MLXHuggingFace) && canImport(MLXLMCommon) && canImport(MLXVLM) && canImport(Tokenizers)
    private let modelConfiguration = VLMRegistry.qwen2_5VL3BInstruct4Bit
    private var modelContainer: ModelContainer?
    #endif

    func process(sampleBuffer: CMSampleBuffer) async -> String? {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        guard let resizedBuffer = makeResizedPixelBuffer(from: imageBuffer) else { return nil }

        #if canImport(MLX) && canImport(MLXHuggingFace) && canImport(MLXLMCommon) && canImport(MLXVLM) && canImport(Tokenizers)
        let image = CIImage(cvPixelBuffer: resizedBuffer)
        do {
            let container = try await loadContainer()
            let userInput = UserInput(
                chat: [
                    .system("你是专业摄影导演，请只用一句中文给出当前画面的构图或姿态建议。"),
                    .user("分析这张相机预览画面，输出最重要的一条导演建议。", images: [.ciImage(image)])
                ],
                processing: .init(resize: targetSize)
            )
            let input = try await container.prepare(input: userInput)
            let stream = try await container.generate(
                input: input,
                parameters: GenerateParameters(maxTokens: 80, temperature: 0.2)
            )
            var response = ""

            generationLoop: for await generation in stream {
                switch generation {
                case .chunk(let text):
                    response += text
                    if response.count >= 160 {
                        break generationLoop
                    }
                case .info, .toolCall:
                    break
                }
            }

            Memory.clearCache()
            let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "正在分析构图与姿态..." : trimmed
        } catch {
            Memory.clearCache()
            return "构图分析暂不可用：\(error.localizedDescription)"
        }
        #else
        return "正在分析构图与姿态..."
        #endif
    }

    #if canImport(MLX) && canImport(MLXHuggingFace) && canImport(MLXLMCommon) && canImport(MLXVLM) && canImport(Tokenizers)
    private func loadContainer() async throws -> ModelContainer {
        if let modelContainer {
            return modelContainer
        }

        let container = try await loadModelContainer(
            from: #hubDownloader(),
            using: #huggingFaceTokenizerLoader(),
            configuration: modelConfiguration
        )
        modelContainer = container
        return container
    }
    #endif

    private func makeResizedPixelBuffer(from sourceBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA
        ]

        var destinationBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, Int(targetSize.width), Int(targetSize.height), kCVPixelFormatType_32BGRA, attributes as CFDictionary, &destinationBuffer)
        guard status == kCVReturnSuccess, let destinationBuffer else { return nil }

        let sourceImage = CIImage(cvPixelBuffer: sourceBuffer)
        let scaleX = targetSize.width / sourceImage.extent.width
        let scaleY = targetSize.height / sourceImage.extent.height
        let scaledImage = sourceImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        let context = CIContext(options: [.cacheIntermediates: false])
        context.render(scaledImage, to: destinationBuffer)
        return destinationBuffer
    }
}
