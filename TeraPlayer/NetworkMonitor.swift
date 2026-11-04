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

            // Wi-Fiで通信可能な状態か確認
            let connected =
                path.status == .satisfied &&
                path.usesInterfaceType(.wifi)

            // メインスレッドで状態を更新
            Task { @MainActor [weak self] in
                self?.isWiFiConnected = connected
            }
        }

        monitor.start(queue: queue)
    }
}
