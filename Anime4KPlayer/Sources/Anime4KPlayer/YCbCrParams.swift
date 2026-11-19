import CoreVideo
import simd

/// Mirror of `YCbCrParams` in Kernels.metal (float3x3 = 3 x 16 bytes, float3 = 16 bytes).
struct YCbCrParams {
    var m: simd_float3x3
    var offset: SIMD3<Float>
}

enum YCbCrMatrix: String {
    case bt601, bt709, bt2020

    var kr: Float { switch self { case .bt601: return 0.299;  case .bt709: return 0.2126; case .bt2020: return 0.2627 } }
    var kb: Float { switch self { case .bt601: return 0.114;  case .bt709: return 0.0722; case .bt2020: return 0.0593 } }

    /// Matrix from the buffer's attachments; falls back to the usual SD/HD convention.
    static func of(_ buffer: CVPixelBuffer) -> YCbCrMatrix {
        if let v = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String {
            if v == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String) { return .bt709 }
            if v == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) { return .bt601 }
            if v == (kCVImageBufferYCbCrMatrix_SMPTE_240M_1995 as String) { return .bt709 }
            if v == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String) { return .bt2020 }
        }
        return CVPixelBufferGetHeight(buffer) >= 720 ? .bt709 : .bt601
    }
}

extension YCbCrParams {
    /// - Parameters:
    ///   - bitDepth: 8 or 10.
    ///   - msbPacked16: 10-bit samples stored in the high bits of 16-bit words (x420/xf20),
    ///     so a code value c reads back as c * 64 / 65535 from an r16Unorm texture.
    static func make(matrix: YCbCrMatrix, fullRange: Bool, bitDepth: Int, msbPacked16: Bool) -> YCbCrParams {
        let unit: Float = msbPacked16 ? Float(1 << (16 - bitDepth)) / 65535 : 1 / Float((1 << bitDepth) - 1)
        let shift = Float(1 << (bitDepth - 8))
        let yBlack, yRange, cMid, cRange: Float
        if fullRange {
            yBlack = 0
            yRange = Float((1 << bitDepth) - 1) * unit
            cMid = Float(1 << (bitDepth - 1)) * unit
            cRange = yRange
        } else {
            yBlack = 16 * shift * unit
            yRange = 219 * shift * unit
            cMid = 128 * shift * unit
            cRange = 224 * shift * unit
        }
        let kr = matrix.kr, kb = matrix.kb, kg = 1 - kr - kb
        // Columns: contribution of Y, Cb, Cr to (R, G, B).
        let colY  = SIMD3<Float>(1, 1, 1) / yRange
        let colCb = SIMD3<Float>(0, -2 * kb * (1 - kb) / kg, 2 * (1 - kb)) / cRange
        let colCr = SIMD3<Float>(2 * (1 - kr), -2 * kr * (1 - kr) / kg, 0) / cRange
        return YCbCrParams(m: simd_float3x3(colY, colCb, colCr), offset: SIMD3(yBlack, cMid, cMid))
    }
}
