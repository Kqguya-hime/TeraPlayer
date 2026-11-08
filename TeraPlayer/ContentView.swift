import SwiftUI
import AVFoundation
import MediaPlayer
import SwiftData

@MainActor
final class NowPlayingManager {

    var onPlay: (() -> Void)?
    var onPause: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onSeek: ((Double) -> Void)?

    private var isConfigured = false

    // ロック画面からの操作を登録
    func configure() {

        guard !isConfigured else { return }
        isConfigured = true

        let center = MPRemoteCommandCenter.shared()

        // 再生
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.onPlay?()
            }
            return .success
        }

        // 一時停止
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.onPause?()
            }
            return .success
        }

        // 再生・一時停止の切り替え
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.onToggle?()
            }
            return .success
        }

        // 次の曲
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.onNext?()
            }
            return .success
        }

        // 前の曲
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.onPrevious?()
            }
            return .success
        }

        // 再生位置の変更
        center.changePlaybackPositionCommand.addTarget {
            [weak self] event in

            guard let event = event
                    as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }

            Task { @MainActor in
                self?.onSeek?(event.positionTime)
            }

            return .success
        }

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true
    }

    var onToggle: (() -> Void)?

    // ロック画面に表示する情報を更新
    func update(
        title: String,
        elapsed: Double,
        duration: Double,
        isPlaying: Bool
    ) {

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]

        if duration.isFinite && duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }

        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }

    // 再生情報を消去
    func clear() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
}
enum RepeatMode {
    case off
    case all
    case one
}

// 検索対象
private enum MusicSearchField: String, CaseIterable, Identifiable {
    case title = "曲名"
    case artist = "アーティスト"
    case album = "アルバム"

    var id: String { rawValue }
}

// キュー内の曲が手動追加か自動選曲かを区別する
enum QueueSource: Equatable {
    case manual
    case automatic
}

private enum QueueTargetKind: String {
    case artist
    case album
}

private struct QueueTarget: Identifiable {
    let name: String
    let kind: QueueTargetKind

    var id: String {
        "\(kind.rawValue):\(name)"
    }

    var displayKind: String {
        kind == .artist ? "アーティスト" : "アルバム"
    }
}

private enum QueueOperation: String, CaseIterable, Identifiable {
    case replace = "置き換え"
    case append = "末尾に追加"

    var id: String { rawValue }
}

private struct QueueRefillCondition {
    let targetName: String
    let targetKind: QueueTargetKind
    let trackPaths: Set<String>
    let shuffle: Bool
}

// 再生キューの1項目
struct QueueItem: Identifiable {
    let file: OpenListFile
    let path: String
    var source: QueueSource

    var id: String {
        path
    }
}

struct ContentView: View {
    
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query private var musicTracks: [MusicTrack]

    // ライブラリスキャンの状態
    @State private var isScanningLibrary = false
    @State private var libraryScanStatus = ""
    
    // 現在表示しているファイル
    @State private var files: [OpenListFile] = []
    @State private var currentPath = "/terabox"
    @State private var isOfflineMode = false

    // ライブラリ検索
    @State private var searchField: MusicSearchField = .title
    @State private var searchText = ""

    // 再生キュー
    @State private var queue: [QueueItem] = []

    // 現在再生中の曲
    @State private var currentTrack: QueueItem? = nil

    // 前に再生した曲の履歴
    @State private var playHistory: [QueueItem] = []

    @State private var errorMessage = ""
    @State private var isLoading = false

    // プレイヤー
    @State private var player = AVPlayer()
    @State private var isPlaying = false
    @State private var nowPlayingManager = NowPlayingManager()
    @State private var timeObserverToken: Any? = nil
    @State private var elapsedTime: Double = 0
    @State private var playbackDuration: Double = 0
    @State private var isSeeking = false
    // 再生設定
    @State private var isShuffle = false
    @State private var repeatMode: RepeatMode = .off
    
    // オフラインダウンロードの状態
    @State private var isDownloading = false
    @State private var downloadProgress = ""
    @State private var downloadFailures: [String] = []
    @State private var downloadTask: Task<Void, Never>? = nil
    @State private var backgroundDownloadCompleted = 0
    @State private var backgroundDownloadTotal = 0
    @State private var backgroundDownloadWasInterrupted = false
    
    //ネットワーク監視
    @StateObject private var networkMonitor = NetworkMonitor()
    
    // 中断・失敗したダウンロードの再試行管理
    @State private var backgroundDownloadNeedsRetry = false
    @State private var isRecoveringDownloads = false
    
    private let service = OpenListService()

    private let musicExtensions = [
        "mp3", "m4a", "aac", "wav", "aiff", "flac"
    ]

    // 自動選曲する曲数
    private let shuffleQueueCount = 10

    @State private var libraryBrowseMode = "曲"
    @State private var selectedArtist: String? = nil
    @State private var selectedAlbum: String? = nil
    @State private var queueTarget: QueueTarget? = nil
    @State private var isQueueTrackListExpanded = false
    @State private var queueShuffle = false
    @State private var queueOperation: QueueOperation = .replace
    @State private var activeRefillCondition: QueueRefillCondition? = nil
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            libraryScreen
                .tabItem {
                    Label("楽曲", systemImage: "music.note.list")
                }
                .tag(0)

            playbackScreen
                .tabItem {
                    Label("再生", systemImage: "play.circle")
                }
                .tag(1)

