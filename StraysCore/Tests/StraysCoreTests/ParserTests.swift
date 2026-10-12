import XCTest
@testable import StraysCore

final class ProcArgsParserTests: XCTestCase {
    /// Builds a KERN_PROCARGS2 buffer the way the kernel lays it out.
    private func buffer(argc: Int32, path: String, padding: Int = 3, strings: [String], trailer: [String] = []) -> [UInt8] {
        var bytes = withUnsafeBytes(of: argc) { Array($0) }
        bytes += Array(path.utf8) + [0]
        bytes += [UInt8](repeating: 0, count: padding)
        for string in strings { bytes += Array(string.utf8) + [0] }
        bytes += [0]
        for string in trailer { bytes += Array(string.utf8) + [0] }
        return bytes
    }

    func testParsesPathArgumentsAndEnvironment() throws {
        let bytes = buffer(
            argc: 3,
            path: "/usr/local/bin/node",
            strings: ["node", "server.js", "--port=3000", "HOME=/Users/me", "CLAUDECODE=1", "EMPTY="],
            trailer: ["executable_path=/usr/local/bin/node", "ptr_munge="]
        )
        let parsed = try XCTUnwrap(ProcArgsParser.parse(bytes))
        XCTAssertEqual(parsed.executablePath, "/usr/local/bin/node")
        XCTAssertEqual(parsed.arguments, ["node", "server.js", "--port=3000"])
        XCTAssertEqual(parsed.environment, ["HOME": "/Users/me", "CLAUDECODE": "1", "EMPTY": ""])
    }

    func testAppleStringsAreNotMistakenForEnvironment() throws {
        let bytes = buffer(argc: 1, path: "/bin/sleep", strings: ["sleep"], trailer: ["executable_path=/bin/sleep"])
        let parsed = try XCTUnwrap(ProcArgsParser.parse(bytes))
        XCTAssertEqual(parsed.arguments, ["sleep"])
        XCTAssertTrue(parsed.environment.isEmpty)
    }

    func testKeepsValuesContainingEqualsSigns() throws {
        let bytes = buffer(argc: 1, path: "/bin/x", strings: ["x", "OPTS=a=b=c"])
        XCTAssertEqual(try XCTUnwrap(ProcArgsParser.parse(bytes)).environment["OPTS"], "a=b=c")
    }

    func testFirstDefinitionOfADuplicateVariableWins() throws {
        let bytes = buffer(argc: 1, path: "/bin/x", strings: ["x", "A=1", "A=2"])
        XCTAssertEqual(try XCTUnwrap(ProcArgsParser.parse(bytes)).environment["A"], "1")
    }

    /// npm sets `process.title`, which makes libuv overwrite the argv area
    /// with the title and zero the rest.
    func testRecoversArgumentsAfterTitleRewrite() throws {
        var bytes = withUnsafeBytes(of: Int32(3)) { Array($0) }
        bytes += Array("/usr/local/bin/node".utf8) + [0, 0, 0]
        bytes += Array("npm run dev".utf8) + [UInt8](repeating: 0, count: 24)
        bytes += Array("HOME=/Users/me".utf8) + [0] + Array("PORT=3000".utf8) + [0, 0]
        let parsed = try XCTUnwrap(ProcArgsParser.parse(bytes))
        XCTAssertEqual(parsed.arguments, ["npm", "run", "dev"])
        XCTAssertEqual(parsed.environment, ["HOME": "/Users/me", "PORT": "3000"])
    }

    func testGenuineEmptyArgumentsAreKept() throws {
        let bytes = buffer(argc: 3, path: "/bin/echo", strings: ["echo", "", "x", "A=1"])
        let parsed = try XCTUnwrap(ProcArgsParser.parse(bytes))
        XCTAssertEqual(parsed.arguments, ["echo", "", "x"])
        XCTAssertEqual(parsed.environment, ["A": "1"])
    }

    func testRejectsGarbage() {
        XCTAssertNil(ProcArgsParser.parse([]))
        XCTAssertNil(ProcArgsParser.parse([1, 2]))
        XCTAssertNil(ProcArgsParser.parse([0xFF, 0xFF, 0xFF, 0xFF, 0x41]))
    }

    func testTruncatedBufferDoesNotCrash() throws {
        let bytes = Array(buffer(argc: 5, path: "/bin/x", strings: ["x", "y"]).dropLast(3))
        let parsed = try XCTUnwrap(ProcArgsParser.parse(bytes))
        XCTAssertEqual(parsed.arguments.first, "x")
    }
}

final class LsofParserTests: XCTestCase {
    // Captured from `lsof -nP -iTCP -sTCP:LISTEN -F pcnPT` on macOS.
    private let sample = """
    p625
    cControlCenter
    f10
    PTCP
    n*:7000
    TST=LISTEN
    f11
    PTCP
    n*:7000
    TST=LISTEN
    p755
    cpostgres
    f7
    PTCP
    n[::1]:5432
    TST=LISTEN
    f8
    PTCP
    n127.0.0.1:5432
    TST=LISTEN
    """

    func testParsesProcessesAndEndpoints() {
        let ports = Set(LsofParser.parse(sample))
        XCTAssertEqual(ports, [
            ListeningPort(pid: 625, port: 7000, transport: .tcp, address: "*"),
            ListeningPort(pid: 755, port: 5432, transport: .tcp, address: "::1"),
            ListeningPort(pid: 755, port: 5432, transport: .tcp, address: "127.0.0.1"),
        ])
    }

