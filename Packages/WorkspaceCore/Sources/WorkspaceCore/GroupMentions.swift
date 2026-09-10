import Foundation

public struct GroupMentionMember: Sendable, Equatable {
  public let id: UUID
  public let name: String

  public init(id: UUID, name: String) {
    self.id = id
    self.name = name
  }
}

public struct GroupMentionResolution: Sendable, Equatable {
  public let targetBotIDs: [UUID]
  public let issues: [GroupMentionIssue]
  public let hasMentions: Bool
  public let messageText: String

  public init(
    targetBotIDs: [UUID], issues: [GroupMentionIssue], hasMentions: Bool, messageText: String
  ) {
    self.targetBotIDs = targetBotIDs
    self.issues = issues
    self.hasMentions = hasMentions
    self.messageText = messageText
  }
}

public enum GroupMentionIssue: Error, Sendable, Equatable, LocalizedError {
  case incompleteMention
  case invalidQuotedName
  case invalidBinding
  case invalidMemberName
  case unknownMember
  case ambiguousMember
  case staleMemberBinding
  case tooManyTargets(maximum: Int)

  public var errorDescription: String? {
    switch self {
    case .incompleteMention:
      return "Finish the member mention, or type \\@ to keep it as literal text."
    case .invalidQuotedName:
      return "Use a valid quoted member mention, or insert one from the member picker."
    case .invalidBinding:
      return
        "This member mention has an invalid identity binding. Insert it again from the member picker."
    case .invalidMemberName:
      return "Member names in mentions must contain between 1 and 80 characters."
    case .unknownMember:
      return "No current group member matches this mention. Type \\@ for a literal handle."
    case .ambiguousMember:
      return "More than one group member has this name. Choose a member from the picker."
    case .staleMemberBinding:
      return
        "This member mention is stale or no longer belongs to the group. Insert it again from the picker."
    case .tooManyTargets(let maximum):
      return "A group round can address at most \(maximum) members."
    }
  }
}

public enum GroupMentions {
  private static let maximumNameLength = 80
  private static let maximumTargets = 6
  private static let openingBoundaries: Set<Unicode.Scalar> = [
    "(", "[", "{", "<", "\"", "'", "“", "‘", ",", ":", ";", "!", "?", "—", "–",
  ]

  public static func token(for member: GroupMentionMember) throws -> String {
    guard isValidName(member.name) else {
      throw GroupMentionIssue.invalidMemberName
    }
    let encoded = try JSONEncoder().encode(member.name)
    guard let quotedName = String(data: encoded, encoding: .utf8) else {
      throw GroupMentionIssue.invalidMemberName
    }
    return "@\(quotedName){\(member.id.uuidString.lowercased())}"
  }

