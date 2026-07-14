import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum PreferenceKeys {
    static let excelPath = "excelPathStoreKey"
    static let stringPath = "stringPathStoreKey"
    static let projectPath = "projectResourceKey"
    static let languageKeys = "langKeysKey"
    static let unusedProjectPath = "kUnuseProjectPathKey"
    static let unusedXLSPath = "kUnuseXLSPathKey"
}

private let supportedSpreadsheetTypes: [UTType] = [
    .spreadsheet,
    UTType(filenameExtension: "csv")!
]

private struct AlertMessage: Identifiable {
    let id = UUID()
    let text: String
}

struct MainContentView: View {
    @AppStorage(PreferenceKeys.excelPath) private var excelPath = ""
    @AppStorage(PreferenceKeys.stringPath) private var stringPath = ""
    @AppStorage(PreferenceKeys.projectPath) private var projectPath = ""
    @AppStorage(PreferenceKeys.languageKeys) private var languageKeysText = ""

    @State private var alertMessage: AlertMessage?
    @State private var isShowingUnusedKeysSheet = false
    @State private var conversionStatusMessage = ""

    private let conversionService = LocalizationConversionService()
    private let defaultLanguageKeys = "en,es,de,fr,tr,it,pt-BR"
    private let statusTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
    private let archiveTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Export Spreadsheet to .strings")
                .font(.system(size: 22, weight: .bold))

            pathSection(
                title: "Spreadsheet File (.xls or .csv):",
                value: excelPath,
                selectAction: selectExcelFile,
                revealAction: openExcelLocation,
                errorMessage: inputFileIsMissing ? "File not found" : nil
            )

            pathSection(
                title: "Optional 1: Export .strings Files To:",
                value: stringPath,
                selectAction: selectStringOutputDirectory,
                revealAction: openStringOutputLocation
            )

            pathSection(
                title: "Optional 2: Replace Project Localization Files Directly:",
                value: projectPath,
                selectAction: selectProjectLocalizationDirectory,
                revealAction: openProjectLocalizationLocation
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("Other Settings")
                    .font(.system(size: 11, weight: .light))
                    .foregroundStyle(.secondary)

                Text("Language Keys (comma separated):")
                    .font(.system(size: 11, weight: .light))
                    .foregroundStyle(.secondary)

                TextField("en,es,de,fr,tr,it,pt-BR", text: $languageKeysText)
                    .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 12) {
                Button("Convert", action: convert)
                    .keyboardShortcut(.defaultAction)

                Button("Find Unused Keys in Project") {
                    isShowingUnusedKeysSheet = true
                }
            }

            if !conversionStatusMessage.isEmpty {
                Text(conversionStatusMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green)
            }
        }
        .padding(32)
        .frame(minWidth: 680, minHeight: 460, alignment: .topLeading)
        .background(WindowConfigurationView())
        .sheet(isPresented: $isShowingUnusedKeysSheet) {
            UnusedKeysSheet()
        }
        .alert(item: $alertMessage) { item in
            Alert(title: Text("System"), message: Text(item.text))
        }
        .onAppear {
            if languageKeysText.isEmpty {
                languageKeysText = defaultLanguageKeys
            }
        }
    }

    @ViewBuilder
    private func pathSection(
        title: String,
        value: String,
        selectAction: @escaping () -> Void,
        revealAction: @escaping () -> Void,
        errorMessage: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.red)
                }
            }

            HStack(spacing: 8) {
                TextField("", text: .constant(value))
                    .textFieldStyle(.roundedBorder)
                    .disabled(true)

                Button("Select", action: selectAction)
                Button("Open", action: revealAction)
                    .disabled(value.isEmpty)
            }
        }
    }

    private func convert() {
        conversionStatusMessage = ""

        guard !excelPath.isEmpty else {
            showAlert("Please select an XLS or CSV file.")
            return
        }

        guard !inputFileIsMissing else {
            return
        }

        guard !stringPath.isEmpty || !projectPath.isEmpty else {
            showAlert("Select at least one export path or project localization path.")
            return
        }

        let languageKeys = parsedLanguageKeys()
        guard !languageKeys.isEmpty else {
            showAlert("Specify the language keys in the spreadsheet (e.g. en,es,de).")
            return
        }

        do {
            try conversionService.convert(
                excelPath: excelPath,
                stringOutputDirectory: stringPath.isEmpty ? nil : stringPath,
                projectLocalizationDirectory: projectPath.isEmpty ? nil : projectPath,
                languageKeys: languageKeys
            )
            let completionDate = Date()
            let archivedPath = try archiveInputFile(completedAt: completionDate)
            let completedAt = statusTimeFormatter.string(from: completionDate)
            conversionStatusMessage = "Convert completed at \(completedAt). Input archived as \(URL(fileURLWithPath: archivedPath).lastPathComponent)."
        } catch {
            showAlert(error.localizedDescription)
        }
    }

    private func archiveInputFile(completedAt date: Date) throws -> String {
        let inputURL = URL(fileURLWithPath: excelPath)
        let filename = inputURL.deletingPathExtension().lastPathComponent
        let fileExtension = inputURL.pathExtension
        let timestamp = archiveTimeFormatter.string(from: date)
        let directoryURL = inputURL.deletingLastPathComponent()
        var archivedURL = directoryURL.appendingPathComponent("\(filename)_\(timestamp)")
        if !fileExtension.isEmpty {
            archivedURL.appendPathExtension(fileExtension)
        }

        var duplicateIndex = 2
        while FileManager.default.fileExists(atPath: archivedURL.path) {
            archivedURL = directoryURL.appendingPathComponent("\(filename)_\(timestamp)_\(duplicateIndex)")
            if !fileExtension.isEmpty {
                archivedURL.appendPathExtension(fileExtension)
            }
            duplicateIndex += 1
        }

        do {
            try FileManager.default.moveItem(at: inputURL, to: archivedURL)
            return archivedURL.path
        } catch {
            throw NSError(
                domain: "XLSConvertToString",
                code: error._code,
                userInfo: [
                    NSLocalizedDescriptionKey: "Conversion completed, but the input file could not be archived: \(error.localizedDescription)",
                    NSUnderlyingErrorKey: error
                ]
            )
        }
    }

    private func parsedLanguageKeys() -> [String] {
        languageKeysText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var inputFileIsMissing: Bool {
        !excelPath.isEmpty && !FileManager.default.fileExists(atPath: excelPath)
    }

    private func selectExcelFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = supportedSpreadsheetTypes

        if panel.runModal() == .OK {
            excelPath = panel.url?.path ?? ""
        }
    }

    private func selectStringOutputDirectory() {
        if let path = selectDirectory() {
            stringPath = path
        }
    }

    private func selectProjectLocalizationDirectory() {
        if let path = selectDirectory() {
            projectPath = path
        }
    }

    private func selectDirectory() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private func openExcelLocation() {
        guard !excelPath.isEmpty else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: excelPath)
    }

    private func openStringOutputLocation() {
        guard !stringPath.isEmpty else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: stringPath)
    }

    private func openProjectLocalizationLocation() {
        guard !projectPath.isEmpty else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: projectPath)
    }

    private func showAlert(_ text: String) {
        alertMessage = AlertMessage(text: text)
    }
}

