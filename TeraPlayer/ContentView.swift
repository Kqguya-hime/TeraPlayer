import SwiftUI
import AVFoundation
import MediaPlayer
import SwiftData
import Charts
import UniformTypeIdentifiers

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

// 統計の集計期間
private enum StatisticsPeriod: String, CaseIterable, Identifiable {
    case all = "全期間"
    case week = "過去7日"
    case month = "過去1か月"
    case year = "過去1年"

    var id: String { rawValue }

    func startDate(from now: Date = Date()) -> Date? {
        let calendar = Calendar.current

        switch self {
        case .all:
            return nil
        case .week:
            return calendar.date(byAdding: .day, value: -7, to: now)
        case .month:
            return calendar.date(byAdding: .month, value: -1, to: now)
        case .year:
            return calendar.date(byAdding: .year, value: -1, to: now)
        }
    }
}

private struct TrackStatistic: Identifiable {
    let path: String
    let title: String
    let artist: String?
    let playCount: Int
    let listenedSeconds: Double
    let completionCount: Int

    var id: String { path }
}

private struct ArtistStatistic: Identifiable {
    let name: String
    let playCount: Int

    var id: String { name }
}

// キュー内の曲が手動追加か自動選曲かを区別する
enum QueueSource: Equatable {
    case manual
    case automatic
    case artistAlbum
    case shuffle
    case unplayedShuffle
    case playlist
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
    @Query private var playbackHistories: [PlaybackHistory]
    @Query private var playlists: [MusicPlaylist]
    @State private var statisticsPeriod: StatisticsPeriod = .all
    @State private var isPlaylistEditorPresented = false
    @State private var editingPlaylistID: String? = nil
    @State private var playlistNameDraft = ""
    @State private var pendingPlaylistTrackPaths: [String]? = nil
    @State private var isPlaylistTrackPickerPresented = false
    @State private var addingTracksToPlaylistID: String? = nil
    @State private var selectedTrackPathsToAdd: [String] = []
    @State private var playlistTrackSearchField: MusicSearchField = .title
    @State private var playlistTrackSearchText = ""
    @State private var isPlaylistPlaybackSheetPresented = false
    @State private var playlistPlaybackTargetID: String? = nil
    @State private var playlistPlaybackOperation: QueueOperation = .replace
    @State private var playlistPlaybackShuffle = false
    @State private var isPlaylistPlayback = false
    @State private var isNowPlayingPlaylistPickerPresented = false

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

    // OpenList APIトークン（入力値はKeychainへ保存）
    @State private var openListTokenDraft = ""
    @State private var isOpenListTokenConfigured = false
    @State private var openListTokenStatus = ""

    // MP3アップロード
    @State private var isMP3ImporterPresented = false
    @State private var isUploadingMP3 = false
    @State private var uploadProgress = ""
    @State private var uploadFailures: [String] = []

    // MP3楽曲情報編集
    @State private var selectedMP3ForEditing: OpenListFile? = nil
    @State private var isSelectingMP3ForEditing = false

    // プレイヤー
    @State private var player = AVPlayer()
    @State private var isPlaying = false
    @State private var nowPlayingManager = NowPlayingManager()
    @State private var timeObserverToken: Any? = nil
    @State private var elapsedTime: Double = 0
    @State private var playbackDuration: Double = 0
    @State private var isSeeking = false

    // 統計用の現在の再生セッション
    @State private var activePlaybackHistory: PlaybackHistory? = nil
    @State private var lastObservedPlaybackTime: Double? = nil
    @State private var unsavedHistorySeconds: Double = 0
    // 再生設定
    @State private var isShuffle = false
    @State private var isUnplayedShuffle = false
    @State private var normalShuffleNeedsReset = false
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

    private enum ShuffleMode: Equatable {
        case off
        case normal
        case unplayed
    }

    private enum ShuffleScope: String, CaseIterable, Identifiable {
        case trackFolder = "曲のフォルダ"
        case allLibrary = "全ライブラリ"
        var id: String { rawValue }
    }

    @State private var shuffleScope: ShuffleScope = .trackFolder
    @State private var libraryBrowseMode = "曲"
    @State private var selectedArtist: String? = nil
    @State private var selectedAlbum: String? = nil
    @State private var queueTarget: QueueTarget? = nil
    @State private var isQueueTrackListExpanded = false
    @State private var queueShuffle = false
    @State private var queueOperation: QueueOperation = .replace
    @State private var activeRefillCondition: QueueRefillCondition? = nil
    @State private var selectedTab = 0
    @AppStorage("appearanceTheme") private var appearanceTheme = "current"