            managementScreen
                .tabItem {
                    Label("管理", systemImage: "slider.horizontal.3")
                }
                .tag(2)
        }
        .safeAreaInset(edge: .bottom) {
            playerControls
        }
        .task {
            networkMonitor.start()
            configureBackgroundDownloadCallbacks()
            BackgroundDownloadManager.shared.restoreSession()
            configureAudioSession()
            configureNowPlaying()
            await loadFiles()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .AVPlayerItemDidPlayToEndTime
            )
        ) { notification in
            if let finishedItem = notification.object as? AVPlayerItem,
               finishedItem == player.currentItem {
                Task {
                    await playNext(isNaturalEnd: true)
                }
            }
        }
        .onChange(of: networkMonitor.isWiFiConnected) { _, isConnected in
            if isConnected {
                print("Wi-Fi接続を検知：自動同期を開始")
                Task {
                    await loadFiles()
                    await scanLibrary()
                }
                retryInterruptedDownloadsIfNeeded()
            }
        }
        .onChange(of: backgroundDownloadNeedsRetry) { _, needsRetry in
            if needsRetry {
                retryInterruptedDownloadsIfNeeded()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && networkMonitor.isWiFiConnected {
                print("アプリ復帰：Wi-Fi接続中のため自動同期")
                Task {
                    await loadFiles()
                    await scanLibrary()
                }
            }
        }
    }

    // MARK: - 画面

    private var libraryScreen: some View {
        NavigationStack {
            List {
                Picker("表示", selection: $libraryBrowseMode) {
                    Text("曲").tag("曲")
                    Text("アーティスト").tag("アーティスト")
                    Text("アルバム").tag("アルバム")
                }
                .pickerStyle(.segmented)

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)

                    TextField(searchPlaceholder, text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if libraryBrowseMode == "アーティスト" {
                    ForEach(filteredArtistNames, id: \.self) { artist in
                        Button {
                            queueShuffle = false
                            queueOperation = .replace
                            queueTarget = QueueTarget(name: artist, kind: .artist)
                        } label: {
                            Label(artist, systemImage: "person")
                        }
                    }
                } else if libraryBrowseMode == "アルバム" {
                    ForEach(filteredAlbumNames, id: \.self) { album in
                        Button {
                            queueShuffle = false
                            queueOperation = .replace
                            queueTarget = QueueTarget(name: album, kind: .album)
                        } label: {
                            Label(album, systemImage: "square.stack")
                        }
                    }
                } else {
                    if let artist = selectedArtist {
                        Section {
                            HStack {
                                Text("アーティスト：\(artist)")
                                Spacer()
                                Button("解除") {
                                    selectedArtist = nil
                                }
                                .font(.caption)
                            }
                        }
                    }

                    if let album = selectedAlbum {
                        Section {
                            HStack {
                                Text("アルバム：\(album)")
                                Spacer()
                                Button("解除") {
                                    selectedAlbum = nil
                                }
                                .font(.caption)
                            }
                        }
                    }

                    Menu {
                        Picker("検索対象", selection: $searchField) {
                            ForEach(MusicSearchField.allCases) { field in
                                Text(field.rawValue).tag(field)
                            }
                        }
                    } label: {
                        Label("検索対象", systemImage: "slider.horizontal.3")
                    }
                    .menuStyle(.borderlessButton)

                    if isLoading {
                        ProgressView("読み込み中...")
                    }

                    if libraryDisplayFiles.isEmpty {
                        Text("表示できる楽曲がありません")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(libraryDisplayFiles) { file in
                        Button {
                            if file.is_dir {
                                Task { await openFolder(file) }
                            } else if isMusicFile(file) {
                                enqueueOrPlay(file)
                            }
                        } label: {
                            HStack {
                                Image(systemName: file.is_dir ? "folder.fill" : "music.note")
                                VStack(alignment: .leading) {
                                    Text(file.name)
                                        .foregroundStyle(.primary)
                                    Text(file.is_dir ? "フォルダ" : "\(file.size) bytes")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if isMusicFile(file) {
                                    Image(systemName: "text.badge.plus")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .disabled(!file.is_dir && !isMusicFile(file))
                    }
                }

                if !errorMessage.isEmpty {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(selectedArtist ?? selectedAlbum ?? "楽曲")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("上へ") {
                        Task { await goToParentFolder() }
                    }
                    .disabled(isOfflineMode || currentPath == "/terabox" || selectedArtist != nil || selectedAlbum != nil)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("更新") {
                        Task { await loadFiles() }
                    }
                }
            }
        }
        .sheet(item: $queueTarget) { target in
            queueCreationSheet(for: target)
        }
    }

    private func queueCreationSheet(for target: QueueTarget) -> some View {
        let tracks = tracks(for: target)

        return NavigationStack {
            Form {
                Section {
                    LabeledContent("種類", value: target.displayKind)
                    LabeledContent("対象", value: target.name)
                    LabeledContent("対象曲数", value: "\(tracks.count) 曲")
                }

                Section {
                    DisclosureGroup(
                        "対象曲一覧（\(tracks.count)曲）",
                        isExpanded: $isQueueTrackListExpanded
                    ) {
                        if tracks.isEmpty {
                            Text("対象曲がありません")
                                .foregroundStyle(.secondary)
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 10) {
                                    ForEach(tracks, id: \.path) { track in
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(
                                                track.title
                                                    ?? (track.fileName as NSString).deletingPathExtension
                                            )
                                            .font(.body)

                                            if let artist = track.artist, !artist.isEmpty {
                                                Text(artist)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .padding(.vertical, 6)
                            }
                            .frame(maxHeight: 220)
                        }
                    }
                }

                Section("シャッフル") {
                    Picker("シャッフル", selection: $queueShuffle) {
                        Text("OFF").tag(false)
                        Text("ON").tag(true)
                    }
                    .pickerStyle(.segmented)
                }

                Section("キュー操作") {
                    Picker("操作", selection: $queueOperation) {
                        ForEach(QueueOperation.allCases) { operation in
                            Text(operation.rawValue).tag(operation)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(queueOperation == .replace
                         ? "現在再生中の曲はそのままにし、これから再生するキューを置き換えます。"
                         : "現在のキューを残し、その末尾に対象曲を追加します。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    createQueue(for: target)
                    queueTarget = nil
                } label: {
                    Text("キューを作成")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(tracks.isEmpty)
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .background(.bar)
            }
            .navigationTitle("キューを作成")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") {
                        queueTarget = nil
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var playbackScreen: some View {
        NavigationStack {
            List {
                Section("現在再生中") {
                    if let track = currentTrack {
                        let metadata = musicTracks.first {
                            $0.path == track.path
                        }

                        VStack(spacing: 18) {
                            Image(systemName: "music.note")
                                .font(.system(size: 54))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 170)
                                .background(.quaternary)
                                .clipShape(RoundedRectangle(cornerRadius: 16))

                            VStack(spacing: 6) {
                                Text(metadata?.title ?? (track.file.name as NSString).deletingPathExtension)
                                    .font(.title3.weight(.semibold))
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)

                                Text(metadata?.artist ?? "アーティスト情報なし")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)

                                Text(metadata?.album ?? "アルバム情報なし")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity)

                            VStack(spacing: 4) {
                                Slider(
                                    value: $elapsedTime,
                                    in: 0...max(playbackDuration, 1),
                                    onEditingChanged: { isEditing in
                                        isSeeking = isEditing

                                        if !isEditing {
                                            seekPlayback(to: elapsedTime)
                                        }
                                    }
                                )
                                .disabled(playbackDuration <= 0)

                                HStack {
                                    Text(formattedTime(elapsedTime))
                                    Spacer()
                                    Text(
                                        playbackDuration > 0
                                            ? formattedTime(playbackDuration)
                                            : "--:--"
                                    )
                                }
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            }

                            HStack(spacing: 34) {
                                Button {
                                    playPrevious()
                                } label: {
                                    Image(systemName: "backward.end.fill")
                                        .font(.title2)
                                }
                                .disabled(playHistory.isEmpty)
                                .accessibilityLabel("前の曲")

                                Button {
                                    togglePlayback()
                                } label: {
                                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                        .font(.system(size: 30))
                                        .frame(width: 64, height: 64)
                                        .background(.blue)
                                        .foregroundStyle(.white)
                                        .clipShape(Circle())
                                }
                                .disabled(player.currentItem == nil)
                                .accessibilityLabel(isPlaying ? "一時停止" : "再生")

                                Button {
                                    Task {
                                        await playNext()
                                    }
                                } label: {
                                    Image(systemName: "forward.end.fill")
                                        .font(.title2)
                                }
                                .disabled(queue.isEmpty && !isShuffle && activeRefillCondition == nil)
                                .accessibilityLabel("次の曲")
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)

                            HStack {
                                Button {
                                    toggleShuffle()
                                } label: {
                                    Label("シャッフル", systemImage: "shuffle")
                                        .foregroundStyle(isShuffle ? .blue : .secondary)
                                }

                                Spacer()

                                Button {
                                    switch repeatMode {
                                    case .off:
                                        repeatMode = .all
                                    case .all:
                                        repeatMode = .one
                                    case .one:
                                        repeatMode = .off
                                    }
                                } label: {
                                    Label(
                                        repeatMode == .one ? "1曲リピート" : "リピート",
                                        systemImage: repeatIcon
                                    )
                                    .foregroundColor(repeatMode == .off ? .secondary : .blue)
                                }
                            }
                            .font(.caption)
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 10)
                    } else {
                        ContentUnavailableView(
                            "再生していません",
                            systemImage: "music.note",
                            description: Text("楽曲画面から曲を選択してください")
                        )
                        .frame(maxWidth: .infinity)
                    }
                }

                Section("再生キュー（\(queue.count)曲）") {
                    if queue.isEmpty {
                        Text("キューは空です")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(queue) { item in
                        Button {
                            moveToFront(item)
                        } label: {
                            HStack {
                                Image(systemName: "music.note")
                                VStack(alignment: .leading) {
                                    Text(item.file.name)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(item.source == .manual ? "ユーザー指定" : "自動選曲")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "line.3.horizontal")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onMove(perform: moveQueueItems)
                    .onDelete(perform: deleteQueueItems)
                }
            }
            .navigationTitle("再生")
            .toolbar {
                EditButton()
            }
        }
    }

    private var managementScreen: some View {
        NavigationStack {
            List {
                Section("音楽ライブラリ") {
                    if isScanningLibrary {
                        ProgressView(libraryScanStatus)
                    } else if !libraryScanStatus.isEmpty {
                        Text(libraryScanStatus)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("まだスキャンしていません")
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        Task { await scanLibrary() }
                    } label: {
                        Label("全曲スキャン・同期", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(isScanningLibrary || isOfflineMode)
                }

                Section("オフライン保存") {
                    Button {
                        downloadTask = Task { await downloadAllTracks() }
                    } label: {
                        Label("全曲ダウンロード", systemImage: "arrow.down.circle")
                    }
                    .disabled(isDownloading || isScanningLibrary || isOfflineMode)

                    Button(role: .destructive) {
                        downloadTask?.cancel()
                        BackgroundDownloadManager.shared.cancelAllDownloads()
                        downloadProgress = "キャンセル処理中..."
                    } label: {
                        Label("キャンセル", systemImage: "xmark.circle")
                    }
                    .disabled(!isDownloading)

                    if !downloadProgress.isEmpty {
                        Text(downloadProgress)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if isDownloading {
                        ProgressView()
                    }

                    if !downloadFailures.isEmpty {
                        Text("ダウンロード失敗：\(downloadFailures.count)曲")
                            .font(.subheadline)
                            .foregroundStyle(.red)

                        ForEach(Array(downloadFailures.enumerated()), id: \.offset) { _, fileName in
                            Label(fileName, systemImage: "exclamationmark.circle")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }

                Section("接続状態") {
                    LabeledContent("ライブラリ", value: isOfflineMode ? "オフライン" : "オンライン")
                    LabeledContent("Wi-Fi", value: networkMonitor.isWiFiConnected ? "接続中" : "未接続")
                    Button("ライブラリを再読み込み") {
                        Task { await loadFiles() }
                    }
                }

                if !errorMessage.isEmpty {
                    Section("エラー") {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("管理")
        }
    }

    // MARK: - 検索

    private var searchPlaceholder: String {
        switch libraryBrowseMode {
        case "アーティスト":
            return "アーティストを検索"
        case "アルバム":
            return "アルバムを検索"
        default:
            return "曲を検索"
        }
    }

    private var filteredArtistNames: [String] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return artistNames }
        return artistNames.filter {
            $0.localizedCaseInsensitiveContains(keyword)
        }
    }

    private var filteredAlbumNames: [String] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return albumNames }
        return albumNames.filter {
            $0.localizedCaseInsensitiveContains(keyword)
        }
    }

    // MARK: - ライブラリ表示データ

    private var artistNames: [String] {
        Array(Set(musicTracks.compactMap { track in
            track.artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })).sorted()
    }

    private var albumNames: [String] {
        Array(Set(musicTracks.compactMap { track in
            track.album?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })).sorted()
    }

    private var libraryDisplayFiles: [OpenListFile] {
        if let artist = selectedArtist {
            return musicTracks
                .filter { $0.artist == artist }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                .map { track in
                    OpenListFile(name: track.fileName, size: track.fileSize, is_dir: false, modified: track.cloudModified, created: nil, sign: track.cloudSign, path: track.path)
                }
                .filter { fileMatchesSearch($0) }
        }

        if let album = selectedAlbum {
            return musicTracks
                .filter { $0.album == album }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                .map { track in
                    OpenListFile(name: track.fileName, size: track.fileSize, is_dir: false, modified: track.cloudModified, created: nil, sign: track.cloudSign, path: track.path)
                }
                .filter { fileMatchesSearch($0) }
        }

        return displayedFiles
    }

    private func fileMatchesSearch(_ file: OpenListFile) -> Bool {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return true }
        guard let track = musicTracks.first(where: { $0.path == makePath(for: file) }) else {
            return false
        }
        switch searchField {
        case .title:
            return track.title.localizedCaseInsensitiveContains(keyword)
        case .artist:
            return track.artist?.localizedCaseInsensitiveContains(keyword) ?? false
        case .album:
            return track.album?.localizedCaseInsensitiveContains(keyword) ?? false
        }
    }

    // MARK: - 検索結果

    private var displayedFiles: [OpenListFile] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        // 検索語が空なら、従来どおり全ファイルを表示
        guard !keyword.isEmpty else {
            return files
        }

        // メタデータ検索ではフォルダを除外
        return files.filter { file in
            guard !file.is_dir, isMusicFile(file) else {
                return false
            }

            let path = makePath(for: file)
            guard let track = musicTracks.first(where: { $0.path == path }) else {
                return false
            }

            switch searchField {
            case .title:
                return track.title.localizedCaseInsensitiveContains(keyword)
            case .artist:
                return track.artist?.localizedCaseInsensitiveContains(keyword) ?? false
            case .album:
                return track.album?.localizedCaseInsensitiveContains(keyword) ?? false
            }
        }
    }

    // MARK: - 差分ライブラリ同期

    private func scanLibrary() async {

        guard !isScanningLibrary else {
            return
        }

        isScanningLibrary = true
        libraryScanStatus = "クラウドを調査中..."
        errorMessage = ""

        defer {
            isScanningLibrary = false
        }

        // 同期専用のデータベース操作領域
        let syncContext = ModelContext(modelContext.container)

        let store = OfflineMusicStore()

        do {

            // 1. クラウド上の全音楽ファイルを取得
            let scannedFiles = try await service.scanMusicFiles(
                rootPath: "/terabox",
                musicExtensions: Set(musicExtensions)
            )

            libraryScanStatus =
                "\(scannedFiles.count)曲の差分を確認中..."

            // 2. データベースの既存データを取得
            let existingTracks = try syncContext.fetch(
                FetchDescriptor<MusicTrack>()
            )

            // /terabox 配下の曲だけを比較対象にする
            var existingByPath: [String: MusicTrack] = [:]

            for track in existingTracks {
                if track.path.hasPrefix("/terabox/") {
                    existingByPath[track.path] = track
                }
            }

            // 3. 同期結果の集計
            var newCount = 0
            var changedCount = 0
            var unchangedCount = 0
            var deletedCount = 0
            var metadataFailures: [String] = []

            let metadataService = MusicMetadataService()

            // 4. クラウドの各ファイルを確認
            for scanned in scannedFiles {

                let track: MusicTrack
                let isNew: Bool

                // 既存データを検索
                if let existing = existingByPath[scanned.path] {

                    track = existing
                    isNew = false

                } else {

                    // 新規ファイルを登録
                    track = MusicTrack(
                        path: scanned.path,
                        fileName: scanned.file.name,
                        fileSize: scanned.file.size
                    )

                    syncContext.insert(track)
                    isNew = true
                }

                // 今回のスキャンで確認した曲を既存一覧から除外
                existingByPath.removeValue(
                    forKey: scanned.path
                )

                // 5. 更新日時を比較
                let modificationChanged: Bool

                if let oldModified = track.cloudModified,
                   let newModified = scanned.file.modified {

                    modificationChanged =
                        oldModified != newModified

                } else if track.cloudModified == nil,
                          scanned.file.modified != nil {

                    // 旧データに更新日時がない場合
                    modificationChanged = true

                } else {

                    modificationChanged = false
                }

                // サイズまたは更新日時が異なれば変更あり
                let isChanged =
                    isNew ||
                    track.fileSize != scanned.file.size ||
                    modificationChanged

                // ファイル名を更新
                track.fileName = scanned.file.name

                // 6. 変更がなければ何もしない
                if !isChanged {

                    unchangedCount += 1
                    continue
                }

                if isNew {
                    newCount += 1
                } else {
                    changedCount += 1
                }

                print(
                    "差分検出: \(isNew ? "新規" : "変更") / \(scanned.file.name)"
                )

                // 7. 変更された曲のローカル音源を無効化
                if let oldLocalFileName = track.localFileName {

                    // 古いファイルを削除
                    try? store.deleteFile(oldLocalFileName)
                }

                track.isDownloaded = false
                track.localFileName = nil

                // 8. メタデータを取得
                do {

                    let musicURL = try await service.getMusicURL(
                        path: scanned.path
                    )

                    let metadata = try await metadataService.readMetadata(
                        from: musicURL
                    )

                    // タイトル
                    if let title = metadata.title?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       !title.isEmpty {

                        track.title = title

                    } else {

                        track.title = (
                            scanned.file.name as NSString
                        ).deletingPathExtension
                    }

                    // アーティスト
                    track.artist = metadata.artist?
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    if track.artist?.isEmpty == true {
                        track.artist = nil
                    }

                    // アルバム
                    track.album = metadata.album?
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    if track.album?.isEmpty == true {
                        track.album = nil
                    }

                    // 再生時間
                    track.duration = metadata.duration

                    // クラウドの同期情報を保存
                    track.fileSize = scanned.file.size
                    track.cloudModified = scanned.file.modified
                    track.cloudSign = scanned.file.sign

                    print("メタデータ更新: \(track.title)")

                } catch {

                    // 失敗した場合は次回の同期で再試行できるようにする
                    metadataFailures.append(scanned.file.name)

                    print(
                        "メタデータ取得失敗: \(scanned.file.name) / \(error.localizedDescription)"
                    )
                }
            }

            // 9. クラウドから削除された曲を処理
            // ここに残っている曲は、今回のクラウド一覧に存在しなかった曲
            for oldTrack in existingByPath.values {

                // ローカル音源も削除
                if let localFileName = oldTrack.localFileName {
                    try? store.deleteFile(localFileName)
                }

                syncContext.delete(oldTrack)
                deletedCount += 1
            }

            // 10. データベースに保存
            try syncContext.save()

            // 11. 結果を表示
            libraryScanStatus =
                """
                同期完了
                新規：\(newCount)曲
                変更：\(changedCount)曲
                変更なし：\(unchangedCount)曲
                削除：\(deletedCount)曲
                メタデータ取得失敗：\(metadataFailures.count)曲
                """

            print("===== 差分同期完了 =====")
            print("新規: \(newCount)")
            print("変更: \(changedCount)")
            print("変更なし: \(unchangedCount)")
            print("削除: \(deletedCount)")
            print("メタデータ失敗: \(metadataFailures.count)")
            print("========================")

        } catch {

            // スキャン全体が失敗した場合は変更を取り消す
            syncContext.rollback()

            errorMessage =
                "ライブラリ同期エラー: \(error.localizedDescription)"

            libraryScanStatus = "同期に失敗しました"
        }
    }
    // MARK: - バックグラウンドダウンロード完了処理

    private func configureBackgroundDownloadCallbacks() {

        let manager = BackgroundDownloadManager.shared

        // ダウンロード進捗の監視
        manager.onProgress = { progress in

            backgroundDownloadCompleted = progress.completed
            backgroundDownloadTotal = progress.total

            isDownloading = progress.isActive
            backgroundDownloadWasInterrupted = progress.wasInterrupted

            if progress.wasInterrupted {
                downloadProgress =
                    "前回のダウンロードは中断されました：\(progress.completed) / \(progress.total) 曲完了"

            } else if progress.total > 0 {

                downloadProgress =
                    "\(progress.completed) / \(progress.total) 曲完了"
            }

            downloadFailures = progress.failures
            backgroundDownloadNeedsRetry =
                progress.wasInterrupted ||
                (!progress.isActive && !progress.failures.isEmpty)
        }

        // ダウンロード完了結果の受け取り
        manager.onCompletion = { result, acknowledge in

            let syncContext = ModelContext(modelContext.container)

            // ダウンロード自体が失敗した場合
            if result.localFileName == nil {

                print(
                    "ダウンロード失敗: \(result.path) / \(result.errorMessage ?? "不明なエラー")"
                )

                // 失敗結果は進捗情報にも記録済みなので、処理済みとして受領する
                acknowledge(true)
                return
            }

            do {

                let allTracks = try syncContext.fetch(
                    FetchDescriptor<MusicTrack>()
                )

                if let track = allTracks.first(where: {
                    $0.path == result.path
                }), let localFileName = result.localFileName {

                    track.localFileName = localFileName
                    track.isDownloaded = true

                    try syncContext.save()

                    if isOfflineMode {
                        files = makeOfflineFiles()
                    }

                    print("保存完了: \(track.title)")

                } else {

                    print("データベースに対象の曲がありません: \(result.path)")
                }

                // SwiftDataへの保存が完了した後に受領通知
                acknowledge(true)

            } catch {

                print(
                    "データベース更新失敗: \(error.localizedDescription)"
                )

                // falseならBackgroundDownloadManager側で結果が保持される
                acknowledge(false)
            }
        }
    }
    // MARK: - 中断・失敗したダウンロードの再試行

    private func retryInterruptedDownloadsIfNeeded() {

        guard backgroundDownloadNeedsRetry else {
            return
        }

        guard networkMonitor.isWiFiConnected else {
            return
        }

        guard !isDownloading && !isRecoveringDownloads else {
            return
        }

        isRecoveringDownloads = true

        print("未完了のダウンロードを再試行します")

        Task {

            // 前回の状態を新しいダウンロードとして開始
            await downloadAllTracks()

            isRecoveringDownloads = false
        }
    }
    // MARK: - 全曲ダウンロード

    private func downloadAllTracks() async {

        guard !isDownloading else {
            return
        }

        isDownloading = true
        downloadProgress = "ダウンロード準備中..."
        downloadFailures = []
        errorMessage = ""

        backgroundDownloadCompleted = 0
        backgroundDownloadTotal = 0
        backgroundDownloadNeedsRetry = false

        // 同期専用のデータベース操作領域
        let syncContext = ModelContext(modelContext.container)

        let store = OfflineMusicStore()

        do {

            // 1. データベースから曲を取得
            let allTracks = try syncContext.fetch(
                FetchDescriptor<MusicTrack>()
            )

            let tracks = allTracks.filter {
                $0.path.hasPrefix("/terabox/")
            }

            // 2. ダウンロードが必要な曲を抽出
            var pendingTracks: [MusicTrack] = []

            for track in tracks {

                if track.isDownloaded,
                   let localFileName = track.localFileName,
                   (try? store.fileExists(localFileName)) == true {

                    continue
                }

                if track.isDownloaded {
                    track.isDownloaded = false
                    track.localFileName = nil
                }

                pendingTracks.append(track)
            }

            try syncContext.save()

            // 3. ダウンロード対象がない場合
            guard !pendingTracks.isEmpty else {
                downloadProgress = "すべての曲が保存済みです"
                isDownloading = false
                return
            }

            // 4. 必要なストレージ容量を計算
            let requiredBytes = pendingTracks.reduce(Int64(0)) {
                $0 + max(0, $1.fileSize)
            }

            let reserveBytes: Int64 = 200 * 1024 * 1024
            let requiredCapacity = requiredBytes + reserveBytes

            let availableBytes = try store.availableCapacity()

            guard availableBytes >= requiredCapacity else {

                let requiredGB =
                    Double(requiredCapacity) / 1_073_741_824

                let availableGB =
                    Double(availableBytes) / 1_073_741_824

                errorMessage = String(
                    format: "空き容量不足です。必要容量：約%.2fGB / 空き容量：約%.2fGB",
                    requiredGB,
                    availableGB
                )

                downloadProgress = "ダウンロードを開始できません"
                isDownloading = false
                return
            }

            // 5. 完了通知を登録
            configureBackgroundDownloadCallbacks()

            // 新しいダウンロードバッチを保存
            BackgroundDownloadManager.shared.startBatch(
                total: pendingTracks.count
            )

            // 6. バックグラウンドダウンロードを開始
            for (index, track) in pendingTracks.enumerated() {

                if Task.isCancelled {

                    // ここまでに開始した通信をキャンセル
                    BackgroundDownloadManager.shared.cancelAllDownloads()

                    // 実際に処理を開始した曲数に合わせる
                    backgroundDownloadTotal = index

                    downloadProgress = "ダウンロードをキャンセルしました"
                    isDownloading = false
                    downloadTask = nil

                    return
                }

                downloadProgress =
                    "\(index + 1) / \(pendingTracks.count) 曲を登録中..."

                do {

                    // クラウド上のURLを取得
                    let remoteURL = try await service.getMusicURL(
                        path: track.path
                    )

                    // ファイル拡張子
                    let fileExtension = (track.fileName as NSString)
                        .pathExtension

                    // バックグラウンド通信に登録
                    BackgroundDownloadManager.shared.startDownload(
                        from: remoteURL,
                        path: track.path,
                        fileExtension: fileExtension
                    )

                } catch {

                    // URL取得に失敗した曲を記録
                    BackgroundDownloadManager.shared.recordPreparationFailure(
                        fileName: track.fileName
                    )

                    print(
                        "ダウンロードURL取得失敗: \(track.fileName) / \(error.localizedDescription)"
                    )
                }
            }

            // 7. 登録完了
            downloadTask = nil

            if backgroundDownloadCompleted >= backgroundDownloadTotal {

                let successCount =
                    backgroundDownloadTotal - downloadFailures.count

                downloadProgress =
                    "ダウンロード完了：\(successCount)曲成功 / \(downloadFailures.count)曲失敗"

                isDownloading = false

            } else {

                downloadProgress =
                    "ダウンロード中：\(backgroundDownloadCompleted) / \(backgroundDownloadTotal) 曲完了"
            }

        } catch {

            errorMessage =
                "ダウンロードエラー: \(error.localizedDescription)"

            downloadProgress = "ダウンロードに失敗しました"
            isDownloading = false
            downloadTask = nil
        }
    }
    // MARK: - 基本処理

    private var folderName: String {
        if isOfflineMode {
            return "オフライン保存"
        }

        return currentPath == "/terabox"
            ? "TeraBox"
            : currentPath.components(separatedBy: "/").last ?? "TeraBox"
    }

    // 端末に実際に保存されている曲だけをオフライン一覧にする
    private func makeOfflineFiles() -> [OpenListFile] {
        let store = OfflineMusicStore()

        return musicTracks
            .filter { track in
                track.path.hasPrefix("/terabox/")
                    && track.isDownloaded
                    && track.localFileName != nil
                    && (try? store.fileExists(track.localFileName!)) == true
            }
            .map { track in
                OpenListFile(
                    name: track.fileName,
                    size: track.fileSize,
                    is_dir: false,
                    modified: track.cloudModified,
                    created: nil,
                    sign: track.cloudSign,
                    path: track.path
                )
            }
            .sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    // 音楽ファイルか判定
    private func isMusicFile(_ file: OpenListFile) -> Bool {
        musicExtensions.contains {
            file.name.lowercased().hasSuffix(".\($0)")
        }
    }

    // ファイルのフルパスを作成
    private func makePath(for file: OpenListFile) -> String {
        file.path ?? "\(currentPath)/\(file.name)"
    }

    // MARK: - バックグラウンド再生

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()

            try session.setCategory(
                .playback,
                mode: .default,
                options: []
            )

            try session.setActive(true)

        } catch {
            errorMessage = "音声設定エラー: \(error.localizedDescription)"
        }
    }

    // ロック画面操作の設定
    private func configureNowPlaying() {

        nowPlayingManager.onPlay = {
            guard player.currentItem != nil else { return }

            player.play()
            isPlaying = true
            updateNowPlayingInfo()
        }

        nowPlayingManager.onPause = {
            player.pause()
            isPlaying = false
            updateNowPlayingInfo()
        }

        nowPlayingManager.onToggle = {
            togglePlayback()
        }

        nowPlayingManager.onNext = {
            Task {
                await playNext()
            }
        }

        nowPlayingManager.onPrevious = {
            playPrevious()
        }

        nowPlayingManager.onSeek = { seconds in
            seekPlayback(to: seconds)
        }

        nowPlayingManager.configure()

        // 再生位置を約1秒ごとに更新
        if timeObserverToken == nil {

            timeObserverToken = player.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 1, preferredTimescale: 600),
                queue: .main
            ) { time in

                Task { @MainActor in
                    let seconds = time.seconds
                    let duration = player.currentItem?.duration.seconds ?? 0

                    if duration.isFinite && duration > 0 {
                        playbackDuration = duration
                    } else {
                        playbackDuration = 0
                    }

                    if !isSeeking && seconds.isFinite {
                        elapsedTime = max(0, seconds)
                    }

                    updateNowPlayingInfo()
                }
            }
        }
    }

    // 再生位置を変更
    private func seekPlayback(to seconds: Double) {
        guard playbackDuration > 0 else { return }

        let targetSeconds = min(max(seconds, 0), playbackDuration)
        let time = CMTime(
            seconds: targetSeconds,
            preferredTimescale: 600
        )

        player.seek(to: time) { _ in
            Task { @MainActor in
                elapsedTime = targetSeconds
                updateNowPlayingInfo()
            }
        }
    }

    // 秒数を「分:秒」の形式に変換
    private func formattedTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "--:--" }

        let totalSeconds = Int(max(0, seconds))
        return String(
            format: "%d:%02d",
            totalSeconds / 60,
            totalSeconds % 60
        )
    }

    // ロック画面に表示する情報を更新
    private func updateNowPlayingInfo() {
        
        guard let track = currentTrack else {
            nowPlayingManager.clear()
            return
        }
        
        let elapsed = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? 0
        
        nowPlayingManager.update(
            title: track.file.name,
            elapsed: elapsed.isFinite ? elapsed : 0,
            duration: duration,
            isPlaying: isPlaying
        )
        // デバッグ用
        print("Now Playing更新: \(track.file.name)")
        print(
            "登録情報:",
            MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            )
    }
    // MARK: - ファイル・フォルダ

    private func loadFiles() async {

        isLoading = true
        errorMessage = ""

        defer {
            isLoading = false
        }

        do {
            files = try await service.getFiles(path: currentPath)

            if isOfflineMode {
                libraryScanStatus = "オンラインライブラリに再接続しました"
            }

            isOfflineMode = false

        } catch {
            isOfflineMode = true
            files = makeOfflineFiles()
            libraryScanStatus = "オフラインモード：保存済み \(files.count) 曲"
            errorMessage = ""
        }
    }

    // フォルダを開く
    private func openFolder(_ folder: OpenListFile) async {

        currentPath = makePath(for: folder)

        await loadFiles()

        // シャッフル中かつキューが空なら新しいフォルダから補充
        if activeRefillCondition == nil && isShuffle && queue.isEmpty {
            fillShuffleQueue()
        }
    }

    // 1つ上のフォルダへ移動
    private func goToParentFolder() async {

        guard !isOfflineMode,
              currentPath != "/terabox" else {
            return
        }

        let parentPath = (currentPath as NSString)
            .deletingLastPathComponent

        guard parentPath == "/terabox"
                || parentPath.hasPrefix("/terabox/") else {
            return
        }

        currentPath = parentPath

        await loadFiles()

        if activeRefillCondition == nil && isShuffle && queue.isEmpty {
            fillShuffleQueue()
        }
    }

    // MARK: - 再生キュー

    // アーティスト／アルバムに属する全曲をライブラリ全体から取得
    private func tracks(for target: QueueTarget) -> [MusicTrack] {
        let matchingTracks = musicTracks.filter { track in
            switch target.kind {
            case .artist:
                return track.artist?
                    .trimmingCharacters(in: .whitespacesAndNewlines) == target.name
            case .album:
                return track.album?
                    .trimmingCharacters(in: .whitespacesAndNewlines) == target.name
            }
        }

        var seenPaths = Set<String>()
        return matchingTracks
            .filter { seenPaths.insert($0.path).inserted }
            .sorted {
                $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
            }
    }

    // 選択したアーティスト／アルバムからキューを作成
    private func createQueue(for target: QueueTarget) {
        let targetTracks = tracks(for: target)
        let targetPaths = Set(targetTracks.map(\.path))

        // 現在再生中の曲は候補から除外
        var candidates = targetTracks.filter {
            $0.path != currentTrack?.path
        }

        // 置き換え／追加それぞれの重複を除外
        if queueOperation == .append {
            let existingPaths = Set(queue.map(\.path))
            candidates.removeAll { existingPaths.contains($0.path) }
        }

        // 対象曲がすべて再生中・キュー内などで追加できない場合は何もしない
        guard !candidates.isEmpty else {
            return
        }

        if queueShuffle {
            candidates.shuffle()
        }

        let newItems = candidates.map { track in
            QueueItem(
                file: OpenListFile(
                    name: track.fileName,
                    size: track.fileSize,
                    is_dir: false,
                    modified: track.cloudModified,
                    created: nil,
                    sign: track.cloudSign,
                    path: track.path
                ),
                path: track.path,
                source: .manual
            )
        }

        switch queueOperation {
        case .replace:
            queue = newItems
        case .append:
            queue.append(contentsOf: newItems)
        }

        // 最後に作成・追加した条件だけを自動補充条件として保持
        activeRefillCondition = QueueRefillCondition(
            targetName: target.name,
            targetKind: target.kind,
            trackPaths: targetPaths,
            shuffle: queueShuffle
        )

        // 再生中の曲がなければ先頭から再生
        if currentTrack == nil, !queue.isEmpty {
            let firstItem = queue.removeFirst()
            Task {
                await startTrack(firstItem)
            }
        }
    }

    // 最後に指定されたアーティスト／アルバムからキューを補充
    private func refillActiveConditionQueue() {
        guard let condition = activeRefillCondition else {
            return
        }

        let queuedPaths = Set(queue.map(\.path))
        var candidates = musicTracks
            .filter { condition.trackPaths.contains($0.path) }
            .filter {
                $0.path != currentTrack?.path
                    && !queuedPaths.contains($0.path)
            }
            .sorted {
                $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
            }

        guard !candidates.isEmpty else {
            return
        }

        if condition.shuffle {
            candidates.shuffle()
        }

        let items = candidates.map { track in
            QueueItem(
                file: OpenListFile(
                    name: track.fileName,
                    size: track.fileSize,
                    is_dir: false,
                    modified: track.cloudModified,
                    created: nil,
                    sign: track.cloudSign,
                    path: track.path
                ),
                path: track.path,
                source: .automatic
            )
        }

        queue.append(contentsOf: items)
    }

    // 曲を選択したときの処理
    private func enqueueOrPlay(_ file: OpenListFile) {

        let path = makePath(for: file)

        // 再生中の曲を選択した場合は何もしない
        if currentTrack?.path == path {
            return
        }

        // 通常の曲選択ではアーティスト／アルバムの自動補充を解除
        activeRefillCondition = nil

        // すでにキューに存在する場合は削除
        queue.removeAll {
            $0.path == path
        }

        // 最前列に追加
        let item = QueueItem(
            file: file,
            path: path,
            source: .manual
        )

        queue.insert(item, at: 0)

        // まだ再生中の曲がない場合はすぐ再生
        if currentTrack == nil {

            let firstItem = queue.removeFirst()

            Task {
                let success = await startTrack(firstItem)

                if success && activeRefillCondition == nil && isShuffle {
                    fillShuffleQueue()
                }
            }
        }
    }

    // キュー内の曲を最前列に移動
    private func moveToFront(_ item: QueueItem) {

        guard let index = queue.firstIndex(where: {
            $0.id == item.id
        }) else {
            return
        }

        var selectedItem = queue.remove(at: index)

        selectedItem.source = .manual

        // キューから通常の曲を選んだ場合は自動補充条件を解除
        activeRefillCondition = nil

        queue.insert(selectedItem, at: 0)

        // 再生中の曲がない場合
        if currentTrack == nil {

            let firstItem = queue.removeFirst()

            Task {
                let success = await startTrack(firstItem)

                if success && activeRefillCondition == nil && isShuffle {
                    fillShuffleQueue()
                }
            }
        }
    }

    // キューの並べ替え
    private func moveQueueItems(
        from source: IndexSet,
        to destination: Int
    ) {
        queue.move(
            fromOffsets: source,
            toOffset: destination
        )
    }

    // キューから曲を削除
    private func deleteQueueItems(at offsets: IndexSet) {
        guard !offsets.isEmpty else { return }

        let conditionPaths = activeRefillCondition?.trackPaths ?? []
        let hadConditionTracksInQueue = queue.contains {
            conditionPaths.contains($0.path)
        }

        queue.remove(atOffsets: offsets)

        // 条件に属するキュー曲をすべて手動削除した場合は自動補充を解除
        let hasConditionTracksRemaining = queue.contains {
            conditionPaths.contains($0.path)
        }

        if hadConditionTracksInQueue && !hasConditionTracksRemaining {
            activeRefillCondition = nil
        }
    }

    // ランダム選曲
    private func fillShuffleQueue() {

        guard isShuffle else {
            return
        }

        // 現在の自動選曲数
        let automaticCount = queue.filter {
            $0.source == .automatic
        }.count

        // 10曲に足りない分だけ補充
        let neededCount = shuffleQueueCount - automaticCount

        guard neededCount > 0 else {
            return
        }

        // 現在のフォルダ内の音楽ファイルを取得
        let candidates = files
            .filter { isMusicFile($0) }
            .map { file in
                QueueItem(
                    file: file,
                    path: makePath(for: file),
                    source: .automatic
                )
            }
            .filter { item in

                // 現在再生中の曲を除外
                item.path != currentTrack?.path

                // キューに存在する曲を除外
                && !queue.contains {
                    $0.path == item.path
                }
            }

        // ランダムに選んで追加
        let selectedItems = Array(
            candidates.shuffled().prefix(neededCount)
        )

        queue.append(contentsOf: selectedItems)
    }

    // シャッフル切り替え
    private func toggleShuffle() {

        isShuffle.toggle()

        // ONにした場合だけ自動補充
        if isShuffle && activeRefillCondition == nil {
            fillShuffleQueue()
        }
    }

    // MARK: - 曲の再生

    // 指定した曲を再生
    private func startTrack(
        _ item: QueueItem,
        recordHistory: Bool = true
    ) async -> Bool {

        do {
            errorMessage = ""

            // 再生するURL
            let musicURL: URL

            // QueueItemのパスを使ってSwiftDataから曲を検索
            let targetPath = item.path

            let descriptor = FetchDescriptor<MusicTrack>(
                predicate: #Predicate { track in
                    track.path == targetPath
                }
            )

            let matchingTrack = try modelContext.fetch(
                descriptor
            ).first

            // ローカル保存済みか確認
            if let track = matchingTrack,
               track.isDownloaded,
               let localFileName = track.localFileName {

                let store = OfflineMusicStore()

                let localURL = try store.localURL(
                    for: localFileName
                )

                // ローカルファイルが実際に存在する場合
                if FileManager.default.fileExists(
                    atPath: localURL.path
                ) {

                    print("ローカル再生: \(track.title)")

                    musicURL = localURL

                } else {

                    // ファイルが消失していた場合は保存状態をリセット
                    print("ローカルファイルが見つかりません。クラウドから再生します")

                    track.isDownloaded = false
                    track.localFileName = nil

                    try? modelContext.save()

                    guard !isOfflineMode else {
                        throw CocoaError(.fileNoSuchFile)
                    }

                    musicURL = try await service.getMusicURL(
                        path: item.path
                    )
                }

            } else {

                // オフライン時はクラウドへのアクセスを試みない
                guard !isOfflineMode else {
                    throw CocoaError(.fileNoSuchFile)
                }

                // 未ダウンロードならクラウドから再生
                print("クラウド再生: \(item.file.name)")

                musicURL = try await service.getMusicURL(
                    path: item.path
                )
            }

            // 正常に取得できた場合だけ履歴に登録
            if recordHistory, let previousTrack = currentTrack {
                playHistory.append(previousTrack)
            }

            player.replaceCurrentItem(
                with: AVPlayerItem(url: musicURL)
            )

            currentTrack = item
            elapsedTime = 0
            playbackDuration = 0
            isSeeking = false

            player.play()
            isPlaying = true
            
            updateNowPlayingInfo()

            return true

        } catch {

            errorMessage = "再生エラー: \(error.localizedDescription)"
            isPlaying = false

            return false
        }
    }

    // 次の曲を再生
    private func playNext(isNaturalEnd: Bool = false) async {

        // 1曲リピートは自然終了時だけ適用
        if isNaturalEnd && repeatMode == .one {

            await player.seek(to: .zero)
            player.play()
            isPlaying = true

            return
        }

        // 全曲リピートの場合、終了した曲をキュー末尾に戻す
        if isNaturalEnd && repeatMode == .all,
           let track = currentTrack,
           !queue.contains(where: { $0.path == track.path }) {

            var repeatedTrack = track
            repeatedTrack.source = .automatic

            queue.append(repeatedTrack)
        }

        // キューが空になった時点で、最後に指定された条件を優先して補充
        if queue.isEmpty {
            if activeRefillCondition != nil {
                refillActiveConditionQueue()
            } else if isShuffle {
                fillShuffleQueue()
            }
        }

        // 次の曲がない場合
        guard !queue.isEmpty else {
            isPlaying = false
            return
        }

        // 最前列の曲を取り出す
        let nextTrack = queue.removeFirst()

        let success = await startTrack(nextTrack)

        if !success {
            queue.insert(nextTrack, at: 0)
            return
        }

        // 通常シャッフルのみ、従来どおり次の曲の再生開始後に補充
        if activeRefillCondition == nil && isShuffle && queue.isEmpty {
            fillShuffleQueue()
        }
    }

    // 前の曲を再生
    private func playPrevious() {

        guard let previousTrack = playHistory.popLast() else {
            return
        }

        // 現在の曲をキューの先頭に戻す
        if let track = currentTrack {
            var item = track
            item.source = .manual

            queue.insert(item, at: 0)
        }

        Task {
            await startTrack(
                previousTrack,
                recordHistory: false
            )
        }
    }

    // 再生・一時停止
    private func togglePlayback() {

        if isPlaying {

            player.pause()
            isPlaying = false

        } else if player.currentItem != nil {

            player.play()
            isPlaying = true
        }

        updateNowPlayingInfo()
    }

    // MARK: - プレイヤー操作画面

    private var playerControls: some View {

        VStack(spacing: 10) {

            Divider()

            HStack(spacing: 16) {

                // 現在の曲
                VStack(alignment: .leading, spacing: 4) {

                    Text(currentTrack?.file.name ?? "再生していません")
                        .font(.subheadline)
                        .lineLimit(1)

                    Text(isPlaying ? "再生中" : "停止中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // 再生画面では楽曲画面へ戻り、それ以外では再生画面を開く
                Button {
                    selectedTab = selectedTab == 1 ? 0 : 1
                } label: {
                    Image(systemName: "list.bullet")
                        .foregroundStyle(.primary)
                        .overlay(alignment: .topTrailing) {
                            if !queue.isEmpty {
                                Circle()
                                    .fill(.blue)
                                    .frame(width: 7, height: 7)
                                    .offset(x: 4, y: -4)
                            }
                        }
                }
                .accessibilityLabel("再生キュー")

                // シャッフル
                Button {
                    toggleShuffle()
                } label: {

                    Image(systemName: "shuffle")
                        .foregroundStyle(
                            isShuffle ? .blue : .secondary
                        )
                }

                // 前の曲
                Button {
                    playPrevious()
                } label: {

                    Image(systemName: "backward.end.fill")
                }
                .disabled(playHistory.isEmpty)

                // 再生・一時停止
                Button {
                    togglePlayback()
                } label: {

                    Image(systemName: isPlaying
                          ? "pause.fill"
                          : "play.fill")
                        .font(.title2)
                }
                .disabled(player.currentItem == nil)

                // 次の曲
                Button {
                    Task {
                        await playNext()
                    }
                } label: {

                    Image(systemName: "forward.end.fill")
                }
                .disabled(queue.isEmpty && !isShuffle)

                // リピート
                Button {

                    switch repeatMode {

                    case .off:
                        repeatMode = .all

                    case .all:
                        repeatMode = .one

                    case .one:
                        repeatMode = .off
                    }

                } label: {

                    Image(systemName: repeatIcon)
                        .foregroundColor(
                            repeatMode == .off ? .secondary : .blue
                        )
                }
            }

            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .background(.regularMaterial)
    }

    // リピートアイコン
    private var repeatIcon: String {

        switch repeatMode {

        case .off:
            return "repeat"

        case .all:
            return "repeat"

        case .one:
            return "repeat.1"
        }
    }
}
