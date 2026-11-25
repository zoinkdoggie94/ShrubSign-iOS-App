//
//  BackgroundAudioManager.swift
//  ShrubSign
//
//  Created by Nagata Asami on 10/10/25.
//
//  A silent audio session keeps ShrubSign alive while iOS downloads and
//  installs an app. 3.2.2 also allows an explicit override during installation
//  so a disabled setting can no longer break the install itself, and makes
//  start/stop idempotent so repeated calls cannot attach duplicate nodes.
//

import AVFoundation

final class BackgroundAudioManager {
    static let shared = BackgroundAudioManager()

    private let _engine = AVAudioEngine()
    private var _source: AVAudioSourceNode?
    private var _downloadNeedsAudio = false
    private var _installations: Set<UUID> = []

    private init() {}

    func start(force: Bool = false, installation: UUID? = nil) {
        guard force || OptionsManager.shared.options.backgroundAudio else { return }
        if let installation {
            _installations.insert(installation)
        } else {
            _downloadNeedsAudio = true
        }
        guard !_engine.isRunning else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)

            if _source == nil {
                let silence = AVAudioSourceNode { _, _, _, audioBufferList -> OSStatus in
                    let pointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
                    for buffer in pointer {
                        memset(buffer.mData, 0, Int(buffer.mDataByteSize))
                    }
                    return noErr
                }
                _engine.attach(silence)
                _engine.connect(silence, to: _engine.mainMixerNode, format: nil)
                _source = silence
            }

            if !_engine.isRunning {
                try _engine.start()
            }
        } catch {
            print("failed to start engine:", error)
        }
    }

    func stop(installation: UUID? = nil) {
        if let installation {
            guard _installations.remove(installation) != nil else { return }
        } else {
            _downloadNeedsAudio = false
        }
        guard !_downloadNeedsAudio, _installations.isEmpty else { return }
        _engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
    }
}
