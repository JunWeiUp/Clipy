import Foundation
import Compression

enum CompressionError: Error {
    case compressionFailed
    case decompressionFailed
}

class CompressionUtils {
    static func compressData(_ data: Data, algorithm: compression_algorithm = COMPRESSION_LZFSE) -> Data? {
        let bufferSize = data.count + 64 // Add some overhead for compression metadata
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        
        let compressedSize = data.withUnsafeBytes { inputPtr in
            buffer.withUnsafeMutableBytes { outputPtr in
                compression_encode_buffer(
                    outputPtr.baseAddress!,
                    bufferSize,
                    inputPtr.baseAddress!,
                    data.count,
                    nil,
                    algorithm
                )
            }
        }
        
        if compressedSize == 0 {
            return nil // Compression failed or not beneficial
        }
        
        return Data(buffer[0..<compressedSize])
    }
    
    static func decompressData(_ data: Data, originalSize: Int, algorithm: compression_algorithm = COMPRESSION_LZFSE) -> Data? {
        var buffer = [UInt8](repeating: 0, count: originalSize)
        
        let decompressedSize = data.withUnsafeBytes { inputPtr in
            buffer.withUnsafeMutableBytes { outputPtr in
                compression_decode_buffer(
                    outputPtr.baseAddress!,
                    originalSize,
                    inputPtr.baseAddress!,
                    data.count,
                    nil,
                    algorithm
                )
            }
        }
        
        if decompressedSize != originalSize {
            return nil // Decompression failed
        }
        
        return Data(buffer)
    }
    
    static func shouldCompressData(_ data: Data) -> Bool {
        // Don't compress very small data (overhead > benefit)
        // Don't compress already compressed data (images, PDFs, etc.)
        if data.count < 1024 {
            return false
        }
        
        // Check if data appears to be already compressed
        // Simple heuristic: if entropy is high, it's likely already compressed
        let entropy = calculateEntropy(data)
        return entropy < 7.0 // Threshold for "compressible" data
    }
    
    private static func calculateEntropy(_ data: Data) -> Double {
        var byteCounts = [UInt8: Int]()
        for byte in data {
            byteCounts[byte, default: 0] += 1
        }
        
        let totalBytes = Double(data.count)
        var entropy: Double = 0.0
        
        for count in byteCounts.values {
            let probability = Double(count) / totalBytes
            entropy -= probability * log2(probability)
        }
        
        return entropy
    }
}