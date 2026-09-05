import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum PreferenceKeys {
    static let excelPath = "excelPathStoreKey"
    static let stringPath = "stringPathStoreKey"
    static let projectPath = "projectResourceKey"
    static let translationAttachmentPath = "translationAttachmentPathStoreKey"
    static let translationProjectPath = "translationProjectPathStoreKey"
    static let languageKeys = "langKeysKey"
    static let unusedProjectPath = "kUnuseProjectPathKey"
    static let unusedXLSPath = "kUnuseXLSPathKey"
    static let conversionProfiles = "conversionProfilesStoreKey"
    static let selectedConversionProfile = "selectedConversionProfileStoreKey"
}

private struct ConversionProfile: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var excelPath: String
    var stringPath: String
    var projectPath: String
    var languageKeysText: String

    static func empty(name: String) -> ConversionProfile {
        ConversionProfile(
            id: UUID(),
            name: name,
            excelPath: "",
            stringPath: "",
            projectPath: "",
            languageKeysText: "en,es,de,fr,tr,it,pt-BR"
        )
    }
}

private final class ConversionProfileStore: ObservableObject {
    @Published private(set) var profiles: [ConversionProfile]
    @Published var selectedProfileID: UUID {
        didSet { persist() }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let loadedProfiles: [ConversionProfile]
        if let data = defaults.data(forKey: PreferenceKeys.conversionProfiles),
           let storedProfiles = try? JSONDecoder().decode([ConversionProfile].self, from: data),
           !storedProfiles.isEmpty {
            loadedProfiles = storedProfiles
        } else {
            let legacyLanguageKeys = defaults.string(forKey: PreferenceKeys.languageKeys) ?? ""
            loadedProfiles = [ConversionProfile(
                id: UUID(),
                name: "Default",
                excelPath: defaults.string(forKey: PreferenceKeys.excelPath) ?? "",
                stringPath: defaults.string(forKey: PreferenceKeys.stringPath) ?? "",
                projectPath: defaults.string(forKey: PreferenceKeys.projectPath) ?? "",
                languageKeysText: legacyLanguageKeys.isEmpty ? "en,es,de,fr,tr,it,pt-BR" : legacyLanguageKeys
            )]
        }
        profiles = loadedProfiles

        if let storedIDText = defaults.string(forKey: PreferenceKeys.selectedConversionProfile),
           let storedID = UUID(uuidString: storedIDText),
           loadedProfiles.contains(where: { $0.id == storedID }) {
            selectedProfileID = storedID
        } else {
            selectedProfileID = loadedProfiles[0].id
        }
        persist()
    }

    var selectedProfile: ConversionProfile {
        profiles.first(where: { $0.id == selectedProfileID }) ?? profiles[0]
    }

    func binding<Value>(for keyPath: WritableKeyPath<ConversionProfile, Value>) -> Binding<Value> {
        Binding(
            get: { self.selectedProfile[keyPath: keyPath] },
            set: { newValue in
                guard let index = self.profiles.firstIndex(where: { $0.id == self.selectedProfileID }) else { return }
                self.profiles[index][keyPath: keyPath] = newValue
                self.persist()
            }
        )
    }

    func addProfile() {
        let profile = ConversionProfile.empty(name: uniqueName(basedOn: "New Configuration"))
        profiles.append(profile)
        selectedProfileID = profile.id
        persist()
    }

    func duplicateSelectedProfile() {
        var profile = selectedProfile
        profile.id = UUID()
        profile.name = uniqueName(basedOn: "\(profile.name) Copy")
        profiles.append(profile)
        selectedProfileID = profile.id
        persist()
    }

    func deleteSelectedProfile() {
        guard profiles.count > 1,
              let index = profiles.firstIndex(where: { $0.id == selectedProfileID }) else { return }
        profiles.remove(at: index)
        selectedProfileID = profiles[min(index, profiles.count - 1)].id
        persist()
    }

