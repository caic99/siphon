import XCTest
@testable import SiphonCore

/// Checks the encoder against the real `scutil` parser rather than against our
/// belief about it. Only `d.init` / `d.add` / `d.show` are used — nothing is
/// written to the dynamic store.
final class ScutilEncodingTests: XCTestCase {
    private func show(_ dictionary: ProxyDictionary) throws -> String {
        var lines = dictionary.scutilCommands(setting: "unused")
        lines.removeLast()          // drop `set`, which would need root
        lines.append("d.show")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(lines.joined(separator: "\n").utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: data, as: UTF8.self)
    }

    func testRealScutilReadsBackWhatWeEncode() throws {
        let dictionary = ProxyDictionary(entries: [
            "HTTPEnable": .number(1),
            "HTTPProxy": .string("proxy.example.com"),
            "HTTPPort": .number(3128),
            "ExceptionsList": .array(["*.local", "169.254/16"]),
        ])
        let output = try show(dictionary)
        XCTAssertTrue(output.contains("HTTPEnable : 1"), output)
        XCTAssertTrue(output.contains("HTTPPort : 3128"), output)
        XCTAssertTrue(output.contains("HTTPProxy : proxy.example.com"), output)
        XCTAssertTrue(output.contains("0 : *.local"), output)
        XCTAssertTrue(output.contains("1 : 169.254/16"), output)
    }

    /// Whitespace inside a value is exactly what unquoted `d.add` would split
    /// on, silently turning one exception into two.
    func testValuesWithSpacesSurviveTheRoundTrip() throws {
        let dictionary = ProxyDictionary(entries: [
            "Spaced": .string("two words"),
            "SpacedList": .array(["one two", "three"]),
        ])
        let output = try show(dictionary)
        XCTAssertTrue(output.contains("Spaced : two words"), output)
        XCTAssertTrue(output.contains("0 : one two"), output)
        XCTAssertTrue(output.contains("1 : three"), output)
    }

    func testQuotesInValuesSurviveTheRoundTrip() throws {
        let output = try show(ProxyDictionary(entries: ["Quoted": .string(#"say "hi""#)]))
        XCTAssertTrue(output.contains(#"Quoted : say "hi""#), output)
    }
}
