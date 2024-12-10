//
//  ViaLightingAPI.swift
//
//  Created by JerryZhangZZY on 2024/12/9.
//

import Foundation
import IOKit
import IOKit.hid

public protocol KbdConnectionDelegate {
    func onConnected(kbdName: String)
    func onDisconnected()
}

public struct VIAConstants {
    public static let viaInterfaceNum: Int = 1
    public static let rawHIDBufferSize: Int = 32
    
    // VIA Commands
    public static let customSetValue: UInt8 = 7
    public static let customSave: UInt8 = 9
    
    // VIA Channels
    public static let channelRGBMatrix: UInt8 = 3
    
    // VIA RGB Matrix Entries
    public static let rgbMatrixValueBrightness: UInt8 = 1
    public static let rgbMatrixValueEffect: UInt8 = 2
    public static let rgbMatrixValueEffectSpeed: UInt8 = 3
    public static let rgbMatrixValueColor: UInt8 = 4
}

public struct HSV {
    public let h: UInt8
    public let s: UInt8
    public let v: UInt8
}

public class ViaLightingAPI : NSObject, @unchecked Sendable {
    
    public var delegate: KbdConnectionDelegate?
    
    private var device: IOHIDDevice? = nil
    private var colorCorrection: [Double]?
    
    public init(vendorID: Int, productID: Int, usage: Int, usagePage: Int) {
        super.init()
        
        DispatchQueue.global().async {
            
            let deviceMatch = [kIOHIDProductIDKey: productID, kIOHIDVendorIDKey: vendorID, kIOHIDDeviceUsageKey: usage, kIOHIDDeviceUsagePageKey: usagePage]
            let managerRef = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            
            IOHIDManagerSetDeviceMatching(managerRef, deviceMatch as CFDictionary?)
            IOHIDManagerScheduleWithRunLoop(managerRef, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerOpen(managerRef, 0)
            
            let matchingCallback: IOHIDDeviceCallback = { inContext, inResult, inSender, inIOHIDDeviceRef in
                let this: ViaLightingAPI = Unmanaged<ViaLightingAPI>.fromOpaque(inContext!).takeUnretainedValue()
                this.connected(inResult, inSender: inSender!, inIOHIDDeviceRef: inIOHIDDeviceRef)
            }
            
            let removalCallback: IOHIDDeviceCallback = { inContext, inResult, inSender, inIOHIDDeviceRef in
                let this: ViaLightingAPI = Unmanaged<ViaLightingAPI>.fromOpaque(inContext!).takeUnretainedValue()
                this.disconnected(inResult, inSender: inSender!, inIOHIDDeviceRef: inIOHIDDeviceRef)
            }
            
            let this = Unmanaged.passRetained(self).toOpaque()
            IOHIDManagerRegisterDeviceMatchingCallback(managerRef, matchingCallback, this)
            IOHIDManagerRegisterDeviceRemovalCallback(managerRef, removalCallback, this)
            
            CFRunLoopRun()
        }
    }
    
    func send(_ data: Data) {
        var byteData = [UInt8](data)
        let length = VIAConstants.rawHIDBufferSize
        while byteData.count < length {
            byteData.append(0)
        }
        let reportId: CFIndex = CFIndex(data[0])
        if let device1 = device {
            IOHIDDeviceSetReport(device1, kIOHIDReportTypeOutput, reportId, byteData, byteData.count)
        }
    }
    
    func connected(_ inResult: IOReturn, inSender: UnsafeMutableRawPointer, inIOHIDDeviceRef: IOHIDDevice!) {
        device = inIOHIDDeviceRef
        let key = kIOHIDProductKey as CFString
        let deviceName = IOHIDDeviceGetProperty(device!, key) as? String ?? "Unknown"
        self.delegate?.onConnected(kbdName: deviceName)
    }
    
    func disconnected(_ inResult: IOReturn, inSender: UnsafeMutableRawPointer, inIOHIDDeviceRef: IOHIDDevice!) {
        device = nil
        self.delegate?.onDisconnected()
    }
    
    /// Sets the brightness of the lighting.
    /// - Parameter brightness: Brightness value (0-255).
    public func setBrightness(brightness: UInt8) {
        let command: [UInt8] = [
            VIAConstants.customSetValue,
            VIAConstants.channelRGBMatrix,
            VIAConstants.rgbMatrixValueBrightness,
            brightness
        ]
        send(Data(command))
    }
    
    /// Sets the lighting effect.
    /// - Parameter effect: Effect ID (e.g., 0 for All Off, 1 for Solid Color).
    public func setEffect(effect: UInt8) {
        let command: [UInt8] = [
            VIAConstants.customSetValue,
            VIAConstants.channelRGBMatrix,
            VIAConstants.rgbMatrixValueEffect,
            effect
        ]
        send(Data(command))
    }
    
    /// Sets the speed of the lighting effect.
    /// - Parameter speed: Speed value (0-255).
    public func setEffectSpeed(speed: UInt8) {
        let command: [UInt8] = [
            VIAConstants.customSetValue,
            VIAConstants.channelRGBMatrix,
            VIAConstants.rgbMatrixValueEffectSpeed,
            speed
        ]
        send(Data(command))
    }
    
    /// Sets the lighting color.
    /// - Parameter color: Array containing `[R, G, B]` or `[H, S]`.
    public func setColor(color: [UInt8]) {
        var hue: UInt8
        var sat: UInt8
        
        switch color.count {
        case 3:
            // RGB 转换为 HSV
            let hsv = rgbToHsv(rgb: color)
            hue = hsv.h
            sat = hsv.s
        case 2:
            // 假设输入为 [H, S]
            hue = color[0]
            sat = color[1]
        default:
            return
        }
        
        let command: [UInt8] = [
            VIAConstants.customSetValue,
            VIAConstants.channelRGBMatrix,
            VIAConstants.rgbMatrixValueColor,
            hue,
            sat
        ]
        send(Data(command))
    }
    
    /// Sets the absolute lighting color, adjusting both HS color and brightness.
    /// - Parameter color: Array containing `[R, G, B]`.
    public func setColorAbs(color: [UInt8]) {
        if color.count == 3 {
            // 应用颜色校正（如果可用）
            var adjustedColor = color
            if let cor = self.colorCorrection {
                for i in 0..<3 {
                    adjustedColor[i] = cor.indices.contains(i) ? UInt8(Double(color[i]) / cor[i]) : color[i]
                }
            }
            
            let hsv = rgbToHsv(rgb: adjustedColor)
            
            let commandColor: [UInt8] = [
                VIAConstants.customSetValue,
                VIAConstants.channelRGBMatrix,
                VIAConstants.rgbMatrixValueColor,
                hsv.h,
                hsv.s
            ]
            
            let commandBrightness: [UInt8] = [
                VIAConstants.customSetValue,
                VIAConstants.channelRGBMatrix,
                VIAConstants.rgbMatrixValueBrightness,
                hsv.v
            ]
            
            send(Data(commandColor))
            send(Data(commandBrightness))
        }
    }
    
    /// Saves the current lighting settings to EEPROM.
    public func save() {
        let command: [UInt8] = [
            VIAConstants.customSave,
            VIAConstants.channelRGBMatrix
        ]
        send(Data(command))
    }
    
    /// Enables color correction based on a true white reference.
    /// - Parameter trueWhite: Array containing `[R, G, B]` values when the keyboard displays true white.
    public func setColorCorrection(trueWhite: [UInt8]) {
        if trueWhite.count == 3 {
            self.colorCorrection = [
                255.0 / Double(trueWhite[0]),
                255.0 / Double(trueWhite[1]),
                255.0 / Double(trueWhite[2])
            ]
        }
    }
    
    /// Disables color correction.
    public func disableColorCorrection() {
        self.colorCorrection = nil
    }
    
    
    private func rgbToHsv(rgb: [UInt8]) -> HSV {
        let r = Double(rgb[0]) / 255.0
        let g = Double(rgb[1]) / 255.0
        let b = Double(rgb[2]) / 255.0
        
        let maxVal = max(r, max(g, b))
        let minVal = min(r, min(g, b))
        let delta = maxVal - minVal
        
        var h: Double = 0
        var s: Double = 0
        let v: Double = maxVal * 255.0
        
        if delta != 0 {
            s = delta / maxVal
            
            if r == maxVal {
                h = (g - b) / delta
            } else if g == maxVal {
                h = 2 + (b - r) / delta
            } else {
                h = 4 + (r - g) / delta
            }
            
            h *= 60
            if h < 0 { h += 360 }
        }
        
        let hByte = UInt8((h / 360.0) * 255.0)
        let sByte = UInt8(s * 255.0)
        let vByte = UInt8(v)
        
        return HSV(h: hByte, s: sByte, v: vByte)
    }
}
