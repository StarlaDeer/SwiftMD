// SwiftMD - USB access for NetMD devices.
// Replaces the WebUSB / node-usb layer that netmd-js runs on.

import Foundation
import IOKit
import IOKit.usb
import IOUSBHost

/// The handful of USB operations the NetMD protocol needs. Implemented by
/// `IOUSBHostTransport` for real hardware and by mocks in tests.
public protocol USBTransport: AnyObject, Sendable {
    /// Vendor request to the interface, device-to-host.
    func controlIn(request: UInt8, length: Int) throws -> [UInt8]
    /// Vendor request to the interface, host-to-device.
    func controlOut(request: UInt8, data: [UInt8]) throws
    func bulkIn(length: Int) throws -> [UInt8]
    func bulkOut(_ data: [UInt8]) throws
    func close()
}

public enum USBError: Error, CustomStringConvertible {
    case noDeviceFound
    case interfaceNotFound(vendorID: Int, productID: Int)
    case pipeNotFound(address: Int)
    case io(String)

    public var description: String {
        switch self {
        case .noDeviceFound: return "No NetMD device is connected."
        case let .interfaceNotFound(v, p):
            return String(format: "Could not find USB interface 0 on device %04x:%04x.", v, p)
        case .pipeNotFound(let a): return String(format: "USB endpoint 0x%02x not found.", a)
        case .io(let msg): return msg
        }
    }
}

/// A NetMD device seen on the USB bus, not yet opened.
public struct USBDeviceInfo: Sendable, Hashable, Identifiable {
    public let vendorID: Int
    public let productID: Int
    public let registryID: UInt64
    public var id: UInt64 { registryID }

    public var definition: DeviceDefinition? {
        knownDevices.first { $0.vendorID == vendorID && $0.productID == productID }
    }

    public var name: String { definition?.name ?? "Unknown Device" }
}

private let bulkReadEndpoint = 0x81 // endpoint 1, IN
private let bulkWriteEndpoint = 0x02 // endpoint 2, OUT
// bmRequestType: direction | vendor (0x40) | recipient interface (0x01)
private let vendorInterfaceIn: UInt8 = 0xc1
private let vendorInterfaceOut: UInt8 = 0x41
/// netmd-js's CLI gives node-usb a 1000-second device timeout. Decks can take several seconds to
/// accept a command while finishing earlier work (an MZ-N707 took over 5 s right after an erase).
private let controlTimeout: TimeInterval = 120
private let bulkReadTimeout: TimeInterval = 30
/// No timeout (0) for bulk writes, as with node-usb in netmd-js. While recording, a deck fills its
/// buffer (about 8 MB on an MZ-N910), then stops taking data while it writes to the disc ("Data Save"),
/// often for well over 30 seconds. Giving up then aborts the recording with "REC Error".
/// Unplugging the device still ends a stuck write.
private let bulkWriteTimeout: TimeInterval = 0

/// NetMD over IOUSBHost. NetMD devices expose a vendor-specific interface that macOS
/// does not bind a driver to, so a normal user-space app can claim it.
public final class IOUSBHostTransport: USBTransport, @unchecked Sendable {
    // IOUSBHost objects are not Sendable; all access happens from the owning NetMD actor.
    private let interface: IOUSBHostInterface
    private let readPipe: IOUSBHostPipe
    private let writePipe: IOUSBHostPipe
    public let info: USBDeviceInfo

    /// Lists connected devices that appear in the NetMD device table.
    public static func connectedDevices() -> [USBDeviceInfo] {
        var found: [USBDeviceInfo] = []
        let matching = IOServiceMatching(kIOUSBHostDeviceClassName)
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let vendor = intProperty(service, kUSBVendorID),
                  let product = intProperty(service, kUSBProductID),
                  knownDevices.contains(where: { $0.vendorID == vendor && $0.productID == product })
            else { continue }
            var registryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &registryID)
            found.append(USBDeviceInfo(vendorID: vendor, productID: product, registryID: registryID))
        }
        return found
    }

    public init(device: USBDeviceInfo, interfaceNumber: Int = 0) throws {
        info = device
        let matching = IOUSBHostInterface.__createMatchingDictionary(
            withVendorID: NSNumber(value: device.vendorID),
            productID: NSNumber(value: device.productID),
            bcdDevice: nil,
            interfaceNumber: NSNumber(value: interfaceNumber),
            // IOKit only matches interfaces by vendor/product when the configuration is given too.
            configurationValue: 1,
            interfaceClass: nil,
            interfaceSubclass: nil,
            interfaceProtocol: nil,
            speed: nil,
            productIDArray: nil
        ).takeRetainedValue()
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else {
            throw USBError.interfaceNotFound(vendorID: device.vendorID, productID: device.productID)
        }
        defer { IOObjectRelease(service) }

        interface = try IOUSBHostInterface(
            __ioService: service,
            options: [],
            queue: nil,
            interestHandler: nil
        )
        do {
            readPipe = try interface.copyPipe(withAddress: bulkReadEndpoint)
            writePipe = try interface.copyPipe(withAddress: bulkWriteEndpoint)
        } catch {
            interface.destroy()
            throw error
        }
    }

    deinit { interface.destroy() }

    public func close() { interface.destroy() }

    private func request(type: UInt8, request: UInt8, length: Int) -> IOUSBDeviceRequest {
        IOUSBDeviceRequest(
            bmRequestType: type,
            bRequest: request,
            wValue: 0,
            wIndex: 0,
            wLength: UInt16(length)
        )
    }

    public func controlIn(request bRequest: UInt8, length: Int) throws -> [UInt8] {
        let data = NSMutableData(length: length)!
        var transferred = 0
        try interface.__send(
            request(type: vendorInterfaceIn, request: bRequest, length: length),
            data: data,
            bytesTransferred: &transferred,
            completionTimeout: controlTimeout
        )
        return Array(UnsafeRawBufferPointer(start: data.bytes, count: transferred))
    }

    public func controlOut(request bRequest: UInt8, data bytes: [UInt8]) throws {
        let data = NSMutableData(bytes: bytes, length: bytes.count)
        var transferred = 0
        try interface.__send(
            request(type: vendorInterfaceOut, request: bRequest, length: bytes.count),
            data: data,
            bytesTransferred: &transferred,
            completionTimeout: controlTimeout
        )
    }

    public func bulkIn(length: Int) throws -> [UInt8] {
        let data = NSMutableData(length: length)!
        var transferred = 0
        try readPipe.__sendIORequest(with: data, bytesTransferred: &transferred, completionTimeout: bulkReadTimeout)
        return Array(UnsafeRawBufferPointer(start: data.bytes, count: transferred))
    }

    public func bulkOut(_ bytes: [UInt8]) throws {
        let data = NSMutableData(bytes: bytes, length: bytes.count)
        var transferred = 0
        try writePipe.__sendIORequest(with: data, bytesTransferred: &transferred, completionTimeout: bulkWriteTimeout)
        guard transferred == bytes.count else {
            throw USBError.io("USB write sent \(transferred) of \(bytes.count) bytes")
        }
    }
}

private func intProperty(_ service: io_service_t, _ key: String) -> Int? {
    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
        .takeRetainedValue() as? Int
}
