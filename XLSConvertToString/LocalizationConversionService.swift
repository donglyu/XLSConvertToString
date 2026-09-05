import Foundation

@objc enum LocalizationConversionErrorCode: Int {
    case invalidExcelFile = 1
    case worksheetParsingFailed = 2
    case invalidCSVFile = 3
    case invalidTranslationAttachmentDirectory = 4
    case translationAttachmentNotFound = 5
    case duplicateTranslationAttachment = 6
}

enum CSVTableReaderError: LocalizedError {
    case malformedCSV
    case unreadableFile

    var errorDescription: String? {
        switch self {
        case .malformedCSV:
            return "The CSV file is malformed: a quoted field is not terminated correctly."
        case .unreadableFile:
            return "Unable to read the CSV file as UTF-8 text."
        }
    }
}

/// Parses RFC 4180-style CSV while preserving quoted commas, newlines, and escaped quotes.
struct CSVTableReader {
    func read(from path: String) throws -> [[String]] {
        guard var text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw CSVTableReaderError.unreadableFile
        }

        if text.first == "\u{FEFF}" {
            text.removeFirst()
        }

        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var isQuoted = false
        var justClosedQuote = false
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            let nextIndex = text.index(after: index)
            let next = nextIndex < text.endIndex ? text[nextIndex] : nil

            if isQuoted {
                if character == "\"" {
                    if next == "\"" {
                        field.append("\"")
                        index = text.index(after: nextIndex)
                    } else {
                        isQuoted = false
                        justClosedQuote = true
                        index = nextIndex
                    }
                } else {
                    field.append(character)
                    index = nextIndex
                }
                continue
            }

            switch character {
            case "\"" where field.isEmpty:
                isQuoted = true
            case ",":
                row.append(field)
                field = ""
                justClosedQuote = false
            case "\n":
                row.append(field)
                rows.append(row)
                row = []
                field = ""
                justClosedQuote = false
            case "\r\n":
                row.append(field)
                rows.append(row)
                row = []
                field = ""
                justClosedQuote = false
            case "\r":
                row.append(field)
                rows.append(row)
                row = []
                field = ""
                justClosedQuote = false
            default:
                if justClosedQuote {
                    throw CSVTableReaderError.malformedCSV
                }
                field.append(character)
            }
            index = nextIndex
        }

        guard !isQuoted else {
            throw CSVTableReaderError.malformedCSV
        }

        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}

@objcMembers
final class LocalizationConversionService: NSObject {
    /// Copies `*.lproj/Localizable.strings` from a translation platform export into a project.
    /// Files are intentionally replaced as-is; no merge, backup, or source-file archival is performed.
    func importTranslationAttachments(
        attachmentDirectory: String,
        projectLocalizationDirectory: String
    ) throws -> Int {
        let fileManager = FileManager.default
        var isAttachmentDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: attachmentDirectory, isDirectory: &isAttachmentDirectory),
              isAttachmentDirectory.boolValue else {
            throw conversionError(
                code: .invalidTranslationAttachmentDirectory,
                description: "The translation attachments path is not a directory: \(attachmentDirectory)"
            )
        }

