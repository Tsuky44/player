import Cocoa
import FlutterMacOS
import MediaPlayer

/// Claims macOS Now Playing / media keys while the in-app player is active.
final class NowPlayingController: NSObject, FlutterStreamHandler {
  static let shared = NowPlayingController()

  private var eventSink: FlutterEventSink?
  private var isActive = false

  private var toggleTarget: Any?
  private var playTarget: Any?
  private var pauseTarget: Any?
  private var previousTarget: Any?
  private var nextTarget: Any?
  private var skipBackTarget: Any?
  private var skipForwardTarget: Any?

  func register(messenger: FlutterBinaryMessenger) {
    let methodChannel = FlutterMethodChannel(
      name: "project_player/now_playing",
      binaryMessenger: messenger
    )
    let eventChannel = FlutterEventChannel(
      name: "project_player/now_playing_events",
      binaryMessenger: messenger
    )

    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    eventChannel.setStreamHandler(self)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "activate":
      activate(args: call.arguments as? [String: Any])
      result(nil)
    case "update":
      update(args: call.arguments as? [String: Any])
      result(nil)
    case "deactivate":
      deactivate()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func activate(args: [String: Any]?) {
    if !isActive {
      registerCommands()
      isActive = true
    }
    update(args: args)
  }

  private func registerCommands() {
    let center = MPRemoteCommandCenter.shared()

    center.togglePlayPauseCommand.isEnabled = true
    toggleTarget = center.togglePlayPauseCommand.addTarget { [weak self] _ in
      self?.emit("playPause")
      return .success
    }

    center.playCommand.isEnabled = true
    playTarget = center.playCommand.addTarget { [weak self] _ in
      self?.emit("play")
      return .success
    }

    center.pauseCommand.isEnabled = true
    pauseTarget = center.pauseCommand.addTarget { [weak self] _ in
      self?.emit("pause")
      return .success
    }

    center.previousTrackCommand.isEnabled = true
    previousTarget = center.previousTrackCommand.addTarget { [weak self] _ in
      self?.emit("rewind")
      return .success
    }

    center.nextTrackCommand.isEnabled = true
    nextTarget = center.nextTrackCommand.addTarget { [weak self] _ in
      self?.emit("fastForward")
      return .success
    }

    center.skipBackwardCommand.isEnabled = true
    center.skipBackwardCommand.preferredIntervals = [10]
    skipBackTarget = center.skipBackwardCommand.addTarget { [weak self] _ in
      self?.emit("rewind")
      return .success
    }

    center.skipForwardCommand.isEnabled = true
    center.skipForwardCommand.preferredIntervals = [10]
    skipForwardTarget = center.skipForwardCommand.addTarget { [weak self] _ in
      self?.emit("fastForward")
      return .success
    }
  }

  private func unregisterCommands() {
    let center = MPRemoteCommandCenter.shared()

    if let target = toggleTarget {
      center.togglePlayPauseCommand.removeTarget(target)
      toggleTarget = nil
    }
    if let target = playTarget {
      center.playCommand.removeTarget(target)
      playTarget = nil
    }
    if let target = pauseTarget {
      center.pauseCommand.removeTarget(target)
      pauseTarget = nil
    }
    if let target = previousTarget {
      center.previousTrackCommand.removeTarget(target)
      previousTarget = nil
    }
    if let target = nextTarget {
      center.nextTrackCommand.removeTarget(target)
      nextTarget = nil
    }
    if let target = skipBackTarget {
      center.skipBackwardCommand.removeTarget(target)
      skipBackTarget = nil
    }
    if let target = skipForwardTarget {
      center.skipForwardCommand.removeTarget(target)
      skipForwardTarget = nil
    }
  }

  private func update(args: [String: Any]?) {
    guard isActive, let args else { return }

    let title = args["title"] as? String ?? "Lecture"
    let duration = args["duration"] as? Double ?? 0
    let elapsed = args["elapsed"] as? Double ?? 0
    let isPlaying = args["isPlaying"] as? Bool ?? false

    var info: [String: Any] = [
      MPMediaItemPropertyTitle: title,
      MPMediaItemPropertyPlaybackDuration: max(duration, 0),
      MPNowPlayingInfoPropertyElapsedPlaybackTime: max(elapsed, 0),
      MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
    ]

    if let artist = args["artist"] as? String, !artist.isEmpty {
      info[MPMediaItemPropertyArtist] = artist
    }

    let center = MPNowPlayingInfoCenter.default()
    center.nowPlayingInfo = info
    center.playbackState = isPlaying ? .playing : .paused
  }

  private func deactivate() {
    guard isActive else { return }

    unregisterCommands()

    let center = MPNowPlayingInfoCenter.default()
    center.nowPlayingInfo = nil
    center.playbackState = .stopped

    isActive = false
  }

  private func emit(_ action: String) {
    eventSink?(action)
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}