  public static func resolve(
    _ text: String,
    members: [GroupMentionMember]
  ) -> GroupMentionResolution {
    let scalars = text.unicodeScalars
    let normalizedMembers = members.map {
      GroupMentionMember(id: $0.id, name: normalize($0.name))
    }
    let membersByID = Dictionary(grouping: normalizedMembers, by: \.id)
    let membersByName = Dictionary(grouping: normalizedMembers, by: \.name)

    var targets: [UUID] = []
    var seenTargets = Set<UUID>()
    var issues: [GroupMentionIssue] = []
    var hasMentions = false
    var reportedTooManyTargets = false
    var removedRanges: [Range<String.Index>] = []
    let code = codeScan(in: scalars)
    var index = scalars.startIndex

    func appendTarget(_ id: UUID) {
      guard seenTargets.insert(id).inserted else { return }
      guard targets.count < maximumTargets else {
        if !reportedTooManyTargets {
          issues.append(.tooManyTargets(maximum: maximumTargets))
          reportedTooManyTargets = true
        }
        return
      }
      targets.append(id)
    }

    while index < scalars.endIndex {
      if let run = code.runs[index] {
        index =
          run.isFence
          ? fenceEnd(after: run, in: scalars, runs: code.runs)
          : code.inlineEnds[index] ?? run.end
        continue
      }
      if let end = urlSpanEnd(in: scalars, from: index) {
        index = end
        continue
      }
      guard scalars[index] == "@" else {
        index = scalars.index(after: index)
        continue
      }

      if isLexicalEmail(in: scalars, at: index) {
        index = scalars.index(after: index)
        continue
      }
      let escapeRun = precedingBackslashRun(in: scalars, before: index)
      guard isMentionBoundary(in: scalars, before: escapeRun.start) else {
        index = scalars.index(after: index)
        continue
      }
      if escapeRun.count % 2 == 1 {
        let escapedSlash = scalars.index(before: index)..<index
        removedRanges.append(escapedSlash)
        index = scalars.index(after: index)
        continue
      }

      hasMentions = true
      let afterAt = scalars.index(after: index)
      guard afterAt < scalars.endIndex else {
        issues.append(.incompleteMention)
        break
      }

      if scalars[afterAt] == "\"" {
        let parsed = parseQuotedMention(in: scalars, quoteIndex: afterAt)
        index = parsed.endIndex
        switch parsed.result {
        case .failure(let issue):
          issues.append(issue)
        case .success(let mention):
          if let bindingRange = mention.bindingRange {
            removedRanges.append(bindingRange)
          }
          let normalizedName = normalize(mention.name)
          guard isValidName(normalizedName) else {
            issues.append(.invalidMemberName)
            continue
          }
          if let boundID = mention.boundID {
            guard
              let matches = membersByID[boundID], matches.count == 1,
              matches[0].name == normalizedName
            else {
              issues.append(.staleMemberBinding)
              continue
            }
            appendTarget(boundID)
          } else {
            resolveUnbound(
              normalizedName, membersByName: membersByName,
              appendTarget: appendTarget, appendIssue: { issues.append($0) })
          }
        }
        continue
      }

      var end = afterAt
      while end < scalars.endIndex, isSimpleNameContinuation(scalars[end]) {
        end = scalars.index(after: end)
      }
      guard isSimpleNameStart(scalars[afterAt]) else {
        issues.append(isCombiningMark(scalars[afterAt]) ? .invalidMemberName : .incompleteMention)
        index = end > afterAt ? end : scalars.index(after: afterAt)
        continue
      }
      guard isTokenTailBoundary(in: scalars, at: end) else {
        issues.append(scalars[end] == "{" ? .invalidBinding : .invalidQuotedName)
        index = end
        continue
      }
      let normalizedName = normalize(String(scalars[afterAt..<end]))
      if normalizedName.count > maximumNameLength {
        issues.append(.invalidMemberName)
      } else {
        resolveUnbound(
          normalizedName, membersByName: membersByName,
          appendTarget: appendTarget, appendIssue: { issues.append($0) })
      }
      index = end
    }

    return GroupMentionResolution(
      targetBotIDs: targets, issues: issues, hasMentions: hasMentions,
      messageText: removing(removedRanges, from: scalars))
  }

  private struct QuotedMention {
    let name: String
    let boundID: UUID?
    let bindingRange: Range<String.Index>?
  }

  private struct ParsedQuotedMention {
    let result: Result<QuotedMention, GroupMentionIssue>
    let endIndex: String.Index
  }

  private static func parseQuotedMention(
    in scalars: String.UnicodeScalarView,
    quoteIndex: String.Index
  ) -> ParsedQuotedMention {
    var cursor = scalars.index(after: quoteIndex)
    var escaped = false
    var closingQuote: String.Index?

    while cursor < scalars.endIndex {
      let scalar = scalars[cursor]
      if scalar == "\"", !escaped {
        closingQuote = cursor
        break
      }
      if scalar == "\\" {
        escaped.toggle()
      } else {
        escaped = false
      }
      cursor = scalars.index(after: cursor)
    }

    guard let closingQuote else {
      return ParsedQuotedMention(result: .failure(.invalidQuotedName), endIndex: cursor)
    }
    let afterQuote = scalars.index(after: closingQuote)
    let encoded = String(scalars[quoteIndex...closingQuote])
    guard
      let data = encoded.data(using: .utf8),
      let name = try? JSONDecoder().decode(String.self, from: data)
    else {
      return ParsedQuotedMention(result: .failure(.invalidQuotedName), endIndex: afterQuote)
    }

    if afterQuote < scalars.endIndex, scalars[afterQuote] == "{" {
      var closeBrace = afterQuote
      for _ in 0..<37 where closeBrace < scalars.endIndex {
        closeBrace = scalars.index(after: closeBrace)
      }
      guard closeBrace < scalars.endIndex, scalars[closeBrace] == "}" else {
        return ParsedQuotedMention(result: .failure(.invalidBinding), endIndex: closeBrace)
      }
      let idStart = scalars.index(after: afterQuote)
      let rawID = String(scalars[idStart..<closeBrace])
      let end = scalars.index(after: closeBrace)
      guard
        rawID.count == 36,
        let id = UUID(uuidString: rawID),
        rawID.lowercased() == id.uuidString.lowercased(),
        isTokenTailBoundary(in: scalars, at: end)
      else {
        return ParsedQuotedMention(result: .failure(.invalidBinding), endIndex: end)
      }
      return ParsedQuotedMention(
        result: .success(
          QuotedMention(name: name, boundID: id, bindingRange: afterQuote..<end)),
        endIndex: end)
    }

    guard isTokenTailBoundary(in: scalars, at: afterQuote) else {
      return ParsedQuotedMention(result: .failure(.invalidQuotedName), endIndex: afterQuote)
    }
    return ParsedQuotedMention(
      result: .success(QuotedMention(name: name, boundID: nil, bindingRange: nil)),
      endIndex: afterQuote)
  }

