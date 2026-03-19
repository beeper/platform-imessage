import AccessibilityControl
import CoreGraphics
import Foundation
import ScreenCaptureKit
import SwiftServerFoundation
import WindowControl

@available(macOS 14.0, *)
enum ScreenshotImageOrigin {
    case topLeft
    case bottomLeft
}

@available(macOS 14.0, *)
struct WindowScreenshot {
    let window: SCWindow
    let image: CGImage

    var windowID: CGWindowID { window.windowID }
    var frame: CGRect { window.frame.standardized }

    var scaleX: CGFloat {
        CGFloat(image.width) / frame.width
    }

    var scaleY: CGFloat {
        CGFloat(image.height) / frame.height
    }

    func pixelCropRect(
        forGlobalRect rect: CGRect,
        padding: CGFloat = 0,
        imageOrigin: ScreenshotImageOrigin = .topLeft
    ) throws -> CGRect {
        let expandedRect = rect.standardized.insetBy(dx: -padding, dy: -padding)
        guard !expandedRect.isNull, !expandedRect.isEmpty else {
            throw ErrorMessage("Cannot crop an empty screenshot rect")
        }

        guard frame.width > 0, frame.height > 0 else {
            throw ErrorMessage("Cannot crop screenshot for zero-sized window \(windowID)")
        }

        let localRect = CGRect(
            x: expandedRect.minX - frame.minX,
            y: expandedRect.minY - frame.minY,
            width: expandedRect.width,
            height: expandedRect.height
        )

        guard scaleX > 0, scaleY > 0 else {
            throw ErrorMessage("Cannot compute screenshot scale for window \(windowID)")
        }

        let pixelY = switch imageOrigin {
        case .topLeft:
            localRect.minY * scaleY
        case .bottomLeft:
            CGFloat(image.height) - (localRect.maxY * scaleY)
        }

        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let pixelRect = CGRect(
            x: localRect.minX * scaleX,
            y: pixelY,
            width: localRect.width * scaleX,
            height: localRect.height * scaleY
        )
        .integral
        .intersection(imageBounds)

        guard !pixelRect.isNull, !pixelRect.isEmpty else {
            throw ErrorMessage("Requested screenshot crop does not intersect captured window \(windowID)")
        }

        return pixelRect
    }

    func cropped(
        toGlobalRect rect: CGRect,
        padding: CGFloat = 0,
        imageOrigin: ScreenshotImageOrigin = .topLeft
    ) throws -> CGImage {
        let cropRect = try pixelCropRect(
            forGlobalRect: rect,
            padding: padding,
            imageOrigin: imageOrigin
        )
        guard let cropped = image.cropping(to: cropRect) else {
            throw ErrorMessage("Failed to crop screenshot for window \(windowID)")
        }
        return cropped
    }
}

@available(macOS 14.0, *)
extension Window {
    var associatedSCWindow: SCWindow {
        get async throws {
            guard CGPreflightScreenCaptureAccess() else {
                throw ErrorMessage("Screen Recording permission is required to capture screenshots")
            }
            
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            
            guard let window = content.windows.first(where: { $0.windowID == raw }) else {
                throw ErrorMessage("Could not locate a shareable window for ID \(raw)")
            }
            
            return window
        }
    }
}

@available(macOS 14.0, *)
extension Window {
    func screenshot(
        showsCursor: Bool = false,
        includeChildWindows: Bool = true,
        ignoreShadows: Bool = true
    ) async throws -> WindowScreenshot {
        let shareableWindow = try await self.screenCaptureWindow

        let filter = SCContentFilter(desktopIndependentWindow: shareableWindow)
        let filterInfo = SCShareableContent.info(for: filter)
        let pointPixelScale = max(CGFloat(filterInfo.pointPixelScale), 1)
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = showsCursor
        configuration.width = max(1, Int((shareableWindow.frame.width * pointPixelScale).rounded()))
        configuration.height = max(1, Int((shareableWindow.frame.height * pointPixelScale).rounded()))

        configuration.ignoreShadowsSingleWindow = ignoreShadows
        
        if #available(macOS 14.2, *) {
            configuration.includeChildWindows = includeChildWindows
        }

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        
        return WindowScreenshot(window: shareableWindow, image: image)
    }
}

@available(macOS 14.0, *)
extension Accessibility.Element {
    func windowScreenshot(
        showsCursor: Bool = false,
        includeChildWindows: Bool = true,
        ignoreShadows: Bool = true
    ) async throws -> WindowScreenshot {
        try await window().screenshot(
            showsCursor: showsCursor,
            includeChildWindows: includeChildWindows,
            ignoreShadows: ignoreShadows
        )
    }

    func screenshot(
        padding: CGFloat = 0,
        imageOrigin: ScreenshotImageOrigin = .topLeft,
        showsCursor: Bool = false,
        includeChildWindows: Bool = true,
        ignoreShadows: Bool = true
    ) async throws -> CGImage {
        let windowScreenshot = try await windowScreenshot(
            showsCursor: showsCursor,
            includeChildWindows: includeChildWindows,
            ignoreShadows: ignoreShadows
        )
        return try windowScreenshot.cropped(
            toGlobalRect: self.frame(),
            padding: padding,
            imageOrigin: imageOrigin
        )
    }
}
