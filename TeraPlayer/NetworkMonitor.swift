//
//  NetworkMonitor.swift
//  TeraPlayer
//
//  Created by Kaguya on 2026/11/07.
//

import Foundation
import Network
import Combine

@MainActor
final class NetworkMonitor: ObservableObject {

    // 初回のネットワーク判定が完了したか
    @Published private(set) var isWiFiStatusKnown = false

    // Wi-Fi接続状態
    @Published private(set) var isWiFiConnected = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(
        label: "TeraPlayer.NetworkMonitor"
    )

    private var isStarted = false

    // MARK: - 監視開始

    func start() {

        guard !isStarted else {
            return
        }

        isStarted = true

        monitor.pathUpdateHandler = { [weak self] path in

            // OpenListは現在LAN内にあるため、Wi-Fiで通信可能な状態を確認する。
            let connected =
                path.status == .satisfied &&
                path.usesInterfaceType(.wifi)

            // メインスレッドで状態を更新する。
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isWiFiConnected = connected
                self.isWiFiStatusKnown = true
            }
        }

        monitor.start(queue: queue)
    }
}