  private static func resolveUnbound(
    _ normalizedName: String,
    membersByName: [String: [GroupMentionMember]],
    appendTarget: (UUID) -> Void,
    appendIssue: (GroupMentionIssue) -> Void
  ) {
    guard let matches = membersByName[normalizedName], !matches.isEmpty else {
      appendIssue(.unknownMember)
      return
    }
    let uniqueIDs = Set(matches.map(\.id))
    guard uniqueIDs.count == 1, let id = uniqueIDs.first else {
      appendIssue(.ambiguousMember)
      return
    }
    appendTarget(id)
  }

  private static func normalize(_ value: String) -> String {
    value.precomposedStringWithCanonicalMapping
  }

  private static func removing(
    _ ranges: [Range<String.Index>], from scalars: String.UnicodeScalarView
  ) -> String {
    guard !ranges.isEmpty else { return String(scalars) }
    var result = ""
    result.reserveCapacity(scalars.count)
    var cursor = scalars.startIndex
    for range in ranges {
      guard range.lowerBound >= cursor else { continue }
      result.append(contentsOf: String(scalars[cursor..<range.lowerBound]))
      cursor = range.upperBound
    }
    result.append(contentsOf: String(scalars[cursor...]))
    return result
  }

  private static func isValidName(_ name: String) -> Bool {
    let count = name.count
    return (1...maximumNameLength).contains(count)
  }

  private static func isSimpleNameStart(_ scalar: Unicode.Scalar) -> Bool {
    scalar == "_" || scalar == "-"
      || (!isCombiningMark(scalar)
        && (scalar.properties.isAlphabetic || scalar.properties.numericType != nil))
  }

  private static func isSimpleNameContinuation(_ scalar: Unicode.Scalar) -> Bool {
    isSimpleNameStart(scalar) || isCombiningMark(scalar)
  }

  private static func isCombiningMark(_ scalar: Unicode.Scalar) -> Bool {
    scalar.properties.generalCategory == .nonspacingMark
      || scalar.properties.generalCategory == .spacingMark
      || scalar.properties.generalCategory == .enclosingMark
  }

  private static func precedingBackslashRun(
    in scalars: String.UnicodeScalarView,
    before index: String.Index
  ) -> (start: String.Index, count: Int) {
    var start = index
    var count = 0
    while start > scalars.startIndex {
      let previous = scalars.index(before: start)
      guard scalars[previous] == "\\" else { break }
      start = previous
      count += 1
    }
    return (start, count)
  }

  private static func isMentionBoundary(
    in scalars: String.UnicodeScalarView, before index: String.Index
  ) -> Bool {
    guard index > scalars.startIndex else { return true }
    let previous = scalars[scalars.index(before: index)]
    return previous.properties.isWhitespace || openingBoundaries.contains(previous)
  }

  private static func isTokenTailBoundary(
    in scalars: String.UnicodeScalarView, at index: String.Index
  ) -> Bool {
    guard index < scalars.endIndex else { return true }
    let next = scalars[index]
    return next.properties.isWhitespace
      || !isSimpleNameContinuation(next) && next != "{" && next != "\""
  }

  private static func urlSpanEnd(
    in scalars: String.UnicodeScalarView, from index: String.Index
  ) -> String.Index? {
    let boundedPrefix = String(scalars[index...].prefix(8)).lowercased()
    guard
      ["https://", "http://", "mailto:", "www."].contains(where: {
        boundedPrefix.hasPrefix($0)
      })
    else { return nil }
    var end = index
    while end < scalars.endIndex {
      let scalar = scalars[end]
      if scalar.properties.isWhitespace || scalar == "<" || scalar == ">" || scalar == "\""
        || scalar == "'"
      {
        break
      }
      end = scalars.index(after: end)
    }
    return end
  }

  private struct CodeRun {
    let start: String.Index
    let end: String.Index
    let length: Int
    let marker: Unicode.Scalar
    let isFence: Bool
  }

  private struct CodeScan {
    let inlineEnds: [String.Index: String.Index]
    let runs: [String.Index: CodeRun]
  }

