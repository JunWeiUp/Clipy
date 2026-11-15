import Foundation
import Vision
// Data is supplied on stdin and decoded entirely in memory; never writes a QR PNG.
guard let line = readLine(),let bytes = Data(base64Encoded:line),bytes.count <= 1024*1024 else { exit(2) }
let request = VNDetectBarcodesRequest();request.symbologies = [.qr]
do {
    try VNImageRequestHandler(data:bytes).perform([request])
    let value:[String:Any] = ["payloads":(request.results ?? []).compactMap(\.payloadStringValue)]
    let output = try JSONSerialization.data(withJSONObject:value);FileHandle.standardOutput.write(output)
} catch { exit(3) }
