//
//  UpdateCheckLogger.swift
//  Roster
//
//  Logs Sparkle's launch-check decision path to the updates category of
//  os_log, so silent background checks are observable via `log stream`.
//

import Foundation
import os
import Sparkle

final class UpdateCheckLogger: NSObject, SPUUpdaterDelegate {
    private static let logger = Logger(subsystem: "dev.arosa.roster", category: "updates")

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        Self.logger.notice("appcast loaded with \(appcast.items.count) items")
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Self.logger.notice("found valid update \(item.displayVersionString) (sparkle version \(item.versionString))")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        Self.logger.notice("no update found: \(error.localizedDescription)")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Self.logger.notice("no update found")
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        Self.logger.notice("will download \(item.displayVersionString)")
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        Self.logger.notice("did download \(item.displayVersionString)")
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        Self.logger.error("download failed for \(item.displayVersionString): \(error.localizedDescription)")
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        Self.logger.notice("will install \(item.displayVersionString)")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Self.logger.error("aborted: \(error.localizedDescription)")
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        if let error {
            Self.logger.error("update cycle finished with error: \(error.localizedDescription)")
        } else {
            Self.logger.notice("update cycle finished cleanly for \(updateCheck.rawValue)")
        }
    }
}