        var isProjectDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: projectLocalizationDirectory, isDirectory: &isProjectDirectory),
              isProjectDirectory.boolValue else {
            throw conversionError(
                code: .invalidTranslationAttachmentDirectory,
                description: "The project localization path is not a directory: \(projectLocalizationDirectory)"
            )
        }

        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: attachmentDirectory),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw conversionError(
                code: .invalidTranslationAttachmentDirectory,
                description: "Unable to scan translation attachments directory: \(attachmentDirectory)"
            )
        }

        var sourceFilesByLanguageDirectory: [String: URL] = [:]
        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent == "Localizable.strings",
                  fileURL.deletingLastPathComponent().pathExtension == "lproj" else {
                continue
            }

            let languageDirectory = fileURL.deletingLastPathComponent().lastPathComponent
            guard sourceFilesByLanguageDirectory[languageDirectory] == nil else {
                throw conversionError(
                    code: .duplicateTranslationAttachment,
                    description: "Multiple translation attachments were found for \(languageDirectory)/Localizable.strings."
                )
            }
            sourceFilesByLanguageDirectory[languageDirectory] = fileURL
        }

        guard !sourceFilesByLanguageDirectory.isEmpty else {
            throw conversionError(
                code: .translationAttachmentNotFound,
                description: "No *.lproj/Localizable.strings files were found in the translation attachments directory."
            )
        }

        let projectURL = URL(fileURLWithPath: projectLocalizationDirectory)
        for languageDirectory in sourceFilesByLanguageDirectory.keys.sorted() {
            guard let sourceURL = sourceFilesByLanguageDirectory[languageDirectory] else { continue }
            let destinationDirectory = projectURL.appendingPathComponent(languageDirectory, isDirectory: true)
            let destinationURL = destinationDirectory.appendingPathComponent("Localizable.strings")

            do {
                try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
                let sourceData = try Data(contentsOf: sourceURL)
                try sourceData.write(to: destinationURL, options: .atomic)
            } catch {
                throw NSError(
                    domain: "LocalizationConversionService",
                    code: error._code,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Failed to replace \(languageDirectory)/Localizable.strings: \(error.localizedDescription)",
                        NSUnderlyingErrorKey: error
                    ]
                )
            }
        }

        return sourceFilesByLanguageDirectory.count
    }

    func convert(
        excelPath: String,
        stringOutputDirectory: String?,
        projectLocalizationDirectory: String?,
        languageKeys: [String]
    ) throws {
        if URL(fileURLWithPath: excelPath).pathExtension.caseInsensitiveCompare("csv") == .orderedSame {
            try convertCSV(
                csvPath: excelPath,
                stringOutputDirectory: stringOutputDirectory,
                projectLocalizationDirectory: projectLocalizationDirectory,
                languageKeys: languageKeys
            )
            return
        }

        var openError = LIBXLS_OK

        guard let workbook = xls_open_file(excelPath, "UTF-8", &openError) else {
            throw conversionError(
                code: .invalidExcelFile,
                description: "Failed to open XLS file: \(String(cString: xls_getError(openError)))."
            )
        }
        defer { xls_close_WB(workbook) }

        guard let worksheet = xls_getWorkSheet(workbook, 0) else {
            throw conversionError(
                code: .invalidExcelFile,
                description: "The XLS file does not contain a readable worksheet."
            )
        }
        defer { xls_close_WS(worksheet) }

        let parseError = xls_parseWorkSheet(worksheet)
        guard parseError == LIBXLS_OK else {
            throw conversionError(
                code: .worksheetParsingFailed,
                description: "Failed to parse worksheet: \(String(cString: xls_getError(parseError)))."
            )
        }

        let rowCount = Int(worksheet.pointee.rows.lastrow) + 1
        let cellCount = Int(worksheet.pointee.rows.lastcol) + 1
        var localizedStrings: [NSMutableString] = []

        for rowIndex in 0..<rowCount {
            guard let key = stringValue(in: worksheet, row: rowIndex, column: 0),
                  !key.isEmpty else {
                continue
            }

            for columnIndex in 2..<cellCount {
                if columnIndex - 1 > localizedStrings.count {
                    localizedStrings.append(NSMutableString())
                }

                guard let rawValue = stringValue(in: worksheet, row: rowIndex, column: columnIndex),
                      !rawValue.isEmpty else {
                    continue
                }

                let sanitizedValue = sanitize(rawValue)
                localizedStrings[columnIndex - 2].append("\n\"\(key)\" = ")
                localizedStrings[columnIndex - 2].append("\"\(sanitizedValue)\";")
            }
        }

        try writeLocalizedStrings(
            localizedStrings,
            stringOutputDirectory: stringOutputDirectory,
            projectLocalizationDirectory: projectLocalizationDirectory,
            languageKeys: languageKeys
        )
    }

    private func writeLocalizedStrings(
        _ localizedStrings: [NSMutableString],
        stringOutputDirectory: String?,
        projectLocalizationDirectory: String?,
        languageKeys: [String]
    ) throws {
        for (index, content) in localizedStrings.enumerated() {
            guard index < languageKeys.count else {
                continue
            }

            guard content.length > 0 else {
                continue
            }

            let languageKey = languageKeys[index]

            if let stringOutputDirectory, !stringOutputDirectory.isEmpty {
                let filePath = (stringOutputDirectory as NSString).appendingPathComponent("\(languageKey).strings")
                try write(content: content as String, to: filePath)
            }

            if let projectLocalizationDirectory, !projectLocalizationDirectory.isEmpty {
                let languageDirectory = (projectLocalizationDirectory as NSString).appendingPathComponent("\(languageKey).lproj")
                let filePath = (languageDirectory as NSString).appendingPathComponent("Localizable.strings")
                try write(content: content as String, to: filePath)
            }
        }
    }

    private func convertCSV(
        csvPath: String,
        stringOutputDirectory: String?,
        projectLocalizationDirectory: String?,
        languageKeys: [String]
    ) throws {
        let rows: [[String]]
        do {
            rows = try CSVTableReader().read(from: csvPath)
        } catch {
            throw conversionError(code: .invalidCSVFile, description: error.localizedDescription)
        }

        var localizedStrings: [NSMutableString] = []
        for row in rows {
            guard let key = row[safe: 0], !key.isEmpty else { continue }

            for columnIndex in 2..<row.count {
                if columnIndex - 1 > localizedStrings.count {
                    localizedStrings.append(NSMutableString())
                }
                guard !row[columnIndex].isEmpty else { continue }

                let sanitizedValue = sanitize(row[columnIndex])
                localizedStrings[columnIndex - 2].append("\n\"\(key)\" = ")
                localizedStrings[columnIndex - 2].append("\"\(sanitizedValue)\";")
            }
        }

        try writeLocalizedStrings(
            localizedStrings,
            stringOutputDirectory: stringOutputDirectory,
            projectLocalizationDirectory: projectLocalizationDirectory,
            languageKeys: languageKeys
        )
    }

    private func write(content: String, to path: String) throws {
        guard let data = (content as NSString).data(using: String.Encoding.utf8.rawValue) else {
            throw NSError(
                domain: "LocalizationConversionService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode file content as UTF-8."]
            )
        }

        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            throw NSError(
                domain: "LocalizationConversionService",
                code: error._code,
                userInfo: [
                    NSLocalizedDescriptionKey: "Failed to write file: \(path)",
                    NSUnderlyingErrorKey: error
                ]
            )
        }
    }

    private func stringValue(in worksheet: UnsafeMutablePointer<xlsWorkSheet>, row: Int, column: Int) -> String? {
        guard row >= 0, column >= 0 else {
            return nil
        }

        guard let cellPointer = xls_cell(worksheet, WORD(row), WORD(column)) else {
            return nil
        }

        let cell = cellPointer.pointee

        if let value = cell.str {
            let string = String(cString: value)
            if !string.isEmpty {
                return string
            }
        }

        switch cell.id {
        case WORD(XLS_RECORD_NUMBER), WORD(XLS_RECORD_RK):
            return String(cell.d)
        case WORD(XLS_RECORD_BOOLERR):
            return cell.d == 0 ? "false" : "true"
        default:
            return nil
        }
    }

    private func sanitize(_ value: String) -> String {
        let escapedValue: NSString
        if value.contains("\"") {
            escapedValue = value.replacingOccurrences(of: "\"", with: "\\\"") as NSString
        } else {
            escapedValue = value as NSString
        }

        let trimmedWhitespace = escapedValue.trimmingCharacters(in: .whitespaces) as NSString
        return trimmedWhitespace.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func conversionError(code: LocalizationConversionErrorCode, description: String) -> NSError {
        NSError(
            domain: "LocalizationConversionService",
            code: code.rawValue,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
