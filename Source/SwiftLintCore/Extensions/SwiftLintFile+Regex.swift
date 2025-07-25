import Foundation
import SourceKittenFramework

public func regex(_ pattern: String,
                  options: NSRegularExpression.Options? = nil) -> NSRegularExpression {
    // all patterns used for regular expressions in SwiftLint are string literals which have been
    // confirmed to work, so it's ok to force-try here.

    let options = options ?? [.anchorsMatchLines, .dotMatchesLineSeparators]
    // swiftlint:disable:next force_try
    return try! .cached(pattern: pattern, options: options)
}

extension SwiftLintFile {
    public func regions(restrictingRuleIdentifiers: Set<RuleIdentifier>? = nil) -> [Region] {
        var regions = [Region]()
        var disabledRules = Set<RuleIdentifier>()
        let commands: [Command]
        if let restrictingRuleIdentifiers {
            commands = self.commands().filter { command in
                command.ruleIdentifiers.contains(where: restrictingRuleIdentifiers.contains)
            }
        } else {
            commands = self.commands()
        }
        let commandPairs = zip(commands, Array(commands.dropFirst().map(Optional.init)) + [nil])
        for (command, nextCommand) in commandPairs {
            switch command.action {
            case .disable:
                disabledRules.formUnion(command.ruleIdentifiers)

            case .enable:
                disabledRules.subtract(command.ruleIdentifiers)

            case .invalid:
                break
            }

            let start = Location(file: path, line: command.line, character: command.range?.upperBound)
            let end = endOf(next: nextCommand)
            guard start < end else { continue }
            var didSetRegion = false
            for (index, region) in zip(regions.indices, regions) where region.start == start && region.end == end {
                regions[index] = Region(
                    start: start,
                    end: end,
                    disabledRuleIdentifiers: disabledRules.union(region.disabledRuleIdentifiers)
                )
                didSetRegion = true
            }
            if !didSetRegion {
                regions.append(
                    Region(start: start, end: end, disabledRuleIdentifiers: disabledRules)
                )
            }
        }
        return regions
    }

    public func commands(in range: NSRange? = nil) -> [Command] {
        guard let range else {
            return commands
                .flatMap { $0.expand() }
        }

        let rangeStart = Location(file: self, characterOffset: range.location)
        let rangeEnd = Location(file: self, characterOffset: NSMaxRange(range))
        return commands
            .filter { command in
                let commandLocation = Location(file: path, line: command.line, character: command.range?.upperBound)
                return rangeStart <= commandLocation && commandLocation <= rangeEnd
            }
            .flatMap { $0.expand() }
    }

    fileprivate func endOf(next command: Command?) -> Location {
        guard let nextCommand = command else {
            return Location(file: path, line: .max, character: .max)
        }
        let nextLine: Int
        let nextCharacter: Int?
        if let nextCommandCharacter = nextCommand.range?.upperBound {
            nextLine = nextCommand.line
            if nextCommandCharacter > 0 {
                nextCharacter = nextCommandCharacter - 1
            } else {
                nextCharacter = nil
            }
        } else {
            nextLine = max(nextCommand.line - 1, 0)
            nextCharacter = .max
        }
        return Location(file: path, line: nextLine, character: nextCharacter)
    }

    public func match(pattern: String, with syntaxKinds: [SyntaxKind], range: NSRange? = nil) -> [NSRange] {
        match(pattern: pattern, range: range)
            .filter { $0.1 == syntaxKinds }
            .map(\.0)
    }

    public func matchesAndTokens(matching pattern: String,
                                 range: NSRange? = nil) -> [(NSTextCheckingResult, [SwiftLintSyntaxToken])] {
        let contents = stringView
        let range = range ?? contents.range
        let syntax = syntaxMap
        return regex(pattern).matches(in: contents, options: [], range: range).compactMap { match in
            let matchByteRange = contents.NSRangeToByteRange(start: match.range.location, length: match.range.length)
            return matchByteRange.map { (match, syntax.tokens(inByteRange: $0)) }
        }
    }

    public func matchesAndSyntaxKinds(matching pattern: String,
                                      range: NSRange? = nil) -> [(NSTextCheckingResult, [SyntaxKind])] {
        matchesAndTokens(matching: pattern, range: range).map { textCheckingResult, tokens in
            (textCheckingResult, tokens.kinds)
        }
    }

    public func match(pattern: String, range: NSRange? = nil, captureGroup: Int = 0) -> [(NSRange, [SyntaxKind])] {
        matchesAndSyntaxKinds(matching: pattern, range: range).map { textCheckingResult, syntaxKinds in
            (textCheckingResult.range(at: captureGroup), syntaxKinds)
        }
    }