    func testWildcardIsLANVisibleAndLoopbackIsNot() {
        let ports = LsofParser.parse(sample)
        XCTAssertTrue(ports.first { $0.pid == 625 }!.isLANVisible)
        XCTAssertFalse(ports.contains { $0.pid == 755 && $0.isLANVisible })
    }

    func testIgnoresNoiseAndEmptyInput() {
        XCTAssertTrue(LsofParser.parse("").isEmpty)
        XCTAssertTrue(LsofParser.parse("n*:80\nxgarbage\np\n").isEmpty, "a name without a PID is not a port")
        XCTAssertTrue(LsofParser.parse("p12\nnnot-an-endpoint\nn*:notaport\n").isEmpty)
    }
}

final class NetstatParserTests: XCTestCase {
    // Captured from `netstat -anv -p tcp` on macOS 26.
    private let sample = """
    Active Internet connections (including servers)
    Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)          rxbytes      txbytes  rhiwat  shiwat          process:pid    state  options           gencnt    flags   flags1 usecnt rtncnt fltrs
    tcp4       0      0  192.168.1.20.52011     17.57.146.20.5223      ESTABLISHED         5120         4096  131072  131072         apsd:412    00102 00000008 0000000000081d7f 00000000 00080800      1      0 000000
    tcp46      0      0  *.52288                *.*                    LISTEN                 0            0  131072  131072         rapportd:646    00100 00000006 0000000000081d7f 00000000 00080800      1      0 000000
    tcp6       0      0  *.56293                *.*                    LISTEN                 0            0  131072  131072 io.tailscale.ipn:26815  00180 00000006 000000000007d19e 00000000 00000800      1      0 000000
    tcp4       0      0  *.45824                *.*                    LISTEN                 0            0  131072  131072 io.tailscale.ipn:26815  00180 00000006 000000000007d19d 00000000 00000800      1      0 000000
    tcp4       0      0  127.0.0.1.57482        *.*                    LISTEN                 0            0  131072  131072 Code Helper (Plu:20009  00100 00000106 000000000006e803 00000001 00000800      1      0 000000
    tcp6       0      0  ::1.5432               *.*                    LISTEN                 0            0  131072  131072         postgres:755    00100 00000006 0000000000000a11 00000000 00000800      1      0 000000
    tcp6       0      0  fe80::1%lo0.8021       *.*                    LISTEN                 0            0  131072  131072           ftpd:99     00100 00000006 0000000000000a12 00000000 00000800      1      0 000000
    """

    private var listeners: [NetstatParser.Listener] { NetstatParser.parse(sample) }

    private func port(_ number: UInt16) -> ListeningPort? {
        listeners.first { $0.port.port == number }?.port
    }

    func testOnlyListeningSocketsAreReported() {
        XCTAssertEqual(listeners.count, 6)
        XCTAssertNil(port(52011))
    }

    func testWildcardAddressFollowsTheProtocolFamily() {
        XCTAssertEqual(port(52288)?.address, "*")
        XCTAssertEqual(port(56293)?.address, "::")
        XCTAssertEqual(port(45824)?.address, "0.0.0.0")
    }

    func testProcessNamesWithSpacesKeepTheRightPID() throws {
        let helper = try XCTUnwrap(listeners.first { $0.port.port == 57482 })
        XCTAssertEqual(helper.port.pid, 20009)
        XCTAssertEqual(helper.processName, "Code Helper (Plu")
        XCTAssertEqual(helper.port.address, "127.0.0.1")
    }

    func testIPv6EndpointsSplitAtTheLastDot() {
        XCTAssertEqual(port(5432)?.address, "::1")
        XCTAssertEqual(port(8021)?.address, "fe80::1%lo0")
        XCTAssertEqual(port(8021)?.isLANVisible, false)
    }
}

final class ListeningPortTests: XCTestCase {
    func testLoopbackDetection() {
        for address in ["127.0.0.1", "127.1.2.3", "::1", "[::1]", "::ffff:127.0.0.1", "fe80::1%lo0", "localhost"] {
            XCTAssertTrue(ListeningPort.isLoopback(address), address)
        }
        for address in ["*", "0.0.0.0", "::", "192.168.1.4", "10.0.0.1", "fe80::1%en0", "127.evil.example"] {
            XCTAssertFalse(ListeningPort.isLoopback(address), address)
        }
    }

    func testSummaryCollapsesSocketsOfTheSamePort() {
        let summary = PortSummary.summarize([
            ListeningPort(pid: 9, port: 3000, transport: .tcp, address: "127.0.0.1"),
            ListeningPort(pid: 7, port: 3000, transport: .tcp, address: "::1"),
            ListeningPort(pid: 7, port: 8080, transport: .tcp, address: "*"),
            ListeningPort(pid: 7, port: 5353, transport: .udp, address: "0.0.0.0"),
        ])
        XCTAssertEqual(summary.map(\.id), ["tcp:3000", "tcp:8080", "udp:5353"])
        XCTAssertEqual(summary[0].addresses, ["127.0.0.1", "::1"])
        XCTAssertEqual(summary[0].pid, 7)
        XCTAssertFalse(summary[0].isLANVisible)
        XCTAssertTrue(summary[1].isLANVisible)
    }
}