  private static func codeScan(in scalars: String.UnicodeScalarView) -> CodeScan {
    var runs: [CodeRun] = []
    var index = scalars.startIndex
    while index < scalars.endIndex {
      let marker = scalars[index]
      guard marker == "`" || marker == "~" else {
        index = scalars.index(after: index)
        continue
      }
      var end = index
      var length = 0
      while end < scalars.endIndex, scalars[end] == marker {
        length += 1
        end = scalars.index(after: end)
      }
      let isFence = length >= 3 && isFenceLineBoundary(in: scalars, at: index)
      runs.append(
        CodeRun(start: index, end: end, length: length, marker: marker, isFence: isFence))
      index = end
    }

    var inlineEnds: [String.Index: String.Index] = [:]
    var nextInline: [Int: CodeRun] = [:]
    // A fence is a barrier: an unmatched inline opener cannot pair with text
    // inside it. The boundary run itself may close an equal-length inline span.
    // Release capacity on reset so many tiny regions do not repeatedly clear
    // one earlier region's large allocation.
    for run in runs.reversed() {
      if run.isFence { nextInline.removeAll() }
      if run.marker == "`" {
        if let next = nextInline[run.length] { inlineEnds[run.start] = next.end }
        nextInline[run.length] = run
      }
    }
    return CodeScan(
      inlineEnds: inlineEnds, runs: Dictionary(uniqueKeysWithValues: runs.map { ($0.start, $0) }))
  }

  private static func fenceEnd(
    after opening: CodeRun, in scalars: String.UnicodeScalarView,
    runs: [String.Index: CodeRun]
  ) -> String.Index {
    var index = opening.end
    while index < scalars.endIndex {
      if let run = runs[index] {
        if run.isFence, run.marker == opening.marker, run.length >= opening.length,
          isClosingFenceTail(in: scalars, after: run.end)
        {
          return run.end
        }
        index = run.end
      } else {
        index = scalars.index(after: index)
      }
    }
    // The caller skips the entire consumed region. Unlike repeatedly searching
    // ahead from unmatched inline runs, this visits each fenced scalar once.
    return scalars.endIndex
  }

  private static func isClosingFenceTail(
    in scalars: String.UnicodeScalarView, after end: String.Index
  ) -> Bool {
    var index = end
    while index < scalars.endIndex {
      let scalar = scalars[index]
      if scalar == "\n" || scalar == "\r" { return true }
      guard scalar == " " || scalar == "\t" else { return false }
      index = scalars.index(after: index)
    }
    return true
  }

  private static func isFenceLineBoundary(
    in scalars: String.UnicodeScalarView, at index: String.Index
  ) -> Bool {
    var cursor = index
    var spaces = 0
    while cursor > scalars.startIndex {
      let previous = scalars.index(before: cursor)
      if scalars[previous] == "\n" || scalars[previous] == "\r" { return true }
      guard scalars[previous] == " ", spaces < 3 else { return false }
      spaces += 1
      cursor = previous
    }
    return true
  }

  private static func isLexicalEmail(
    in scalars: String.UnicodeScalarView, at atIndex: String.Index
  ) -> Bool {
    guard atIndex > scalars.startIndex else { return false }
    let previous = scalars[scalars.index(before: atIndex)]
    let hasLocalPart: Bool
    if previous == "\"" {
      var cursor = scalars.index(before: atIndex)
      guard precedingBackslashRun(in: scalars, before: cursor).count.isMultiple(of: 2) else {
        return false
      }
      var foundOpeningQuote = false
      while cursor > scalars.startIndex {
        cursor = scalars.index(before: cursor)
        let scalar = scalars[cursor]
        if scalar == "\n" || scalar == "\r" { break }
        if scalar == "\"",
          precedingBackslashRun(in: scalars, before: cursor).count.isMultiple(of: 2)
        {
          foundOpeningQuote = true
          break
        }
      }
      hasLocalPart = foundOpeningQuote
    } else {
      hasLocalPart = isEmailAtom(previous)
    }
    guard hasLocalPart else { return false }

    var cursor = scalars.index(after: atIndex)
    var labelHasContent = false
    var sawDot = false
    var finalLabelHasContent = false
    while cursor < scalars.endIndex {
      let scalar = scalars[cursor]
      if scalar == "." {
        guard labelHasContent else { break }
        sawDot = true
        finalLabelHasContent = false
      } else if scalar == "-" || scalar.properties.isAlphabetic
        || scalar.properties.numericType != nil
      {
        labelHasContent = true
        if sawDot { finalLabelHasContent = true }
      } else {
        break
      }
      cursor = scalars.index(after: cursor)
    }
    return sawDot && finalLabelHasContent
  }

  private static func isEmailAtom(_ scalar: Unicode.Scalar) -> Bool {
    if scalar.properties.isAlphabetic || scalar.properties.numericType != nil { return true }
    return "!#$%&'*+-/=?^_`{|}~.".unicodeScalars.contains(scalar)
  }
}