    public func swiftDeclarationKindsByLine() -> [[SwiftDeclarationKind]]? {
        if sourcekitdFailed {
            return nil
        }
        var results = [[SwiftDeclarationKind]](repeating: [], count: lines.count + 1)
        var lineIterator = lines.makeIterator()
        var structureIterator = structureDictionary.kinds().makeIterator()
        var maybeLine = lineIterator.next()
        var maybeStructure = structureIterator.next()
        while let line = maybeLine, let structure = maybeStructure {
            if line.byteRange.contains(structure.byteRange.location),
               let swiftDeclarationKind = SwiftDeclarationKind(rawValue: structure.kind) {
                results[line.index].append(swiftDeclarationKind)
            }
            if structure.byteRange.location >= line.byteRange.upperBound {
                maybeLine = lineIterator.next()
            } else {
                maybeStructure = structureIterator.next()
            }
        }
        return results
    }

    public func syntaxTokensByLine() -> [[SwiftLintSyntaxToken]]? {
        if sourcekitdFailed {
            return nil
        }
        var results = [[SwiftLintSyntaxToken]](repeating: [], count: lines.count + 1)
        var tokenGenerator = syntaxMap.tokens.makeIterator()
        var lineGenerator = lines.makeIterator()
        var maybeLine = lineGenerator.next()
        var maybeToken = tokenGenerator.next()
        while let line = maybeLine, let token = maybeToken {
            let tokenRange = token.range
            if line.byteRange.contains(token.offset) ||
                tokenRange.contains(line.byteRange.location) {
                results[line.index].append(token)
            }
            let tokenEnd = tokenRange.upperBound
            let lineEnd = line.byteRange.upperBound
            if tokenEnd < lineEnd {
                maybeToken = tokenGenerator.next()
            } else if tokenEnd > lineEnd {
                maybeLine = lineGenerator.next()
            } else {
                maybeLine = lineGenerator.next()
                maybeToken = tokenGenerator.next()
            }
        }
        return results
    }

    public func syntaxKindsByLine() -> [[SyntaxKind]]? {
        guard !sourcekitdFailed, let tokens = syntaxTokensByLine() else {
            return nil
        }

        return tokens.map(\.kinds)
    }

    /**
     This function returns only matches that are not contained in a syntax kind
     specified.

     - parameter pattern: regex pattern to be matched inside file.
     - parameter excludingSyntaxKinds: syntax kinds the matches to be filtered
     when inside them.

     - returns: An array of [NSRange] objects consisting of regex matches inside
     file contents.
     */
    public func match(pattern: String,
                      excludingSyntaxKinds syntaxKinds: Set<SyntaxKind>,
                      range: NSRange? = nil,
                      captureGroup: Int = 0) -> [NSRange] {
        match(pattern: pattern, range: range, captureGroup: captureGroup)
            .filter { syntaxKinds.isDisjoint(with: $0.1) }
            .map(\.0)
    }

    public func append(_ string: String) {
        guard string.isNotEmpty else {
            return
        }
        file.contents += string
        if isVirtual {
            return
        }
        guard let stringData = string.data(using: .utf8) else {
            queuedFatalError("can't encode '\(string)' with UTF8")
        }
        guard let path, let fileHandle = FileHandle(forWritingAtPath: path) else {
            queuedFatalError("can't write to path '\(String(describing: self.path))'")
        }
        _ = fileHandle.seekToEndOfFile()
        fileHandle.write(stringData)
        fileHandle.closeFile()
        invalidateCache()
    }

    public func write<S: StringProtocol>(_ string: S) {
        guard string != contents else {
            return
        }
        file.contents = String(string)
        if isVirtual {
            return
        }
        guard let path else {
            queuedFatalError("file needs a path to call write(_:)")
        }
        guard let stringData = String(string).data(using: .utf8) else {
            queuedFatalError("can't encode '\(string)' with UTF8")
        }
        do {
            try stringData.write(to: URL(fileURLWithPath: path, isDirectory: false), options: .atomic)
        } catch {
            queuedFatalError("can't write file to \(path)")
        }
        invalidateCache()
    }

    public func ruleEnabled(violatingRanges: [NSRange], for rule: some Rule) -> [NSRange] {
        let fileRegions = regions()
        if fileRegions.isEmpty { return violatingRanges }
        return violatingRanges.filter { range in
            let region = fileRegions.first {
                $0.contains(Location(file: self, characterOffset: range.location))
            }
            return region?.isRuleEnabled(rule) ?? true
        }
    }

    public func ruleEnabled(violatingRange: NSRange, for rule: some Rule) -> NSRange? {
        ruleEnabled(violatingRanges: [violatingRange], for: rule).first
    }

    public func contents(for token: SwiftLintSyntaxToken) -> String? {
        stringView.substringWithByteRange(token.range)
    }
}
