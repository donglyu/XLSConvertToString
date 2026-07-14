import Foundation

struct UnusedLocalizationKeysResult {
    let status: String
    let resultText: String
}

enum UnusedLocalizationKeysError: LocalizedError {
    case invalidXLS
    case invalidCSV
    case noKeysFound

    var errorDescription: String? {
        switch self {
        case .invalidXLS:
            return "Unable to read the XLS file."
        case .invalidCSV:
            return "Unable to read the CSV file."
        case .noKeysFound:
            return "No keys were found in the XLS file."
        }
    }
}

final class UnusedLocalizationKeysService {
    func findUnusedKeys(
        projectPath: String,
        xlsPath: String,
        ignoreComments: Bool,
        progress: @escaping @Sendable (_ scannedCount: Int, _ totalCount: Int, _ remainingCount: Int) -> Void
    ) throws -> UnusedLocalizationKeysResult {
        if URL(fileURLWithPath: xlsPath).pathExtension.caseInsensitiveCompare("csv") == .orderedSame {
            return try findUnusedKeysInCSV(
                projectPath: projectPath,
                csvPath: xlsPath,
                ignoreComments: ignoreComments,
                progress: progress
            )
        }

        var openError = LIBXLS_OK

        guard let workbook = xls_open_file(xlsPath, "UTF-8", &openError) else {
            throw UnusedLocalizationKeysError.invalidXLS
        }
        defer { xls_close_WB(workbook) }

        guard let worksheet = xls_getWorkSheet(workbook, 0) else {
            throw UnusedLocalizationKeysError.invalidXLS
        }
        defer { xls_close_WS(worksheet) }

        guard xls_parseWorkSheet(worksheet) == LIBXLS_OK else {
            throw UnusedLocalizationKeysError.invalidXLS
        }

        var allKeys = OrderedSet<String>()
        let rowCount = Int(worksheet.pointee.rows.lastrow) + 1
        for rowIndex in 1..<rowCount {
            guard let key = stringValue(in: worksheet, row: rowIndex, column: 0),
                  !key.isEmpty else {
                continue
            }

            allKeys.append(key)
        }

        guard !allKeys.isEmpty else {
            throw UnusedLocalizationKeysError.noKeysFound
        }

        return scan(
            projectPath: projectPath,
            allKeys: allKeys,
            ignoreComments: ignoreComments,
            progress: progress
        )
    }

    private func scan(
        projectPath: String,
        allKeys: OrderedSet<String>,
        ignoreComments: Bool,
        progress: @escaping @Sendable (_ scannedCount: Int, _ totalCount: Int, _ remainingCount: Int) -> Void
    ) -> UnusedLocalizationKeysResult {
        let candidateFiles = candidateSourceFiles(at: projectPath)
        var remainingKeys = allKeys
        var scannedCount = 0

        for relativePath in candidateFiles {
            autoreleasepool {
                let fullPath = (projectPath as NSString).appendingPathComponent(relativePath)
                let content = try? String(contentsOfFile: fullPath, encoding: .utf8)
                scannedCount += 1

                guard let content, !content.isEmpty else {
                    if scannedCount == 1 || scannedCount % 20 == 0 {
                        progress(scannedCount, candidateFiles.count, remainingKeys.count)
                    }
                    return
                }

                let searchContent = ignoreComments ? removingComments(from: content) : content
                for key in remainingKeys.elements {
                    if searchContent.contains("\"\(key)\"") {
                        remainingKeys.remove(key)
                    }
                }

                if scannedCount == 1 || scannedCount % 20 == 0 || scannedCount == candidateFiles.count {
                    progress(scannedCount, candidateFiles.count, remainingKeys.count)
                }
            }
        }

        if remainingKeys.isEmpty {
            return UnusedLocalizationKeysResult(
                status: "Completed",
                resultText: "No unused keys found."
            )
        }

        let body = remainingKeys.elements.joined(separator: "\n")
        return UnusedLocalizationKeysResult(
            status: "Completed",
            resultText: "Found \(remainingKeys.count) unused keys:\n\n\(body)\n"
        )
    }

