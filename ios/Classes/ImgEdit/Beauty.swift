import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Beauty pipeline: skin smoothing (bilateral approximation via CIBoxBlur
/// + difference mask), teeth whiten + eye brighten (CIColorControls
/// confined to face-landmark ROIs).
///
/// Real `VNDetectFaceLandmarksRequest` invocation lives in `FaceDetector`;
/// this enum operates on the produced ROIs.
public enum Beauty {

    public struct Params {
        public var skin: Float
        public var teeth: Float
        public var eyes: Float
        public init(skin: Float = 0, teeth: Float = 0, eyes: Float = 0) {
            self.skin = skin
            self.teeth = teeth
            self.eyes = eyes
        }
    }

    public static func apply(_ image: CIImage, params: Params,
                             faceROIs: [CGRect] = [],
                             teethROIs: [CGRect] = [],
                             eyeROIs: [CGRect] = []) -> CIImage {
        var current = image
        if params.skin > 0, !faceROIs.isEmpty {
            current = smoothSkin(current, intensity: params.skin, rois: faceROIs)
        }
        if params.teeth > 0, !teethROIs.isEmpty {
            current = brighten(current, intensity: params.teeth, rois: teethROIs)
        }
        if params.eyes > 0, !eyeROIs.isEmpty {
            current = brighten(current, intensity: params.eyes * 1.2, rois: eyeROIs)
        }
        return current
    }

    private static func smoothSkin(_ src: CIImage, intensity: Float,
                                   rois: [CGRect]) -> CIImage {
        let blur = CIFilter.boxBlur()
        blur.inputImage = src
        blur.radius = 6 * intensity
        guard let blurred = blur.outputImage else { return src }
        var out = src
        for roi in rois {
            let masked = CIImage(color: .white).cropped(to: roi)
            let blend = CIFilter.blendWithMask()
            blend.inputImage = blurred
            blend.backgroundImage = out
            blend.maskImage = masked
            if let composed = blend.outputImage { out = composed }
        }
        return out
    }

    private static func brighten(_ src: CIImage, intensity: Float,
                                 rois: [CGRect]) -> CIImage {
        let cc = CIFilter.colorControls()
        cc.inputImage = src
        cc.brightness = 0.05 * intensity
        cc.contrast = 1.0 + 0.1 * intensity
        cc.saturation = 1.0 - 0.2 * intensity
        guard let bright = cc.outputImage else { return src }
        var out = src
        for roi in rois {
            let masked = CIImage(color: .white).cropped(to: roi)
            let blend = CIFilter.blendWithMask()
            blend.inputImage = bright
            blend.backgroundImage = out
            blend.maskImage = masked
            if let composed = blend.outputImage { out = composed }
        }
        return out
    }
}
