// SwiftMD - port of the device table in netmd-js src/netmd.ts
// Original: Copyright (C) Stefano Brilli, Asivery (https://github.com/cybercase/netmd-js)
// Licensed under the GNU General Public License v2.0.

public struct DeviceFlags: Sendable, Hashable {
    public var nativeMonoUpload = false
    public var nativeLPEncoding = false
}

public struct DeviceDefinition: Sendable, Hashable {
    public let vendorID: Int
    public let productID: Int
    public let name: String
    public let flags: DeviceFlags

    init(_ vendorID: Int, _ productID: Int, _ name: String, flags: DeviceFlags = DeviceFlags()) {
        self.vendorID = vendorID
        self.productID = productID
        self.name = name
        self.flags = flags
    }
}

private let mono = DeviceFlags(nativeMonoUpload: true)

public let knownDevices: [DeviceDefinition] = [
    DeviceDefinition(0x04dd, 0x7202, "Sharp IM-MT899H"),
    DeviceDefinition(0x04dd, 0x9013, "Sharp IM-DR400"),
    DeviceDefinition(0x04dd, 0x9014, "Sharp IM-DR80", flags: mono),
    DeviceDefinition(0x054c, 0x0034, "Sony PCLK-XX"),
    DeviceDefinition(0x054c, 0x0036, "Sony"),
    DeviceDefinition(0x054c, 0x0075, "Sony MZ-N1"),
    DeviceDefinition(0x054c, 0x007c, "Sony"),
    DeviceDefinition(0x054c, 0x0080, "Sony LAM-1"),
    DeviceDefinition(0x054c, 0x0081, "Sony MDS-JB980/MDS-NT1/MDS-JE780", flags: mono),
    DeviceDefinition(0x054c, 0x0084, "Sony MZ-N505"),
    DeviceDefinition(0x054c, 0x0085, "Sony MZ-S1"),
    DeviceDefinition(0x054c, 0x0086, "Sony MZ-N707"),
    DeviceDefinition(0x054c, 0x008e, "Sony CMT-C7NT"),
    DeviceDefinition(0x054c, 0x0097, "Sony PCGA-MDN1"),
    DeviceDefinition(0x054c, 0x00ad, "Sony CMT-L7HD"),
    DeviceDefinition(0x054c, 0x00c6, "Sony MZ-N10"),
    DeviceDefinition(0x054c, 0x00c7, "Sony MZ-N910"),
    DeviceDefinition(0x054c, 0x00c8, "Sony MZ-N710/NF810"),
    DeviceDefinition(0x054c, 0x00c9, "Sony MZ-N510/N610"),
    DeviceDefinition(0x054c, 0x00ca, "Sony MZ-NE410/NF520D"),
    DeviceDefinition(0x054c, 0x00e7, "Sony CMT-M333NT/M373NT"),
    DeviceDefinition(0x054c, 0x00eb, "Sony MZ-NE810/NE910"),
    DeviceDefinition(0x054c, 0x0101, "Sony LAM"), // They all report the same VID/PID
    DeviceDefinition(0x054c, 0x0113, "Aiwa AM-NX1"),
    DeviceDefinition(0x054c, 0x013f, "Sony MDS-S500"),
    DeviceDefinition(0x054c, 0x014c, "Aiwa AM-NX9"),
    DeviceDefinition(0x054c, 0x017e, "Sony MZ-NH1"),
    DeviceDefinition(0x054c, 0x0180, "Sony MZ-NH3D"),
    DeviceDefinition(0x054c, 0x0182, "Sony MZ-NH900"),
    DeviceDefinition(0x054c, 0x0184, "Sony MZ-NH700/NH800"),
    DeviceDefinition(0x054c, 0x0186, "Sony MZ-NH600"),
    DeviceDefinition(0x054c, 0x0187, "Sony MZ-NH600D"),
    DeviceDefinition(0x054c, 0x0188, "Sony MZ-N920"),
    DeviceDefinition(0x054c, 0x018a, "Sony LAM-3"),
    DeviceDefinition(0x054c, 0x01e9, "Sony MZ-DH10P"),
    DeviceDefinition(0x054c, 0x0219, "Sony MZ-RH10"),
    DeviceDefinition(0x054c, 0x021b, "Sony MZ-RH710/MZ-RH910"),
    DeviceDefinition(0x054c, 0x021d, "Sony CMT-AH10"),
    DeviceDefinition(0x054c, 0x022c, "Sony CMT-AH10"),
    DeviceDefinition(0x054c, 0x023c, "Sony DS-HMD1"),
    DeviceDefinition(0x054c, 0x0286, "Sony MZ-RH1"),
    DeviceDefinition(0x054c, 0x011a, "Sony CMT-SE7"),
    DeviceDefinition(0x054c, 0x0148, "Sony MDS-A1"),
    DeviceDefinition(0x0b28, 0x1004, "Kenwood MDX-J9"),
    DeviceDefinition(0x04da, 0x23b3, "Panasonic SJ-MR250", flags: mono),
    DeviceDefinition(0x04da, 0x23b6, "Panasonic SJ-MR270", flags: mono),
    DeviceDefinition(0x0411, 0x0083, "Buffalo MD-HUSB"),
]