    private func uniqueName(basedOn baseName: String) -> String {
        guard profiles.contains(where: { $0.name == baseName }) else { return baseName }
        var suffix = 2
        while profiles.contains(where: { $0.name == "\(baseName) \(suffix)" }) {
            suffix += 1
        }
        return "\(baseName) \(suffix)"
    }

    private func persist() {
        guard !profiles.isEmpty else { return }
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: PreferenceKeys.conversionProfiles)
        }
        defaults.set(selectedProfileID.uuidString, forKey: PreferenceKeys.selectedConversionProfile)
    }
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
    @StateObject private var profileStore = ConversionProfileStore()

    @State private var alertMessage: AlertMessage?
    @State private var isShowingUnusedKeysSheet = false
    @State private var isShowingAttachmentImportSheet = false
    @State private var conversionStatusMessage = ""
    @State private var shouldShowInputFileMissingError = false
    @State private var isConfirmingProfileDeletion = false

    private let conversionService = LocalizationConversionService()
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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Export Spreadsheet to .strings")
                    .font(.system(size: 22, weight: .bold))

                configurationSection

                pathSection(
                    title: "Spreadsheet File (.xls or .csv):",
                    value: profileStore.selectedProfile.excelPath,
                    selectAction: selectExcelFile,
                    revealAction: openExcelLocation,
                    errorMessage: shouldShowInputFileMissingError ? "File not found" : nil
                )

                pathSection(
                    title: "Optional 1: Export .strings Files To:",
                    value: profileStore.selectedProfile.stringPath,
                    selectAction: selectStringOutputDirectory,
                    revealAction: openStringOutputLocation
                )

                pathSection(
                    title: "Optional 2: Replace Project Localization Files Directly:",
                    value: profileStore.selectedProfile.projectPath,
                    selectAction: selectProjectLocalizationDirectory,
                    revealAction: openProjectLocalizationLocation
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text("Language Keys (comma separated):")
                        .font(.system(size: 11, weight: .light))
                        .foregroundStyle(.secondary)

                    TextField("en,es,de,fr,tr,it,pt-BR", text: profileStore.binding(for: \.languageKeysText))
                        .textFieldStyle(.roundedBorder)
                }

                Button("Convert", action: convert)
                    .keyboardShortcut(.defaultAction)

                if !conversionStatusMessage.isEmpty {
                    Text(conversionStatusMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.green)
                }

                Divider()

                Text("More Tools")
                    .font(.system(size: 16, weight: .semibold))

                HStack(spacing: 12) {
                    toolEntry(
                        title: "Unused Localization Keys",
                        description: "Find spreadsheet keys that are not referenced in project source code.",
                        systemImage: "magnifyingglass",
                        buttonTitle: "Open Finder"
                    ) {
                        isShowingUnusedKeysSheet = true
                    }

                    toolEntry(
                        title: "Translation Attachments",
                        description: "Import exported Localizable.strings attachments into a project.",
                        systemImage: "square.and.arrow.down",
                        buttonTitle: "Open Importer"
                    ) {
                        isShowingAttachmentImportSheet = true
                    }
                }
            }
            .padding(32)
        }
        .frame(minWidth: 720, minHeight: 680, alignment: .topLeading)
        .background(WindowConfigurationView())
        .sheet(isPresented: $isShowingUnusedKeysSheet) {
            UnusedKeysSheet()
        }
        .sheet(isPresented: $isShowingAttachmentImportSheet) {
            TranslationAttachmentsSheet()
        }
        .alert(item: $alertMessage) { item in
            Alert(title: Text("System"), message: Text(item.text))
        }
        .confirmationDialog(
            "Delete \(profileStore.selectedProfile.name)?",
            isPresented: $isConfirmingProfileDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Configuration", role: .destructive) {
                profileStore.deleteSelectedProfile()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved paths and language settings for this configuration.")
        }
        .onChange(of: profileStore.selectedProfileID) {
            shouldShowInputFileMissingError = false
            conversionStatusMessage = ""
        }
    }

    private var configurationSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Picker("Configuration:", selection: $profileStore.selectedProfileID) {
                        ForEach(profileStore.profiles) { profile in
                            Text(profile.name).tag(profile.id)
                        }
                    }
                    .frame(maxWidth: 360)

                    Button("New", action: profileStore.addProfile)
                    Button("Duplicate", action: profileStore.duplicateSelectedProfile)
                    Button("Delete") {
                        isConfirmingProfileDeletion = true
                    }
                        .disabled(profileStore.profiles.count == 1)
                }

                HStack {
                    Text("Configuration Name:")
                    TextField("Configuration Name", text: profileStore.binding(for: \.name))
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding(4)
        }
    }

    private func toolEntry(
        title: String,
        description: String,
        systemImage: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label(title, systemImage: systemImage)
                    .font(.system(size: 14, weight: .semibold))

                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(buttonTitle, action: action)
            }
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .padding(4)
        }
        .frame(maxWidth: .infinity)
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
        let profile = profileStore.selectedProfile

        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showAlert("Please enter a configuration name.")
            return
        }

        guard !profile.excelPath.isEmpty else {
            showAlert("Please select an XLS or CSV file.")
            return
        }

        guard FileManager.default.fileExists(atPath: profile.excelPath) else {
            shouldShowInputFileMissingError = true
            return
        }

        shouldShowInputFileMissingError = false

        guard !profile.stringPath.isEmpty || !profile.projectPath.isEmpty else {
            showAlert("Select at least one export path or project localization path.")
            return
        }

        let languageKeys = parsedLanguageKeys(from: profile.languageKeysText)
        guard !languageKeys.isEmpty else {
            showAlert("Specify the language keys in the spreadsheet (e.g. en,es,de).")
            return
        }

        do {
            try conversionService.convert(
                excelPath: profile.excelPath,
                stringOutputDirectory: profile.stringPath.isEmpty ? nil : profile.stringPath,
                projectLocalizationDirectory: profile.projectPath.isEmpty ? nil : profile.projectPath,
                languageKeys: languageKeys
            )
            let completionDate = Date()
            let archivedPath = try archiveInputFile(at: profile.excelPath, completedAt: completionDate)
            let completedAt = statusTimeFormatter.string(from: completionDate)
            conversionStatusMessage = "\(profile.name) converted at \(completedAt). Input archived as \(URL(fileURLWithPath: archivedPath).lastPathComponent)."
        } catch {
            showAlert(error.localizedDescription)
        }
    }

    private func archiveInputFile(at path: String, completedAt date: Date) throws -> String {
        let inputURL = URL(fileURLWithPath: path)
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

    private func parsedLanguageKeys(from text: String) -> [String] {
        text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func selectExcelFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = supportedSpreadsheetTypes

        if panel.runModal() == .OK {
            profileStore.binding(for: \.excelPath).wrappedValue = panel.url?.path ?? ""
            shouldShowInputFileMissingError = false
        }
    }

    private func selectStringOutputDirectory() {
        if let path = selectDirectory() {
            profileStore.binding(for: \.stringPath).wrappedValue = path
        }
    }

    private func selectProjectLocalizationDirectory() {
        if let path = selectDirectory() {
            profileStore.binding(for: \.projectPath).wrappedValue = path
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
        let path = profileStore.selectedProfile.excelPath
        guard !path.isEmpty else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    private func openStringOutputLocation() {
        let path = profileStore.selectedProfile.stringPath
        guard !path.isEmpty else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    private func openProjectLocalizationLocation() {
        let path = profileStore.selectedProfile.projectPath
        guard !path.isEmpty else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
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

private struct SecondaryToolHeader: View {
    let title: String
    let description: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 24))
                .foregroundStyle(.tint)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ToolPathSection: View {
    let title: String
    let value: String
    let isDisabled: Bool
    let selectAction: () -> Void
    let revealAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .medium))

            HStack(spacing: 8) {
                TextField("Not selected", text: .constant(value))
                    .textFieldStyle(.roundedBorder)
                    .disabled(true)

                Button("Select", action: selectAction)
                    .disabled(isDisabled)
                Button("Open", action: revealAction)
                    .disabled(value.isEmpty)
            }
        }
    }
}

