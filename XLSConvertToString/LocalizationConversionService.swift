import Foundation

@objc enum LocalizationConversionErrorCode: Int {
    case invalidExcelFile = 1
    case worksheetParsingFailed = 2
}

@objcMembers
final class LocalizationConversionService: NSObject {
    func convert(
        excelPath: String,
        stringOutputDirectory: String?,
        projectLocalizationDirectory: String?,
        languageKeys: [String]
    ) throws {
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