    var body: some View {
        TabView(selection: $selectedTab) {
            libraryScreen
                .tag(0)

            playbackScreen
                .tag(1)

            managementScreen
                .tag(2)

            playlistScreen
                .tag(3)
        }
        .tabViewStyle(.automatic)
        .toolbar(.hidden, for: .tabBar)
        .preferredColorScheme(appearanceTheme == "light" ? .light : nil)
        .tint(appearanceTheme == "light" ? Color(red: 0.58, green: 0.39, blue: 0.28) : .blue)
        .toolbarBackground(appearanceTheme == "light" ? Color(red: 0.98, green: 0.97, blue: 0.94) : Color.clear, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("画面", selection: $selectedTab) {
                Text("楽曲").tag(0)
                Text("再生").tag(1)
                Text("管理").tag(2)
                Text("プレイリスト").tag(3)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(appearanceTheme == "light" ? Color(red: 0.98, green: 0.97, blue: 0.94) : Color(.systemBackground))
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
            if phase != .active {
                // バックグラウンドへ移る前に再生時間を保存
                checkpointPlaybackSession()
                lastObservedPlaybackTime = nil
            }

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
                HStack(spacing: 8) {
                    if currentPath != "/terabox" && !isOfflineMode {
                        Button {
                            Task { await goToParentFolder() }
                        } label: {
                            Label("上へ", systemImage: "arrow.up")
                        }
                        .buttonStyle(.bordered)
                    }

                    if !isOfflineMode {
                        Button {
                            isSelectingMP3ForEditing.toggle()
                        } label: {
                            Label(
                                isSelectingMP3ForEditing ? "選択をキャンセル" : "楽曲情報編集",
                                systemImage: isSelectingMP3ForEditing ? "xmark" : "pencil"
                            )
                        }
                        .buttonStyle(.bordered)
                        .tint(isSelectingMP3ForEditing ? .orange : .blue)
                    }

                    Spacer(minLength: 4)

                    Button {
                        Task { await loadFiles() }
                    } label: {
                        Label("更新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    startAllLibraryShuffle()
                } label: {
                    Label("全ライブラリ・シャッフル再生", systemImage: "shuffle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)

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
                            } else if isSelectingMP3ForEditing {
                                if file.name.lowercased().hasSuffix(".mp3") && !isOfflineMode {
                                    selectedMP3ForEditing = file
                                    isSelectingMP3ForEditing = false
                                } else {
                                    errorMessage = "楽曲情報を編集できるのはオンラインのMP3ファイルのみです。"
                                }
                            } else if isMusicFile(file) {
                                enqueueOrPlay(file)
                            }
                        } label: {
                            HStack {
                                Image(systemName: file.is_dir ? "folder.fill" : (isSelectingMP3ForEditing ? "pencil" : "music.note"))
                                VStack(alignment: .leading) {
                                    Text(file.name)
                                        .foregroundStyle(.primary)
                                    Text(file.is_dir ? "フォルダ" : "\(file.size) bytes")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if isSelectingMP3ForEditing && !file.is_dir && file.name.lowercased().hasSuffix(".mp3") {
                                    Image(systemName: "pencil.circle.fill")
                                        .foregroundStyle(.blue)
                                } else if isMusicFile(file) {
                                    Image(systemName: "text.badge.plus")
                                        .foregroundStyle(appearanceTheme == "light" ? Color(red: 0.58, green: 0.39, blue: 0.28) : .blue)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
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
        }
        .sheet(item: $queueTarget) { target in
            queueCreationSheet(for: target)
        }
        .sheet(item: $selectedMP3ForEditing) { file in
            MP3MetadataEditorSheet(
                fileName: file.name,
                loadMetadata: {
                    try await loadCloudMP3Metadata(path: makePath(for: file))
                },
                saveMetadata: { title, artist, album in
                    try await saveCloudMP3Metadata(
                        path: makePath(for: file),
                        title: title,
                        artist: artist,
                        album: album
                    )
                }
            )
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

    // MARK: - プレイリスト画面

    private var playlistScreen: some View {
        NavigationStack {
            List {
                Section("自作プレイリスト") {
                    Button {
                        editingPlaylistID = nil
                        playlistNameDraft = ""
                        pendingPlaylistTrackPaths = nil
                        isPlaylistEditorPresented = true
                    } label: {
                        Label("新規プレイリストを作成", systemImage: "plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderedProminent)

                    if playlists.isEmpty {
                        Text("プレイリストはまだありません")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(playlists.sorted { $0.createdAt < $1.createdAt }) { playlist in
                        NavigationLink {
                            playlistDetailScreen(playlist)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(playlist.name)
                                    .foregroundStyle(.primary)
                                Text("\(playlist.trackPaths.count)曲")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                modelContext.delete(playlist)
                                try? modelContext.save()
                            } label: {
                                Label("削除", systemImage: "trash")
                            }

                            Button {
                                editingPlaylistID = playlist.id
                                playlistNameDraft = playlist.name
                                pendingPlaylistTrackPaths = nil
                                isPlaylistEditorPresented = true
                            } label: {
                                Label("名前変更", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
                }

                Section("パーソナライズ") {
                    NavigationLink {
                        personalizedPlaylistDetailScreen
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("よく聴く曲")
                                .foregroundStyle(.primary)
                            Text("再生回数・完了数・総再生時間の順で最大30曲")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(personalizedTrackStatistics.count)曲")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("プレイリスト")
        }
        .sheet(isPresented: $isPlaylistEditorPresented) {
            playlistEditorSheet
        }
    }

    private var playlistEditorSheet: some View {
        NavigationStack {
            Form {
                Section("プレイリスト名") {
                    TextField("名前を入力", text: $playlistNameDraft)
                        .textInputAutocapitalization(.words)
                }
            }
            .navigationTitle(editingPlaylistID == nil ? "新規プレイリスト" : "名前を変更")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("キャンセル") {
                        isPlaylistEditorPresented = false
                        pendingPlaylistTrackPaths = nil
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        savePlaylistName()
                    }
                    .disabled(playlistNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func savePlaylistName() {
        let name = playlistNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        if let editingPlaylistID,
           let playlist = playlists.first(where: { $0.id == editingPlaylistID }) {
            playlist.name = name
            playlist.updatedAt = Date()
        } else {
            modelContext.insert(
                MusicPlaylist(
                    name: name,
                    trackPaths: pendingPlaylistTrackPaths ?? []
                )
            )
        }

        do {
            try modelContext.save()
            isPlaylistEditorPresented = false
            editingPlaylistID = nil
            playlistNameDraft = ""
            pendingPlaylistTrackPaths = nil
        } catch {
            errorMessage = "プレイリストを保存できませんでした: \(error.localizedDescription)"
        }
    }

    private var personalizedPlaylistDetailScreen: some View {
        List {
            Section {
                Button {
                    editingPlaylistID = nil
                    playlistNameDraft = "よく聴く曲"
                    pendingPlaylistTrackPaths = personalizedTrackStatistics.map(\.path)
                    isPlaylistEditorPresented = true
                } label: {
                    Label("自作プレイリストにコピー", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .disabled(personalizedTrackStatistics.isEmpty)

                Text("全期間の再生履歴をもとに自動更新されます。コピーすると、その時点の曲構成で固定されます。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("ランキング（最大30曲）") {
                if personalizedTrackStatistics.isEmpty {
                    Text("再生履歴がありません")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(personalizedTrackStatistics.indices, id: \.self) { index in
                        let item = personalizedTrackStatistics[index]
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(index + 1). \(item.title)")
                                    .lineLimit(1)
                                Spacer()
                                Text("\(item.playCount)回")
                                    .monospacedDigit()
                            }

                            if let artist = item.artist, !artist.isEmpty {
                                Text(artist)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            HStack(spacing: 14) {
                                Label("完了 \(item.completionCount)回", systemImage: "checkmark.circle")
                                Label(formattedListeningTime(item.listenedSeconds), systemImage: "clock")
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .navigationTitle("よく聴く曲")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func playlistDetailScreen(_ playlist: MusicPlaylist) -> some View {
        List {
            Section {
                HStack {
                    Button {
                        playlistPlaybackTargetID = playlist.id
                        playlistPlaybackOperation = .replace
                        playlistPlaybackShuffle = false
                        isPlaylistPlaybackSheetPresented = true
                    } label: {
                        Label("プレイリストを再生", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)

                    Spacer()
                    EditButton()
                    Spacer()
                    Button {
                        addingTracksToPlaylistID = playlist.id
                        selectedTrackPathsToAdd = []
                        playlistTrackSearchField = .title
                        playlistTrackSearchText = ""
                        isPlaylistTrackPickerPresented = true
                    } label: {
                        Label("曲を追加", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                }

                Text("曲一覧（\(playlist.trackPaths.count)曲）")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if playlist.trackPaths.isEmpty {
                    Text("曲が登録されていません")
                        .foregroundStyle(.secondary)
                }

                ForEach(playlist.trackPaths, id: \.self) { path in
                    if let track = musicTracks.first(where: { $0.path == path }) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.title)
                            if let artist = track.artist, !artist.isEmpty {
                                Text(artist)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("ライブラリに存在しない曲")
                            .foregroundStyle(.secondary)
                    }
                }
                .onMove { source, destination in
                    movePlaylistTracks(
                        in: playlist,
                        from: source,
                        to: destination
                    )
                }
                .onDelete { offsets in
                    removePlaylistTracks(
                        from: playlist,
                        at: offsets
                    )
                }
            }
        }
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isPlaylistTrackPickerPresented) {
            playlistTrackPickerSheet
        }
        .sheet(isPresented: $isPlaylistPlaybackSheetPresented) {
            playlistPlaybackSheet
        }
    }

    private var playlistPlaybackSheet: some View {
        NavigationStack {
            Form {
                Section("再生順") {
                    Picker("シャッフル", selection: $playlistPlaybackShuffle) {
                        Text("OFF（登録順）").tag(false)
                        Text("ON（ランダム）").tag(true)
                    }
                    .pickerStyle(.segmented)
                }

                Section("キュー操作") {
                    Picker("操作", selection: $playlistPlaybackOperation) {
                        ForEach(QueueOperation.allCases) { operation in
                            Text(operation.rawValue).tag(operation)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(playlistPlaybackOperation == .replace
                         ? "現在再生中の曲は維持し、次の再生キューを置き換えます。"
                         : "現在のキューを維持し、プレイリストの曲を末尾に追加します。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("プレイリスト再生")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("キャンセル") {
                        isPlaylistPlaybackSheetPresented = false
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("再生") {
                        startPlaylistPlayback()
                    }
                    .disabled(playlistPlaybackTargetID == nil)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func startPlaylistPlayback() {
        guard let playlistID = playlistPlaybackTargetID,
              let playlist = playlists.first(where: { $0.id == playlistID }) else {
            return
        }

        let existingPaths = Set(queue.map(\.path))
        var candidatePaths = playlist.trackPaths.filter { path in
            path != currentTrack?.path
        }

        if playlistPlaybackOperation == .append {
            candidatePaths.removeAll { existingPaths.contains($0) }
        }

        // ライブラリから消えた曲は再生対象に含めない
        let tracksByPath = Dictionary(uniqueKeysWithValues: musicTracks.map { ($0.path, $0) })
        candidatePaths = candidatePaths.filter { tracksByPath[$0] != nil }

        // 同一プレイリスト内の重複パスも除外
        var seenPaths = Set<String>()
        candidatePaths = candidatePaths.filter { seenPaths.insert($0).inserted }

        if playlistPlaybackShuffle {
            candidatePaths.shuffle()
        }

        let newItems = candidatePaths.compactMap { path -> QueueItem? in
            guard let track = tracksByPath[path] else { return nil }
            return QueueItem(
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
                source: .playlist
            )
        }

        guard !newItems.isEmpty else {
            isPlaylistPlaybackSheetPresented = false
            playlistPlaybackTargetID = nil
            return
        }

        activeRefillCondition = nil
        isPlaylistPlayback = true

        switch playlistPlaybackOperation {
        case .replace:
            queue = newItems
        case .append:
            queue.append(contentsOf: newItems)
        }

        isPlaylistPlaybackSheetPresented = false
        playlistPlaybackTargetID = nil

        if currentTrack == nil, !queue.isEmpty {
            let firstItem = queue.removeFirst()
            Task {
                let success = await startTrack(firstItem)
                if !success {
                    queue.insert(firstItem, at: 0)
                }
            }
        }
    }

    private var playlistTrackPickerSheet: some View {
        NavigationStack {
            List {
                Section {
                    Picker("検索対象", selection: $playlistTrackSearchField) {
                        ForEach(MusicSearchField.allCases) { field in
                            Text(field.rawValue).tag(field)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField(playlistTrackSearchField.rawValue + "で検索", text: $playlistTrackSearchText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if !playlistTrackSearchText.isEmpty {
                            Button {
                                playlistTrackSearchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if let playlist = playlists.first(where: {
                    $0.id == addingTracksToPlaylistID
                }) {
                    ForEach(
                        musicTracks
                            .filter { track in
                                let keyword = playlistTrackSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !keyword.isEmpty else { return true }
                                let target: String?
                                switch playlistTrackSearchField {
                                case .title: target = track.title
                                case .artist: target = track.artist
                                case .album: target = track.album
                                }
                                return target?.localizedCaseInsensitiveContains(keyword) ?? false
                            }
                            .sorted {
                                $0.title.localizedStandardCompare($1.title) == .orderedAscending
                            },
                        id: \.path
                    ) { track in
                        let alreadyAdded = playlist.trackPaths.contains(track.path)
                        let isSelected = selectedTrackPathsToAdd.contains(track.path)

                        Button {
                            guard !alreadyAdded else { return }
                            if isSelected {
                                selectedTrackPathsToAdd.removeAll { $0 == track.path }
                            } else {
                                selectedTrackPathsToAdd.append(track.path)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(track.title)
                                        .foregroundStyle(.primary)
                                    if let artist = track.artist, !artist.isEmpty {
                                        Text(artist)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if alreadyAdded {
                                    Text("登録済み")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else if isSelected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.blue)
                                } else {
                                    Image(systemName: "circle")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(alreadyAdded)
                    }
                } else {
                    Text("プレイリストが見つかりません")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("曲を追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("キャンセル") {
                        isPlaylistTrackPickerPresented = false
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("追加（\(selectedTrackPathsToAdd.count)曲）") {
                        addSelectedTracksToPlaylist()
                    }
                    .disabled(selectedTrackPathsToAdd.isEmpty)
                }
            }
        }
    }

    private func addSelectedTracksToPlaylist() {
        guard let playlist = playlists.first(where: {
            $0.id == addingTracksToPlaylistID
        }) else {
            return
        }

        let existingPaths = Set(playlist.trackPaths)
        let newPaths = selectedTrackPathsToAdd.filter {
            !existingPaths.contains($0)
        }

        playlist.trackPaths.append(contentsOf: newPaths)
        playlist.updatedAt = Date()

        do {
            try modelContext.save()
            isPlaylistTrackPickerPresented = false
            selectedTrackPathsToAdd = []
            addingTracksToPlaylistID = nil
        } catch {
            errorMessage = "曲を追加できませんでした: \(error.localizedDescription)"
        }
    }

    private func removePlaylistTracks(
        from playlist: MusicPlaylist,
        at offsets: IndexSet
    ) {
        playlist.trackPaths.remove(atOffsets: offsets)
        playlist.updatedAt = Date()
        try? modelContext.save()
    }

    private func movePlaylistTracks(
        in playlist: MusicPlaylist,
        from source: IndexSet,
        to destination: Int
    ) {
        playlist.trackPaths.move(
            fromOffsets: source,
            toOffset: destination
        )
        playlist.updatedAt = Date()
        try? modelContext.save()
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
                                .background(appearanceTheme == "light" ? Color(red: 0.93, green: 0.89, blue: 0.82) : Color(.quaternarySystemFill))
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
                                .disabled(queue.isEmpty && !isShuffle && !isUnplayedShuffle && activeRefillCondition == nil)
                                .accessibilityLabel("次の曲")
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)

                            HStack {
                                Menu {
                                    Button {
                                        setShuffleScope(.trackFolder)
                                    } label: {
                                        if shuffleScope == .trackFolder {
                                            Label("再生中の曲のフォルダ", systemImage: "checkmark")
                                        } else {
                                            Text("再生中の曲のフォルダ")
                                        }
                                    }
                                    Button {
                                        setShuffleScope(.allLibrary)
                                    } label: {
                                        if shuffleScope == .allLibrary {
                                            Label("全ライブラリ", systemImage: "checkmark")
                                        } else {
                                            Text("全ライブラリ")
                                        }
                                    }
                                } label: {
                                    Label(shuffleScopeTitle, systemImage: "folder")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(shuffleScopeColor)
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 5)
                                        .background(shuffleScopeColor.opacity(0.14), in: Capsule())
                                }

                                Menu {
                                    Button("OFF") { setShuffleMode(.off) }
                                    Button("通常シャッフル") { setShuffleMode(.normal) }
                                    Button("未再生シャッフル") { setShuffleMode(.unplayed) }
                                } label: {
                                    Label(shuffleModeTitle, systemImage: "shuffle")
                                        .foregroundStyle(isShuffle || isUnplayedShuffle ? .blue : .secondary)
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

                            Button {
                                isNowPlayingPlaylistPickerPresented = true
                            } label: {
                                Label("プレイリストに追加", systemImage: "plus")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(currentTrack == nil)
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

                Section {
                    HStack {
                        Text("再生キュー（\(queue.count)曲）")
                            .font(.headline)
                        Spacer()
                        EditButton()
                    }

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
        }
        .sheet(isPresented: $isNowPlayingPlaylistPickerPresented) {
            nowPlayingPlaylistPickerSheet
        }
    }

    private var nowPlayingPlaylistPickerSheet: some View {
        NavigationStack {
            List {
                if let track = currentTrack {
                    Section("追加する楽曲") {
                        Text(musicTracks.first(where: { $0.path == track.path })?.title
                             ?? (track.file.name as NSString).deletingPathExtension)
                            .font(.headline)
                        Text(musicTracks.first(where: { $0.path == track.path })?.artist
                             ?? "アーティスト情報なし")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section("追加先のプレイリスト") {
                        if playlists.isEmpty {
                            ContentUnavailableView(
                                "プレイリストがありません",
                                systemImage: "music.note.list",
                                description: Text("先にプレイリスト画面で作成してください")
                            )
                        } else {
                            ForEach(playlists.sorted { $0.createdAt < $1.createdAt }) { playlist in
                                let alreadyAdded = playlist.trackPaths.contains(track.path)
                                Button {
                                    guard !alreadyAdded else { return }
                                    playlist.trackPaths.append(track.path)
                                    playlist.updatedAt = Date()
                                    do {
                                        try modelContext.save()
                                    } catch {
                                        errorMessage = "プレイリストに追加できませんでした: \\(error.localizedDescription)"
                                    }
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(playlist.name)
                                                .foregroundStyle(.primary)
                                            Text("\\(playlist.trackPaths.count)曲")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        if alreadyAdded {
                                            Label("追加済み", systemImage: "checkmark.circle.fill")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        } else {
                                            Image(systemName: "plus.circle")
                                                .foregroundStyle(.blue)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .disabled(alreadyAdded)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "再生していません",
                        systemImage: "music.note",
                        description: Text("楽曲を再生してから操作してください")
                    )
                }
            }
            .navigationTitle("プレイリストに追加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") {
                        isNowPlayingPlaylistPickerPresented = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var managementScreen: some View {
        NavigationStack {
            List {
                Section("外観設定") {
                    Picker("デザイン", selection: $appearanceTheme) {
                        Text("現在のデザイン").tag("current")
                        Text("ライトテーマ").tag("light")
                    }
                    .pickerStyle(.segmented)

                    Text(appearanceTheme == "light"
                         ? "白を基調とした明るい配色を使用します。"
                         : "現在の表示設定を維持します。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("OpenList接続") {
                    LabeledContent(
                        "APIトークン",
                        value: isOpenListTokenConfigured ? "登録済み" : "未登録"
                    )

                    SecureField("新しいAPIトークンを入力", text: $openListTokenDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button("トークンを保存") {
                        saveOpenListToken()
                    }
                    .disabled(openListTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("保存済みトークンを削除", role: .destructive) {
                        deleteOpenListToken()
                    }
                    .disabled(!isOpenListTokenConfigured)

                    if !openListTokenStatus.isEmpty {
                        Text(openListTokenStatus)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("MP3アップロード") {
                    Button {
                        isMP3ImporterPresented = true
                    } label: {
                        Label("MP3を選択してアップロード", systemImage: "arrow.up.doc")
                    }
                    .disabled(isUploadingMP3 || isOfflineMode)

                    Text("保存先：TeraPlayer Upload")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if isUploadingMP3 {
                        ProgressView(uploadProgress)
                    } else if !uploadProgress.isEmpty {
                        Text(uploadProgress)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(Array(uploadFailures.enumerated()), id: \.offset) { _, failure in
                        Text(failure)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section("再生統計") {
                    NavigationLink {
                        statisticsScreen
                    } label: {
                        Label("再生統計を見る", systemImage: "chart.bar.xaxis")
                    }
                }

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
            .fileImporter(
                isPresented: $isMP3ImporterPresented,
                allowedContentTypes: [UTType(filenameExtension: "mp3") ?? .audio],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    Task {
                        await uploadSelectedMP3Files(urls)
                    }
                case .failure(let error):
                    uploadProgress = "ファイル選択エラー：\(error.localizedDescription)"
                }
            }
            .onAppear {
                loadOpenListTokenStatus()
            }
        }
    }

    private func uploadSelectedMP3Files(_ urls: [URL]) async {
        guard !isUploadingMP3 else { return }

        let mp3URLs = urls.filter {
            $0.pathExtension.lowercased() == "mp3"
        }

        guard !mp3URLs.isEmpty else {
            uploadProgress = "MP3ファイルを選択してください。"
            return
        }

        isUploadingMP3 = true
        uploadProgress = "アップロード準備中..."
        uploadFailures = []

        defer {
            isUploadingMP3 = false
        }

        let uploader = OpenListUploadService()
        var succeeded = 0

        for (index, url) in mp3URLs.enumerated() {
            uploadProgress = "\(index + 1) / \(mp3URLs.count) 曲をアップロード中..."

            let hasAccess = url.startAccessingSecurityScopedResource()

            do {
                try await uploader.upload(fileURL: url)
                succeeded += 1
            } catch {
                uploadFailures.append(
                    "\(url.lastPathComponent)：\(error.localizedDescription)"
                )
            }

            if hasAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        uploadProgress = "\(succeeded) / \(mp3URLs.count) 曲のアップロードが完了しました。"

        if succeeded > 0 {
            await scanLibrary()
            await loadFiles()
        }
    }

    private func loadOpenListTokenStatus() {
        do {
            isOpenListTokenConfigured = try OpenListTokenStore.load()?.isEmpty == false
            openListTokenStatus = isOpenListTokenConfigured
                ? "トークンはこの端末のKeychainに保存されています。"
                : "トークンを登録してください。"
        } catch {
            isOpenListTokenConfigured = false
            openListTokenStatus = "Keychainを読み取れませんでした: \(error.localizedDescription)"
        }
    }

    private func saveOpenListToken() {
        let token = openListTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }

        do {
            try OpenListTokenStore.save(token)
            openListTokenDraft = ""
            isOpenListTokenConfigured = true
            openListTokenStatus = "トークンを端末内のKeychainに保存しました。"
        } catch {
            openListTokenStatus = "トークンを保存できませんでした: \(error.localizedDescription)"
        }
    }

    private func deleteOpenListToken() {
        do {
            try OpenListTokenStore.delete()
            openListTokenDraft = ""
            isOpenListTokenConfigured = false
            openListTokenStatus = "保存済みトークンを削除しました。"
        } catch {
            openListTokenStatus = "トークンを削除できませんでした: \(error.localizedDescription)"
        }
    }

    // MARK: - 再生統計

    private var statisticsScreen: some View {
        List {
            Section {
                Picker("集計期間", selection: $statisticsPeriod) {
                    ForEach(StatisticsPeriod.allCases) { period in
                        Text(period.rawValue).tag(period)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("再生回数 TOP 10") {
                if trackStatistics.isEmpty {
                    ContentUnavailableView(
                        "再生履歴がありません",
                        systemImage: "chart.bar",
                        description: Text("曲を再生すると、ここに統計が表示されます")
                    )
                } else {
                    Chart(trackStatistics) { item in
                        BarMark(
                            x: .value("再生回数", item.playCount),
                            y: .value("楽曲", item.title)
                        )
                        .foregroundStyle(appearanceTheme == "light" ? Color(red: 0.68, green: 0.49, blue: 0.36) : .blue)
                    }
                    .chartXAxisLabel("再生回数")
                    .frame(height: CGFloat(max(trackStatistics.count * 34, 180)))

                    ForEach(trackStatistics.indices, id: \.self) { index in
                        let item = trackStatistics[index]

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(index + 1). \(item.title)")
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(item.playCount)回")
                                    .font(.subheadline.monospacedDigit())
                            }

                            if let artist = item.artist, !artist.isEmpty {
                                Text(artist)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            HStack(spacing: 14) {
                                Label(
                                    formattedListeningTime(item.listenedSeconds),
                                    systemImage: "clock"
                                )
                                Label(
                                    "完了 \(item.completionCount)回",
                                    systemImage: "checkmark.circle"
                                )
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }

            Section("アーティスト再生ランキング TOP 10") {
                if artistStatistics.isEmpty {
                    Text("アーティスト情報のある再生履歴がありません")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(artistStatistics.indices, id: \.self) { index in
                        let item = artistStatistics[index]

                        HStack {
                            Text("\(index + 1).")
                                .foregroundStyle(.secondary)
                                .frame(width: 28, alignment: .leading)
                            Text(item.name)
                                .lineLimit(1)
                            Spacer()
                            Text("\(item.playCount)回")
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .navigationTitle("再生統計")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var filteredPlaybackHistories: [PlaybackHistory] {
        guard let startDate = statisticsPeriod.startDate() else {
            return playbackHistories
        }

        return playbackHistories.filter { $0.startedAt >= startDate }
    }

    private var trackStatistics: [TrackStatistic] {
        let tracksByPath = Dictionary(
            musicTracks.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let grouped = Dictionary(grouping: filteredPlaybackHistories, by: \.trackPath)

        return grouped.compactMap { path, histories in
            guard let track = tracksByPath[path] else { return nil }

            return TrackStatistic(
                path: path,
                title: track.title,
                artist: track.artist,
                playCount: histories.count,
                listenedSeconds: histories.reduce(0) { $0 + $1.listenedSeconds },
                completionCount: histories.filter(\.completed).count
            )
        }
        .sorted {
            if $0.playCount != $1.playCount {
                return $0.playCount > $1.playCount
            }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        .prefix(10)
        .map { $0 }
    }

    // 全期間の再生統計から「よく聴く曲」上位30曲を作成する
    private var personalizedTrackStatistics: [TrackStatistic] {
        let tracksByPath = Dictionary(
            musicTracks.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let grouped = Dictionary(grouping: playbackHistories, by: \.trackPath)

        return grouped.compactMap { path, histories in
            guard let track = tracksByPath[path], !histories.isEmpty else {
                return nil
            }

            return TrackStatistic(
                path: path,
                title: track.title,
                artist: track.artist,
                playCount: histories.count,
                listenedSeconds: histories.reduce(0) { $0 + $1.listenedSeconds },
                completionCount: histories.filter(\.completed).count
            )
        }
        .sorted {
            if $0.playCount != $1.playCount {
                return $0.playCount > $1.playCount
            }
            if $0.completionCount != $1.completionCount {
                return $0.completionCount > $1.completionCount
            }
            if $0.listenedSeconds != $1.listenedSeconds {
                return $0.listenedSeconds > $1.listenedSeconds
            }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        .prefix(30)
        .map { $0 }
    }

    private var artistStatistics: [ArtistStatistic] {
        let tracksByPath = Dictionary(
            musicTracks.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var counts: [String: Int] = [:]

        for history in filteredPlaybackHistories {
            guard let artist = tracksByPath[history.trackPath]?.artist?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !artist.isEmpty else {
                continue
            }

            counts[artist, default: 0] += 1
        }

        return counts.map {
            ArtistStatistic(name: $0.key, playCount: $0.value)
        }
        .sorted {
            if $0.playCount != $1.playCount {
                return $0.playCount > $1.playCount
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        .prefix(10)
        .map { $0 }
    }

    private func formattedListeningTime(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60

        if hours > 0 {
            return "\(hours)時間\(minutes)分"
        }
        return "\(minutes)分"
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

                // ライブラリから削除された曲の再生統計も削除
                let deletedPath = oldTrack.path
                let historyDescriptor = FetchDescriptor<PlaybackHistory>(
                    predicate: #Predicate { history in
                        history.trackPath == deletedPath
                    }
                )

                if let histories = try? syncContext.fetch(historyDescriptor) {
                    for history in histories {
                        syncContext.delete(history)
                    }
                }

                // 削除された曲をすべての自作プレイリストから除外
                for playlist in playlists where playlist.trackPaths.contains(deletedPath) {
                    playlist.trackPaths.removeAll { $0 == deletedPath }
                    playlist.updatedAt = Date()
                }

                // 削除対象が現在の再生セッションなら、以後の記録を停止
                if activePlaybackHistory?.trackPath == deletedPath {
                    activePlaybackHistory = nil
                    lastObservedPlaybackTime = nil
                    unsavedHistorySeconds = 0
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

                    // 実際に再生していた時間だけを加算する
                    recordPlaybackProgress(at: seconds)

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

        // 起動処理・Wi-Fi検知・画面更新による同時取得を防ぐ
        guard !isLoading else {
            print("ライブラリ取得をスキップ：別の取得処理が実行中")
            return
        }

        isLoading = true
        errorMessage = ""

        defer {
            isLoading = false
        }

        do {
            let loadedFiles = try await service.getFiles(path: currentPath)
            files = loadedFiles

            if isOfflineMode {
                libraryScanStatus = "オンラインライブラリに再接続しました"
            }

            isOfflineMode = false

        } catch {
            isOfflineMode = true
            files = makeOfflineFiles()
            libraryScanStatus = "オフラインモード：保存済み \(files.count) 曲"
            errorMessage = "OpenList接続エラー：\(error.localizedDescription)"
            print("OpenList接続エラー: \(String(reflecting: error))")
        }
    }

    // オフライン保存済みファイルが存在すれば、クラウドから再取得せず利用する。
    private func offlineMP3Source(path: String) throws -> (MusicTrack?, URL?) {
        let descriptor = FetchDescriptor<MusicTrack>(
            predicate: #Predicate { $0.path == path }
        )
        let track = try modelContext.fetch(descriptor).first

        guard let track,
              track.isDownloaded,
              let localFileName = track.localFileName else {
            return (track, nil)
        }

        let store = OfflineMusicStore()
        guard try store.fileExists(localFileName) else {
            return (track, nil)
        }

        return (track, try store.localURL(for: localFileName))
    }

    // クラウドからMP3を取得し、TagLibが扱いやすい一時的な.mp3ファイルにする。
    private func downloadCloudMP3ToTemporaryFile(path: String) async throws -> URL {
        let remoteURL = try await service.getMusicURL(path: path)
        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 1800

        let (downloadURL, response) = try await OpenListNetworkSession.shared.download(
            for: request
        )

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            try? FileManager.default.removeItem(at: downloadURL)
            throw URLError(.badServerResponse)
        }

        let temporaryMP3URL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp3")

        do {
            try FileManager.default.copyItem(at: downloadURL, to: temporaryMP3URL)
            try? FileManager.default.removeItem(at: downloadURL)
            return temporaryMP3URL
        } catch {
            try? FileManager.default.removeItem(at: downloadURL)
            try? FileManager.default.removeItem(at: temporaryMP3URL)
            throw error
        }
    }

    // MP3のタグを読み込む。オフライン保存済みならローカルファイルを優先する。
    private func loadCloudMP3Metadata(path: String) async throws -> MusicTagMetadata {
        let (_, localURL) = try offlineMP3Source(path: path)

        if let localURL {
            return try MusicTagService().readMetadata(from: localURL)
        }

        let temporaryMP3URL = try await downloadCloudMP3ToTemporaryFile(path: path)
        defer { try? FileManager.default.removeItem(at: temporaryMP3URL) }

        return try MusicTagService().readMetadata(from: temporaryMP3URL)
    }

    // 編集後のMP3をクラウドへ反映し、オフライン保存済み音源も同時に更新する。
    private func saveCloudMP3Metadata(
        path: String,
        title: String,
        artist: String,
        album: String
    ) async throws {
        let (track, localURL) = try offlineMP3Source(path: path)
        let sourceMP3URL: URL
        let sourceIsTemporary: Bool

        if let localURL {
            // 端末に保存済みなら、そのファイルを編集元にする。
            sourceMP3URL = localURL
            sourceIsTemporary = false
        } else {
            sourceMP3URL = try await downloadCloudMP3ToTemporaryFile(path: path)
            sourceIsTemporary = true
        }

        defer {
            if sourceIsTemporary {
                try? FileManager.default.removeItem(at: sourceMP3URL)
            }
        }

        let editedURL = try MusicTagService().makeEditedCopy(
            of: sourceMP3URL,
            title: title,
            artist: artist,
            album: album
        )
        defer { try? FileManager.default.removeItem(at: editedURL) }

        let attributes = try FileManager.default.attributesOfItem(atPath: editedURL.path)
        let updatedFileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0

        // クラウドへの置き換えが成功するまでは元ファイルを変更しない。
        try await OpenListUploadService().replace(
            fileURL: editedURL,
            remotePath: path
        )

        // クラウド更新成功後、SwiftDataとオフライン保存ファイルを同期する。
        if let track {
            track.title = title
            track.artist = artist.isEmpty ? nil : artist
            track.album = album.isEmpty ? nil : album
            track.fileSize = updatedFileSize

            // オフライン保存済みの場合だけ、既存の保存名を維持して内容を置き換える。
            if track.isDownloaded, let localFileName = track.localFileName {
                do {
                    try OfflineMusicStore().replaceDownloadedFile(
                        from: editedURL,
                        localFileName: localFileName
                    )
                    track.isDownloaded = true
                } catch {
                    // クラウド側は更新済み。古いローカル音源は誤再生させない。
                    print("オフライン音源の更新に失敗: \(error.localizedDescription)")
                    try? OfflineMusicStore().deleteFile(localFileName)
                    track.isDownloaded = false
                    track.localFileName = nil
                }
            }

            try modelContext.save()
        }

        await loadFiles()
    }

    // フォルダを開く
    private func openFolder(_ folder: OpenListFile) async {

        currentPath = makePath(for: folder)

        await loadFiles()

        // シャッフル中かつキューが空なら新しいフォルダから補充
        if activeRefillCondition == nil && queue.isEmpty {
            fillActiveShuffleQueue()
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

        if activeRefillCondition == nil && queue.isEmpty {
            fillActiveShuffleQueue()
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
        isPlaylistPlayback = false
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
                source: .artistAlbum
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

        // 通常の曲選択ではプレイリスト再生・アーティスト／アルバムの自動補充を解除
        isPlaylistPlayback = false
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

                if success && activeRefillCondition == nil {
                    fillActiveShuffleQueue()
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

        let selectedItem = queue.remove(at: index)

        // キューから曲を選んだ場合は自動補充条件を解除するが、再生元は保持する
        isPlaylistPlayback = false
        activeRefillCondition = nil

        queue.insert(selectedItem, at: 0)

        // 再生中の曲がない場合
        if currentTrack == nil {

            let firstItem = queue.removeFirst()

            Task {
                let success = await startTrack(firstItem)

                if success && activeRefillCondition == nil {
                    fillActiveShuffleQueue()
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

    // シャッフル対象の楽曲をSwiftDataから取得する
    private var availableShuffleTracks: [MusicTrack] {
        if isOfflineMode {
            return musicTracks.filter { $0.isDownloaded && $0.localFileName != nil }
        }
        return musicTracks
    }

    private var shuffleCandidateTracks: [MusicTrack] {
        switch shuffleScope {
        case .allLibrary:
            return availableShuffleTracks
        case .trackFolder:
            let folderPath: String
            if let currentTrack {
                folderPath = (currentTrack.path as NSString).deletingLastPathComponent
            } else {
                folderPath = currentPath
            }
            return availableShuffleTracks.filter {
                (($0.path as NSString).deletingLastPathComponent) == folderPath
            }
        }
    }

    private func queueItem(for track: MusicTrack, source: QueueSource) -> QueueItem {
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
            source: source
        )
    }

    // ランダム選曲
    private func fillShuffleQueue() {
        guard isShuffle else { return }
        let automaticCount = queue.filter { $0.source == .shuffle }.count
        let neededCount = shuffleQueueCount - automaticCount
        guard neededCount > 0 else { return }

        let excludedPaths = Set(queue.map(\.path)).union(
            currentTrack.map { [$0.path] } ?? []
        )
        let candidates = shuffleCandidateTracks.filter {
            !excludedPaths.contains($0.path)
        }
        let items = candidates.shuffled()
            .prefix(neededCount)
            .map { queueItem(for: $0, source: .shuffle) }
        queue.append(contentsOf: items)
    }

    // 全ライブラリからシャッフル再生を開始する
    private func startAllLibraryShuffle() {
        let availableTracks = isOfflineMode
            ? musicTracks.filter { $0.isDownloaded && $0.localFileName != nil }
            : musicTracks
        guard let selectedTrack = availableTracks.randomElement() else {
            errorMessage = "ライブラリに再生できる楽曲がありません"
            return
        }

        shuffleScope = .allLibrary
        isPlaylistPlayback = false
        activeRefillCondition = nil
        queue.removeAll()

        isShuffle = true
        isUnplayedShuffle = false
        normalShuffleNeedsReset = true

        let item = queueItem(for: selectedTrack, source: .shuffle)
        Task {
            let success = await startTrack(item)
            if success { fillActiveShuffleQueue() }
        }
    }

    private var shuffleScopeTitle: String {
        shuffleScope.rawValue
    }

    private var shuffleScopeColor: Color {
        shuffleScope == .allLibrary ? .purple : .blue
    }

    // 再生範囲を切り替える。すでにキューに入っている曲は維持し、
    // 次回以降の自動補充から新しい範囲を適用する。
    private func setShuffleScope(_ scope: ShuffleScope) {
        guard shuffleScope != scope else { return }
        shuffleScope = scope
        if isShuffle { normalShuffleNeedsReset = true }
    }

    // 選択中のシャッフル方式
    private var shuffleModeTitle: String {
        if isUnplayedShuffle { return "未再生シャッフル" }
        if isShuffle { return "通常シャッフル" }
        return "シャッフル OFF"
    }

    // シャッフル方式を切り替える
    private func setShuffleMode(_ mode: ShuffleMode) {
        let wasNormalShuffle = isShuffle
        let wasUnplayedShuffle = isUnplayedShuffle

        switch mode {
        case .off:
            isShuffle = false
            isUnplayedShuffle = false
            normalShuffleNeedsReset = false

        case .normal:
            isShuffle = true
            isUnplayedShuffle = false
            if !wasNormalShuffle {
                normalShuffleNeedsReset = true
            }

        case .unplayed:
            isShuffle = false
            isUnplayedShuffle = true
            normalShuffleNeedsReset = false
        }

        // 別方式の自動選曲だけを取り除き、手動キューやプレイリスト曲は維持する
        if mode != .off && (wasNormalShuffle != isShuffle || wasUnplayedShuffle != isUnplayedShuffle) {
            queue.removeAll { $0.source == .shuffle || $0.source == .unplayedShuffle }
        }

        if activeRefillCondition == nil && !isPlaylistPlayback {
            fillActiveShuffleQueue()
        }
    }

    // 現在有効なシャッフル方式に応じてキューを補充する
    private func fillActiveShuffleQueue() {
        guard activeRefillCondition == nil, !isPlaylistPlayback else { return }

        if isShuffle {
            fillShuffleQueue()
        } else if isUnplayedShuffle {
            fillUnplayedShuffleQueue()
        }
    }

    // 現在のシャッフル範囲内の未再生フラグをリセットする
    private func resetUnplayedShuffleFlags() {
        for track in shuffleCandidateTracks {
            track.hasBeenPlayedInUnplayedShuffle = false
        }
        do {
            try modelContext.save()
        } catch {
            print("未再生フラグの初期化に失敗: \(error.localizedDescription)")
        }
    }

    // 選択範囲内の未再生曲をランダムにキューへ追加する
    private func fillUnplayedShuffleQueue() {
        guard isUnplayedShuffle else { return }

        let queuedCount = queue.filter { $0.source == .unplayedShuffle }.count
        let neededCount = shuffleQueueCount - queuedCount
        guard neededCount > 0 else { return }

        var unplayedTracks = shuffleCandidateTracks.filter {
            $0.hasBeenPlayedInUnplayedShuffle != true
        }

        if unplayedTracks.isEmpty && !shuffleCandidateTracks.isEmpty {
            resetUnplayedShuffleFlags()

            if let currentPath = currentTrack?.path,
               let current = musicTracks.first(where: { $0.path == currentPath }),
               shuffleCandidateTracks.contains(where: { $0.path == currentPath }) {
                current.hasBeenPlayedInUnplayedShuffle = true
                try? modelContext.save()
            }

            unplayedTracks = shuffleCandidateTracks.filter {
                $0.hasBeenPlayedInUnplayedShuffle != true
            }
        }

        let excludedPaths = Set(queue.map(\.path)).union(
            currentTrack.map { [$0.path] } ?? []
        )
        let candidates = unplayedTracks.filter {
            !excludedPaths.contains($0.path)
        }
        let items = candidates.shuffled()
            .prefix(neededCount)
            .map { queueItem(for: $0, source: .unplayedShuffle) }
        queue.append(contentsOf: items)
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

            // 正常に取得できた場合だけ、戻るための履歴に登録
            if recordHistory, let previousTrack = currentTrack {
                playHistory.append(previousTrack)
            }

            // 前の再生セッションを未完了として保存
            finishPlaybackSession(completed: false)

            player.replaceCurrentItem(
                with: AVPlayerItem(url: musicURL)
            )

            currentTrack = item
            elapsedTime = 0
            playbackDuration = 0
            isSeeking = false

            player.play()
            isPlaying = true

            updateUnplayedShuffleFlag(for: item)

            // 新しい再生セッションを開始して統計に記録
            beginPlaybackSession(trackPath: item.path)
            lastObservedPlaybackTime = nil

            updateNowPlayingInfo()

            return true

        } catch {

            errorMessage = "再生エラー: \(error.localizedDescription)"
            isPlaying = false

            return false
        }
    }

    // 実際に再生を開始した曲だけ未再生フラグを更新する
    private func updateUnplayedShuffleFlag(for item: QueueItem) {
        let shouldMarkAsPlayed = item.source == .manual
            || item.source == .shuffle
            || item.source == .unplayedShuffle
        guard shouldMarkAsPlayed else { return }

        // 通常シャッフルは、その方式で最初の曲が再生開始した時点で全フラグを初期化する
        if isShuffle && normalShuffleNeedsReset && activeRefillCondition == nil && !isPlaylistPlayback {
            resetUnplayedShuffleFlags()
            normalShuffleNeedsReset = false
        }

        guard let track = musicTracks.first(where: { $0.path == item.path }) else {
            return
        }

        track.hasBeenPlayedInUnplayedShuffle = true
        do {
            try modelContext.save()
        } catch {
            print("未再生フラグの保存に失敗: \(error.localizedDescription)")
        }
    }

    // MARK: - 再生統計の記録

    // 新しい再生セッションを作成する
    private func beginPlaybackSession(trackPath: String) {

        let history = PlaybackHistory(trackPath: trackPath)
        modelContext.insert(history)
        activePlaybackHistory = history
        lastObservedPlaybackTime = nil
        unsavedHistorySeconds = 0

        // 再生開始時点で再生回数を加算
        let descriptor = FetchDescriptor<MusicTrack>(
            predicate: #Predicate { track in
                track.path == trackPath
            }
        )

        do {
            if let track = try modelContext.fetch(descriptor).first {
                track.playCount += 1
                track.lastPlayed = Date()
            }

            try modelContext.save()
        } catch {
            print("再生履歴の開始保存に失敗: \(error.localizedDescription)")
        }
    }

    // AVPlayerの再生位置の差分から、実再生時間を加算する
    private func recordPlaybackProgress(at currentTime: Double) {

        guard currentTime.isFinite else { return }

        defer {
            lastObservedPlaybackTime = currentTime
        }

        guard isPlaying,
              let history = activePlaybackHistory,
              let previousTime = lastObservedPlaybackTime else {
            return
        }

        let delta = currentTime - previousTime

        // 1秒間隔の監視で大きな差が出た場合は、
        // シークや一時停止・復帰による変化とみなして加算しない
        guard delta > 0, delta <= 2.5 else {
            return
        }

        history.listenedSeconds += delta
        history.lastUpdatedAt = Date()
        unsavedHistorySeconds += delta

        // 約10秒ごとに途中経過を保存
        if unsavedHistorySeconds >= 10 {
            checkpointPlaybackSession()
        }
    }

    // 現在のセッションの途中経過を保存する
    private func checkpointPlaybackSession() {

        guard let history = activePlaybackHistory else { return }
        guard unsavedHistorySeconds > 0 else { return }

        history.lastUpdatedAt = Date()

        do {
            try modelContext.save()
            unsavedHistorySeconds = 0
        } catch {
            print("再生時間の途中保存に失敗: \(error.localizedDescription)")
        }
    }

    // セッションを終了する。自然終了時だけ完了扱いにする
    private func finishPlaybackSession(completed: Bool) {

        guard let history = activePlaybackHistory else { return }

        checkpointPlaybackSession()

        if completed {
            history.completed = true
            history.lastUpdatedAt = Date()
        }

        do {
            try modelContext.save()
        } catch {
            print("再生履歴の終了保存に失敗: \(error.localizedDescription)")
        }

        activePlaybackHistory = nil
        lastObservedPlaybackTime = nil
        unsavedHistorySeconds = 0
    }

    // 次の曲を再生
    private func playNext(isNaturalEnd: Bool = false) async {

        // 自然終了したセッションは完了として確定
        if isNaturalEnd {
            finishPlaybackSession(completed: true)
        }

        // 1曲リピートは自然終了時だけ適用
        if isNaturalEnd && repeatMode == .one {

            // リピートも新しい再生セッションとして記録
            if let track = currentTrack {
                beginPlaybackSession(trackPath: track.path)
            }

            await player.seek(to: .zero)
            lastObservedPlaybackTime = nil
            player.play()
            isPlaying = true

            return
        }

        // 全曲リピートの場合、終了した曲をキュー末尾に戻す
        if isNaturalEnd && repeatMode == .all,
           let track = currentTrack,
           !queue.contains(where: { $0.path == track.path }) {

            let repeatedTrack = track
            queue.append(repeatedTrack)
        }

        // プレイリスト再生中は、プレイリスト外の自動選曲を行わない
        if queue.isEmpty && !isPlaylistPlayback {
            if activeRefillCondition != nil {
                refillActiveConditionQueue()
            } else {
                fillActiveShuffleQueue()
            }
        }

        // 次の曲がない場合
        guard !queue.isEmpty else {
            isPlaying = false
            isPlaylistPlayback = false
            return
        }

        // 最前列の曲を取り出す
        let nextTrack = queue.removeFirst()

        let success = await startTrack(nextTrack)

        if !success {
            queue.insert(nextTrack, at: 0)
            return
        }

        // 有効なシャッフル方式に応じて、次の曲の再生開始後に補充
        if activeRefillCondition == nil && queue.isEmpty && !isPlaylistPlayback {
            fillActiveShuffleQueue()
        }
    }

    // 前の曲を再生
    private func playPrevious() {

        guard let previousTrack = playHistory.popLast() else {
            return
        }

        // 現在の曲をキューの先頭に戻す
        if let track = currentTrack {
            // 元の再生元を保持し、プレイリスト／アーティスト／アルバム由来の曲を通常再生扱いにしない
            queue.insert(track, at: 0)
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

            // 一時停止直前までの再生時間を保存
            checkpointPlaybackSession()
            lastObservedPlaybackTime = nil
            player.pause()
            isPlaying = false

        } else if player.currentItem != nil {

            lastObservedPlaybackTime = nil
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

                // 再生範囲
                Menu {
                    Button {
                        setShuffleScope(.trackFolder)
                    } label: {
                        if shuffleScope == .trackFolder {
                            Label("再生中の曲のフォルダ", systemImage: "checkmark")
                        } else {
                            Text("再生中の曲のフォルダ")
                        }
                    }
                    Button {
                        setShuffleScope(.allLibrary)
                    } label: {
                        if shuffleScope == .allLibrary {
                            Label("全ライブラリ", systemImage: "checkmark")
                        } else {
                            Text("全ライブラリ")
                        }
                    }
                } label: {
                    Image(systemName: "folder")
                        .foregroundStyle(shuffleScopeColor)
                        .padding(6)
                        .background(shuffleScopeColor.opacity(0.14), in: Circle())
                }

                // シャッフル方式
                Menu {
                    Button("OFF") { setShuffleMode(.off) }
                    Button("通常シャッフル") { setShuffleMode(.normal) }
                    Button("未再生シャッフル") { setShuffleMode(.unplayed) }
                } label: {
                    Image(systemName: "shuffle")
                        .foregroundStyle(isShuffle || isUnplayedShuffle ? .blue : .secondary)
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
                .disabled(queue.isEmpty && !isShuffle && !isUnplayedShuffle)

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
        .background(appearanceTheme == "light" ? Color(red: 0.98, green: 0.97, blue: 0.94) : Color(.secondarySystemBackground))
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

private struct MP3MetadataEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let fileName: String
    let loadMetadata: () async throws -> MusicTagMetadata
    let saveMetadata: (String, String, String) async throws -> Void

    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("ファイル") {
                    Text(fileName)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("楽曲情報") {
                    TextField("曲名", text: $title)
                    TextField("アーティスト名", text: $artist)
                    TextField("アルバム名", text: $album)
                }

                if isLoading {
                    Section {
                        ProgressView("楽曲情報を読み込み中...")
                    }
                }

                if isSaving {
                    Section {
                        ProgressView("変更をクラウドへ保存中...")
                    }
                }

                if !errorMessage.isEmpty {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("楽曲情報の編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            await save()
                        }
                    }
                    .disabled(isLoading || isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task {
                await load()
            }
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = ""

        do {
            let metadata = try await loadMetadata()
            title = metadata.title
            artist = metadata.artist
            album = metadata.album
        } catch {
            errorMessage = "楽曲情報を読み込めませんでした：\(error.localizedDescription)"
        }

        isLoading = false
    }

    private func save() async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            errorMessage = "曲名を入力してください。"
            return
        }

        isSaving = true
        errorMessage = ""

        do {
            try await saveMetadata(
                trimmedTitle,
                artist.trimmingCharacters(in: .whitespacesAndNewlines),
                album.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            dismiss()
        } catch {
            errorMessage = "保存に失敗しました：\(error.localizedDescription)"
        }

        isSaving = false
    }
}