    private func findUnusedKeysInCSV(
        projectPath: String,
        csvPath: String,
        ignoreComments: Bool,
        progress: @escaping @Sendable (_ scannedCount: Int, _ totalCount: Int, _ remainingCount: Int) -> Void
    ) throws -> UnusedLocalizationKeysResult {
        let rows: [[String]]
        do {
            rows = try CSVTableReader().read(from: csvPath)
        } catch {
            throw UnusedLocalizationKeysError.invalidCSV
        }

        var allKeys = OrderedSet<String>()
        for row in rows.dropFirst() {
            guard let key = row.first, !key.isEmpty else { continue }
            allKeys.append(key)
        }
        guard !allKeys.isEmpty else { throw UnusedLocalizationKeysError.noKeysFound }

        return scan(
            projectPath: projectPath,
            allKeys: allKeys,
            ignoreComments: ignoreComments,
            progress: progress
        )
    }

    private func candidateSourceFiles(at projectPath: String) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: projectPath) else {
            return []
        }

        var files: [String] = []
        for case let file as String in enumerator {
            let ext = URL(fileURLWithPath: file).pathExtension.lowercased()
            if ext == "m" || ext == "h" || ext == "swift" {
                files.append(file)
            }
        }
        return files
    }

    private func stringValue(in worksheet: UnsafeMutablePointer<xlsWorkSheet>, row: Int, column: Int) -> String? {
        guard let cellPointer = xls_cell(worksheet, WORD(row), WORD(column)) else {
            return nil
        }

        guard let rawValue = cellPointer.pointee.str else {
            return nil
        }

        let value = String(cString: rawValue)
        return value.isEmpty ? nil : value
    }

    private func removingComments(from source: String) -> String {
        guard !source.isEmpty else { return source }

        var result = String()
        result.reserveCapacity(source.count)

        var index = source.startIndex
        var inLineComment = false
        var inBlockComment = false
        var inString = false
        var stringDelimiter: Character?
        var isEscaped = false

        while index < source.endIndex {
            let current = source[index]
            let nextIndex = source.index(after: index)
            let next = nextIndex < source.endIndex ? source[nextIndex] : nil

            if inLineComment {
                if current == "\n" {
                    inLineComment = false
                    result.append(current)
                }
                index = nextIndex
                continue
            }

            if inBlockComment {
                if current == "*", next == "/" {
                    inBlockComment = false
                    index = source.index(after: nextIndex)
                } else {
                    index = nextIndex
                }
                continue
            }

            if inString {
                result.append(current)
                if isEscaped {
                    isEscaped = false
                    index = nextIndex
                    continue
                }
                if current == "\\" {
                    isEscaped = true
                    index = nextIndex
                    continue
                }
                if current == stringDelimiter {
                    inString = false
                    stringDelimiter = nil
                }
                index = nextIndex
                continue
            }

            if current == "\"" || current == "'" {
                inString = true
                stringDelimiter = current
                result.append(current)
                index = nextIndex
                continue
            }

            if current == "/", next == "/" {
                inLineComment = true
                index = source.index(after: nextIndex)
                continue
            }

            if current == "/", next == "*" {
                inBlockComment = true
                index = source.index(after: nextIndex)
                continue
            }

            result.append(current)
            index = nextIndex
        }

        return result
    }
}

private struct OrderedSet<Element: Hashable> {
    private(set) var elements: [Element] = []
    private var lookup: Set<Element> = []

    init() {}

    init(_ elements: [Element]) {
        for element in elements {
            append(element)
        }
    }

    var isEmpty: Bool { elements.isEmpty }
    var count: Int { elements.count }

    mutating func append(_ element: Element) {
        guard lookup.insert(element).inserted else { return }
        elements.append(element)
    }

    mutating func remove(_ element: Element) {
        guard lookup.remove(element) != nil else { return }
        elements.removeAll { $0 == element }
    }
}