struct WindowConfigurationView: NSViewRepresentable {
    final class Coordinator {
        var hasClearedInitialFocus = false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configureWindow(for: view, coordinator: context.coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configureWindow(for: nsView, coordinator: context.coordinator)
        }
    }

    private func configureWindow(for view: NSView, coordinator: Coordinator) {
        guard let window = view.window else { return }

        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        window.title = "iOS/MAC App Localization Tool - Version \(version) (Build \(build))"

        if !coordinator.hasClearedInitialFocus {
            window.makeFirstResponder(nil)
            coordinator.hasClearedInitialFocus = true
        }
    }
}

struct UnusedKeysSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PreferenceKeys.unusedProjectPath) private var projectPath = ""
    @AppStorage(PreferenceKeys.unusedXLSPath) private var xlsPath = ""

    @State private var ignoreComments = false
    @State private var isSearching = false
    @State private var status = "Idle"
    @State private var resultText = "Results will be shown here..."
    @State private var alertMessage: AlertMessage?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Find Unused Localization Keys")
                .font(.system(size: 20, weight: .bold))

            pathSection(
                title: "Project Path:",
                value: projectPath,
                selectAction: selectProjectPath,
                revealAction: openProjectPath
            )

            pathSection(
                title: "Spreadsheet File (.xls or .csv):",
                value: xlsPath,
                selectAction: selectXLSPath,
                revealAction: openXLSPath
            )

            Toggle("Ignore Comments", isOn: $ignoreComments)
                .disabled(isSearching)

            HStack(spacing: 12) {
                Button(isSearching ? "Searching..." : "Start Search", action: startSearch)
                    .disabled(isSearching)

                Text(status)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                Button("Close") {
                    dismiss()
                }
            }

            ScrollView {
                Text(resultText)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 460, alignment: .topLeading)
        .alert(item: $alertMessage) { item in
            Alert(title: Text("Notice"), message: Text(item.text))
        }
    }

    @ViewBuilder
    private func pathSection(
        title: String,
        value: String,
        selectAction: @escaping () -> Void,
        revealAction: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)

            HStack(spacing: 8) {
                TextField("", text: .constant(value))
                    .textFieldStyle(.roundedBorder)
                    .disabled(true)

                Button("Select", action: selectAction)
                    .disabled(isSearching)

                Button("Open", action: revealAction)
                    .disabled(value.isEmpty)
            }
        }
    }

    private func startSearch() {
        guard !projectPath.isEmpty else {
            showAlert("Please select a project path first.")
            return
        }
        guard !xlsPath.isEmpty else {
            showAlert("Please select an XLS or CSV file first.")
            return
        }

        isSearching = true
        status = "Loading keys..."
        resultText = "Searching for unused localization keys..."

        let selectedProjectPath = projectPath
        let selectedXLSPath = xlsPath
        let shouldIgnoreComments = ignoreComments

        Task.detached(priority: .userInitiated) {
            do {
                let service = UnusedLocalizationKeysService()
                let result = try service.findUnusedKeys(
                    projectPath: selectedProjectPath,
                    xlsPath: selectedXLSPath,
                    ignoreComments: shouldIgnoreComments
                ) { scannedCount, totalCount, remainingCount in
                    Task { @MainActor in
                        guard isSearching else { return }
                        status = "Scanning \(scannedCount)/\(totalCount) files, \(remainingCount) keys remaining"
                    }
                }

                await MainActor.run {
                    isSearching = false
                    status = result.status
                    resultText = result.resultText
                }
            } catch {
                await MainActor.run {
                    isSearching = false
                    status = "Failed"
                    showAlert(error.localizedDescription)
                }
            }
        }
    }

    private func selectProjectPath() {
        if let path = selectDirectory() {
            projectPath = path
        }
    }

    private func selectXLSPath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = supportedSpreadsheetTypes

        if panel.runModal() == .OK {
            xlsPath = panel.url?.path ?? ""
        }
    }

    private func selectDirectory() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private func openProjectPath() {
        guard !projectPath.isEmpty else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: projectPath)
    }

    private func openXLSPath() {
        guard !xlsPath.isEmpty else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: xlsPath)
    }

    private func showAlert(_ text: String) {
        alertMessage = AlertMessage(text: text)
    }
}
