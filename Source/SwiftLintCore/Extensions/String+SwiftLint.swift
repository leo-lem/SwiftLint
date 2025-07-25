import Foundation
import SourceKittenFramework

public extension String {
    func hasTrailingWhitespace() -> Bool {
        if isEmpty {
            return false
        }

        if let unicodescalar = unicodeScalars.last {
            return CharacterSet.whitespaces.contains(unicodescalar)
        }

        return false
    }

    func isUppercase() -> Bool {
        self == uppercased()
    }

    func isLowercase() -> Bool {
        self == lowercased()
    }

    private subscript (range: Range<Int>) -> String {
        let nsrange = NSRange(location: range.lowerBound,
                              length: range.upperBound - range.lowerBound)
        if let indexRange = nsrangeToIndexRange(nsrange) {
            return String(self[indexRange])
        }
        queuedFatalError("invalid range")
    }

    func substring(from: Int, length: Int? = nil) -> String {
        if let length {
            return self[from..<from + length]
        }
        return String(self[index(startIndex, offsetBy: from, limitedBy: endIndex)!...])
    }

    func lastIndex(of search: String) -> Int? {
        if let range = range(of: search, options: [.literal, .backwards]) {
            return distance(from: startIndex, to: range.lowerBound)
        }
        return nil
    }

    func nsrangeToIndexRange(_ nsrange: NSRange) -> Range<Index>? {
        guard nsrange.location != NSNotFound else {
            return nil
        }
        let from16 = utf16.index(utf16.startIndex, offsetBy: nsrange.location,
                                 limitedBy: utf16.endIndex) ?? utf16.endIndex
        let to16 = utf16.index(from16, offsetBy: nsrange.length,
                               limitedBy: utf16.endIndex) ?? utf16.endIndex

        guard let fromIndex = Index(from16, within: self),
              let toIndex = Index(to16, within: self) else {
            return nil
        }

        return fromIndex..<toIndex
    }

    var fullNSRange: NSRange {
        NSRange(location: 0, length: utf16.count)
    }

    /// Returns a new string, converting the path to a canonical absolute path.
    ///
    /// - returns: A new `String`.
    func absolutePathStandardized() -> String {
        bridge().absolutePathRepresentation().bridge().standardizingPath
    }

    var isFile: Bool {
        if self.isEmpty {
            return false
        }
        var isDirectoryObjC: ObjCBool = false
        if FileManager.default.fileExists(atPath: self, isDirectory: &isDirectoryObjC) {
            return !isDirectoryObjC.boolValue
        }
        return false
    }

    /// Count the number of occurrences of the given character in `self`
    /// - Parameter character: Character to count
    /// - Returns: Number of times `character` occurs in `self`
    func countOccurrences(of character: Character) -> Int {
        self.reduce(0, {
            $1 == character ? $0 + 1 : $0
        })
    }

    /// If self is a path, this method can be used to get a path expression relative to a root directory
    func path(relativeTo rootDirectory: String) -> String {
        let normalizedRootDir = rootDirectory.bridge().standardizingPath
        let normalizedSelf = bridge().standardizingPath
        if normalizedRootDir.isEmpty {
            return normalizedSelf
        }
        var rootDirComps = normalizedRootDir.components(separatedBy: "/")
        let rootDirCompsCount = rootDirComps.count

        while true {
            let sharedRootDir = rootDirComps.joined(separator: "/")
            if normalizedSelf == sharedRootDir || normalizedSelf.hasPrefix(sharedRootDir + "/") {
                let path = (0 ..< rootDirCompsCount - rootDirComps.count).map { _ in "/.." }.flatMap { $0 }
                    + String(normalizedSelf.dropFirst(sharedRootDir.count))
                return String(path.dropFirst()) // Remove leading '/'
            }
            rootDirComps = rootDirComps.dropLast()
        }
    }

    func deletingPrefix(_ prefix: String) -> String {
        guard hasPrefix(prefix) else { return self }
        return String(dropFirst(prefix.count))
    }

    func indent(by spaces: Int, skipFirst: Bool = false, skipEmptyLines: Bool = true) -> String {
        let lines = components(separatedBy: "\n")
        if skipFirst, let firstLine = lines.first {
            return firstLine + "\n" + lines.dropFirst().indent(by: spaces, skipEmptyLines: skipEmptyLines)
        }
        return lines.indent(by: spaces, skipEmptyLines: skipEmptyLines)
    }

    func linesPrefixed(with prefix: Self) -> Self {
        split(separator: "\n").joined(separator: "\n\(prefix)")
    }

    func characterPosition(of utf8Offset: Int) -> Int? {
        guard utf8Offset != 0 else {
            return 0
        }
        guard utf8Offset > 0, utf8Offset < lengthOfBytes(using: .utf8) else {
            return nil
        }
        for (offset, index) in indices.enumerated() where self[...index].lengthOfBytes(using: .utf8) == utf8Offset {
            return offset + 1
        }
        return nil
    }
}

private extension Sequence where Element == String {
    func indent(by spaces: Int, skipEmptyLines: Bool = true) -> String {
        map { line in
            if skipEmptyLines, line.isEmpty {
                return line
            }
            return String(repeating: " ", count: spaces) + line
        }
        .joined(separator: "\n")
    }
}