struct TranslationAttachmentsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PreferenceKeys.translationAttachmentPath) private var attachmentPath = ""
    @AppStorage(PreferenceKeys.translationProjectPath) private var projectPath = ""

    @State private var statusMessage = ""
    @State private var alertMessage: AlertMessage?

    private let conversionService = LocalizationConversionService()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SecondaryToolHeader(
                title: "Import Translation Attachments",
                description: "Replace matching *.lproj/Localizable.strings files in a project. Source attachments are left unchanged.",
                systemImage: "square.and.arrow.down"
            )

            GroupBox("Locations") {
                VStack(alignment: .leading, spacing: 16) {
                    ToolPathSection(
                        title: "Translation Attachments Directory",
                        value: attachmentPath,
                        isDisabled: false,
                        selectAction: selectAttachmentDirectory,
                        revealAction: { reveal(attachmentPath) }
                    )

                    ToolPathSection(
                        title: "Project Localization Directory to Replace",
                        value: projectPath,
                        isDisabled: false,
                        selectAction: selectProjectDirectory,
                        revealAction: { reveal(projectPath) }
                    )
                }
                .padding(8)
            }

            if !statusMessage.isEmpty {
                Label(statusMessage, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green)
                    .textSelection(.enabled)
            }

            Spacer()

            Divider()

            HStack {
                Button("Close") { dismiss() }
                Spacer()
                Button("Import Attachments", action: importAttachments)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 620, minHeight: 390, alignment: .topLeading)
        .alert(item: $alertMessage) { item in
            Alert(title: Text("Import Failed"), message: Text(item.text))
        }
    }

    private func importAttachments() {
        statusMessage = ""
        guard !attachmentPath.isEmpty else {
            showAlert("Please select a translation attachments directory.")
            return
        }
        guard !projectPath.isEmpty else {
            showAlert("Please select a project localization directory to replace.")
            return
        }

        do {
            let count = try conversionService.importTranslationAttachments(
                attachmentDirectory: attachmentPath,
                projectLocalizationDirectory: projectPath
            )
            statusMessage = "Imported \(count) Localizable.strings file(s)."
        } catch {
            showAlert(error.localizedDescription)
        }
    }

    private func selectAttachmentDirectory() {
        if let path = selectDirectory() { attachmentPath = path }
    }

    private func selectProjectDirectory() {
        if let path = selectDirectory() { projectPath = path }
    }

    private func selectDirectory() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private func reveal(_ path: String) {
        guard !path.isEmpty else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    private func showAlert(_ text: String) {
        alertMessage = AlertMessage(text: text)
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
        VStack(alignment: .leading, spacing: 20) {
            SecondaryToolHeader(
                title: "Find Unused Localization Keys",
                description: "Compare keys in a spreadsheet with references in Objective-C and Swift source files.",
                systemImage: "magnifyingglass"
            )

            GroupBox("Search Inputs") {
                VStack(alignment: .leading, spacing: 16) {
                    ToolPathSection(
                        title: "Project Source Directory",
                        value: projectPath,
                        isDisabled: isSearching,
                        selectAction: selectProjectPath,
                        revealAction: openProjectPath
                    )

                    ToolPathSection(
                        title: "Spreadsheet File (.xls or .csv)",
                        value: xlsPath,
                        isDisabled: isSearching,
                        selectAction: selectXLSPath,
                        revealAction: openXLSPath
                    )

                    Toggle("Ignore matches inside source-code comments", isOn: $ignoreComments)
                        .disabled(isSearching)
                }
                .padding(8)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Results")
                        .font(.system(size: 13, weight: .semibold))
                    if isSearching {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(status)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                ScrollView {
                    Text(resultText)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.2))
                }
            }

            Divider()

            HStack {
                Button("Close") { dismiss() }
                Spacer()
                Button(isSearching ? "Searching..." : "Start Search", action: startSearch)
                    .disabled(isSearching)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 640, minHeight: 560, alignment: .topLeading)
        .alert(item: $alertMessage) { item in
            Alert(title: Text("Notice"), message: Text(item.text))
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
