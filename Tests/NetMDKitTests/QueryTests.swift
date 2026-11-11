// Ported from netmd-js src/query-utils.test.ts

import Testing
@testable import NetMDKit

@Suite struct FormatQueryTests {
    @Test func constant() throws {
        #expect(try formatQuery("00 00 00 01") == [0x00, 0x00, 0x00, 0x01])
    }

    @Test func lengthPrefixedBytes() throws {
        #expect(try formatQuery("00 00 00 %x", .bytes(encodeToSJIS("ciao"))) ==
            [0x00, 0x00, 0x00, 0x00, 0x04, 0x63, 0x69, 0x61, 0x6f])
    }

    @Test func rawBytes() throws {
        #expect(try formatQuery("00 00 00 %*", .bytes([0xff, 0x00])) == [0x00, 0x00, 0x00, 0xff, 0x00])
        #expect(try formatQuery("00 00 00 %*", .bytes(encodeToSJIS("abc"))) == [0x00, 0x00, 0x00, 0x61, 0x62, 0x63])
    }

    @Test func nullTerminatedString() throws {
        #expect(try formatQuery("00 00 00 %s", .bytes(encodeToSJIS("ciao"))) ==
            [0x00, 0x00, 0x00, 0x00, 0x05, 0x63, 0x69, 0x61, 0x6f, 0x00])
    }

    @Test func oneByteLengthPrefix() throws {
        #expect(try formatQuery("00 %z", .bytes([0xaa, 0xbb])) == [0x00, 0x02, 0xaa, 0xbb])
    }

    @Test func integers() throws {
        #expect(try formatQuery("00 00 00 %b", 0xff) == [0x00, 0x00, 0x00, 0xff])
        #expect(try formatQuery("00 00 00 %w", 0xff01) == [0x00, 0x00, 0x00, 0xff, 0x01])
        #expect(try formatQuery("00 00 00 %d", 0xff01_9922) == [0x00, 0x00, 0x00, 0xff, 0x01, 0x99, 0x22])
        #expect(try formatQuery("00 00 00 %<d", 0xff01_9922) == [0x00, 0x00, 0x00, 0x22, 0x99, 0x01, 0xff])
        #expect(try formatQuery("00 00 00 %q", 0xff01_9922_2299_01ff) ==
            [0x00, 0x00, 0x00, 0xff, 0x01, 0x99, 0x22, 0x22, 0x99, 0x01, 0xff])
    }

    @Test func bcd() throws {
        #expect(try formatQuery("00 00 00 %B", 24) == [0x00, 0x00, 0x00, 0x24])
        #expect(try formatQuery("00 00 00 %W", 24) == [0x00, 0x00, 0x00, 0x00, 0x24])
        #expect(try formatQuery("%W", 1234) == [0x12, 0x34])
    }

    @Test func missingArgumentThrows() {
        #expect(throws: QueryError.self) { try formatQuery("00 %b") }
    }
}

@Suite struct ScanQueryTests {
    @Test func constantAndWildcard() throws {
        #expect(try scanQuery([0x00, 0x00, 0x00, 0x01], "00 00 00 01").isEmpty)
        #expect(try scanQuery([0x00, 0x00, 0x00, 0x01], "00 00 %? 01").isEmpty)
    }

    @Test func remaining() throws {
        #expect(try scanQuery([0x00, 0x00, 0x00, 0x01], "00 00 %*") == [.bytes([0x00, 0x01])])
    }

    @Test func lengthPrefixedBytes() throws {
        let result = try scanQuery([0x00, 0x00, 0x00, 0x04, 0x63, 0x69, 0x61, 0x6f], "00 00 %x")
        #expect(result == [.bytes(Array("ciao".utf8))])
    }

    @Test func nullTerminatedString() throws {
        let result = try scanQuery([0x00, 0x00, 0x00, 0x05, 0x63, 0x69, 0x61, 0x6f, 0x00], "00 00 %s")
        #expect(result == [.bytes(Array("ciao\0".utf8))])
    }

    @Test func integers() throws {
        #expect(try scanQuery([0x00, 0x00, 0xff], "00 00 %b") == [.int(0xff)])
        #expect(try scanQuery([0x00, 0x00, 0xff, 0x01], "00 00 %w") == [.int(0xff01)])
        #expect(try scanQuery([0x00, 0x00, 0xff, 0x01, 0xaa, 0x10], "00 00 %d") == [.int(0xff01_aa10)])
        #expect(try scanQuery([0x00, 0x00, 0x10, 0xaa, 0x01, 0xff], "00 00 %<d") == [.int(0xff01_aa10)])
        #expect(try scanQuery([0xff, 0x01, 0x99, 0x22, 0x22, 0x99, 0x01, 0xff], "%q") == [.int(0xff01_9922_2299_01ff)])
    }

    @Test func bcd() throws {
        #expect(try scanQuery([0x24], "%B") == [.int(24)])
        #expect(try scanQuery([0x12, 0x34], "%W") == [.int(1234)])
    }

    @Test func missingSkippedByteIsTolerated() throws {
        // The MZ-N910 omits the trailing byte that the playback-status format skips with %?.
        #expect(try scanQuery([0x00, 0x00, 0x01, 0xaa], "00 %x %?") == [.bytes([0xaa])])
    }

    @Test func mismatchThrows() {
        #expect(throws: QueryError.self) { try scanQuery([0x00, 0x01], "00 02") }
    }

    @Test func trailingBytesThrow() {
        #expect(throws: QueryError.trailingBytes(1)) { try scanQuery([0x00, 0x01], "00") }
    }

    @Test func truncatedInputThrows() {
        #expect(throws: QueryError.self) { try scanQuery([0x00], "00 %w") }
    }

    @Test func roundTrip() throws {
        let bytes = try formatQuery("1806 %b %w %x", 3, 0x1234, .bytes([1, 2, 3]))
        #expect(try scanQuery(bytes, "1806 %b %w %x") == [.int(3), .int(0x1234), .bytes([1, 2, 3])])
    }
}

@Suite struct BCDTests {
    @Test func conversions() throws {
        #expect(bcd2Int(0x99) == 99)
        #expect(bcd2Int(0x1234) == 1234)
        #expect(try int2BCD(56) == 0x56)
        #expect(try int2BCD(0) == 0)
        #expect(throws: QueryError.self) { try int2BCD(100) }
    }
}
