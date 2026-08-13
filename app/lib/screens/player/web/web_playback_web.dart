import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

/// Browser implementation — see `web_playback.dart`.

/// Whether [WebPlayback.install] has already injected the bridge.
///
/// Tracked in Dart rather than by probing the global: a top-level `@JS` getter
/// for `__playeurWeb` resolves to null here even once the object exists, which
/// silently turned every call below into a no-op. The bridge calls themselves
/// are guarded by try/catch, which covers the case where injection failed.
bool _bridgeInstalled = false;

/// The hook has to intercept the *assignment* of `window.Hls`, which happens
/// inside hls.js's own bundle when media_kit injects it. `Object.defineProperty`
/// with a setter is the only way to be there when it lands, and expressing that
/// through `dart:js_interop` (building a JS constructor from Dart, copying its
/// statics, preserving `new` semantics) is far less legible than the eight lines
/// of JavaScript it replaces.
const _bridgeSource = r'''
(function () {
  if (window.__playeurWeb) return;

  var instances = [];

  // Wraps the hls.js constructor so every instance is recorded. `new W(cfg)`
  // returns `inst`, which replaces `this` — so callers see a genuine Hls.
  function wrap(Original) {
    if (typeof Original !== 'function') return Original;
    function W(cfg) {
      var inst = new Original(cfg);
      instances.push(inst);
      return inst;
    }
    W.prototype = Original.prototype;
    // getOwnPropertyNames, not for..in: hls.js declares statics such as
    // `Events` as non-enumerable, and a for..in copy silently drops them.
    Object.getOwnPropertyNames(Original).forEach(function (k) {
      if (k === 'prototype' || k === 'name' || k === 'length') return;
      try { W[k] = Original[k]; } catch (e) {}
    });
    W.isSupported = function () { return Original.isSupported(); };
    return W;
  }

  // The retries below run outside the Dart call, so their verdict would
  // otherwise be invisible. Keeping the last one readable makes "which engine
  // ended up in charge" answerable at any moment.
  function record(outcome) {
    window.__playeurWeb.lastOutcome = outcome;
    return outcome;
  }

  var wrapped = null;
  var existing = window.Hls;
  Object.defineProperty(window, 'Hls', {
    configurable: true,
    get: function () { return wrapped; },
    set: function (v) { wrapped = wrap(v); }
  });
  if (existing) window.Hls = existing;

  window.__playeurWeb = {
    // Makes hls.js drive the playlist whenever it can, which is the order every
    // serious player uses and the one hls.js documents.
    //
    // media_kit asks the element first — `canPlayType('application/vnd.apple.
    // mpegurl') != ''` — and only reaches for hls.js when that comes back
    // empty. Chromium answers "maybe" to that question and has no native HLS
    // whatsoever, so media_kit assigns the .m3u8 straight to `src`, the browser
    // dribbles out a few segments and stalls for good. Safari is the one engine
    // that really means "maybe", and there `Hls.isSupported()` is false, so the
    // native path is kept for it.
    //
    // Returns which engine ended up in charge.
    takeOverHls: function (url, attempt) {
      attempt = attempt || 0;
      var video = document.querySelector('video');
      var hlsReady = (typeof window.Hls === 'function');
      // A blob source means MediaSource is already attached: media_kit went
      // down the hls.js branch on its own and there is nothing to repair.
      if (video && video.src && video.src.indexOf('blob:') === 0) return record('hlsjs');

      // Three things land at their own pace after open() resolves: the platform
      // view holding the <video>, hls.js (media_kit injects it with an async
      // <script>), and media_kit's own `element.src = <playlist>` assignment.
      //
      // Waiting for that last one matters as much as the others. Taking over
      // before it happens works for a moment and is then undone — media_kit
      // overwrites src and the MediaSource is dropped, which is why playback
      // landed on hls.js or on the stalling native path at random.
      var mediaKitAssigned = !!(video && video.src);
      if (!video || !hlsReady || !mediaKitAssigned) {
        // 30s of budget: entering the player screen for the first time can take
        // seconds to produce the platform view, and giving up early is what left
        // playback on the native path that cannot work.
        if (attempt < 300) {
          setTimeout(function () {
            window.__playeurWeb.takeOverHls(url, attempt + 1);
          }, 100);
          return record(!video ? 'waiting-for-video'
               : !hlsReady ? 'waiting-for-hlsjs'
               : 'waiting-for-src');
        }
        return record('gave-up');
      }
      if (!window.Hls.isSupported()) return record('native');

      // Deliberately NOT clearing src first. Removing the attribute and calling
      // load() empties the element, which fires a fatal "Empty src attribute"
      // error; media_kit forwards it and the player screen closes on the spot.
      // attachMedia() points src at its own MediaSource blob anyway, so the old
      // playlist URL is superseded without ever passing through an empty state.
      var hls = new window.Hls({});
      hls.loadSource(url);
      hls.attachMedia(video);
      // Always resume: a transcoding session is only ever opened with play:true,
      // and the element's paused flag at this instant says nothing — media_kit's
      // own play() may not have run yet. There is a user gesture behind every
      // one of these, so autoplay policy lets it through.
      //
      // Driven off the element's own `canplay` rather than an Hls event, so it
      // does not depend on the constructor's statics surviving the wrapper.
      var tryPlay = function () {
        var p = video.play();
        if (p && p.catch) p.catch(function () {});
      };
      video.addEventListener('canplay', tryPlay, { once: true });
      tryPlay();
      return record('hlsjs-forced');
    },

    instanceCount: function () { return instances.length; },

    // Destroys every instance but the newest, which is the one driving the
    // element right now. Each abandoned instance otherwise keeps its segment
    // loaders and error handlers alive against the shared <video>.
    releaseStaleHls: function () {
      var released = 0;
      for (var i = 0; i < instances.length - 1; i++) {
        try { instances[i].destroy(); released++; } catch (e) {}
      }
      instances = instances.length ? [instances[instances.length - 1]] : [];
      return released;
    },
    // Destroys everything, for teardown.
    releaseAllHls: function () {
      var released = 0;
      for (var i = 0; i < instances.length; i++) {
        try { instances[i].destroy(); released++; } catch (e) {}
      }
      instances = [];
      return released;
    }
  };
})();
''';

@JS('__playeurWeb.takeOverHls')
external String _takeOverHls(String url, int attempt);

@JS('__playeurWeb.releaseStaleHls')
external int _releaseStaleHls();

@JS('__playeurWeb.releaseAllHls')
external int _releaseAllHls();

abstract final class WebPlayback {
  /// Injects the bridge. Idempotent, and safe to call before hls.js exists —
  /// the point is precisely to be installed first.
  static void install() {
    if (_bridgeInstalled) return;
    _bridgeInstalled = true;
    final script = web.HTMLScriptElement()
      ..type = 'text/javascript'
      ..text = _bridgeSource;
    (web.document.head ?? web.document.documentElement!).append(script);
  }

  /// Puts hls.js in charge of [masterUrl] when the browser only pretends to
  /// support HLS, then reclaims whatever the previous session left behind.
  ///
  /// Call right after `player.open()` of a master playlist.
  static void adoptHlsSession(String masterUrl) {
    try {
      final engine = _takeOverHls(masterUrl, 0);
      debugPrint('WebPlayback: HLS engine = $engine');
    } catch (e) {
      debugPrint('WebPlayback: takeOverHls failed: $e');
    }
    releaseStaleHlsSessions();
  }

  /// Reclaims the hls.js instances left behind by previous sessions. Call right
  /// after each `player.open()` of a master playlist.
  static int releaseStaleHlsSessions() {
    try {
      final released = _releaseStaleHls();
      if (released > 0) {
        debugPrint('WebPlayback: released $released stale hls.js session(s)');
      }
      return released;
    } catch (e) {
      debugPrint('WebPlayback: releaseStaleHls failed: $e');
      return 0;
    }
  }

  /// Tears every hls.js instance down, including the active one.
  static int releaseAllHlsSessions() {
    try {
      return _releaseAllHls();
    } catch (_) {
      return 0;
    }
  }

  /// Shows [vtt] as the one and only subtitle track.
  ///
  /// The cues are handed to the browser (`mode = 'showing'`) instead of being
  /// parsed in Dart and painted by Flutter. That skips media_kit's broken
  /// `oncuechange` path entirely, and has a bonus this player wants anyway: the
  /// browser keeps rendering them in native full screen, where a Flutter overlay
  /// would be gone.
  static bool showSubtitleVtt(
    String vtt, {
    String? language,
    String? label,
  }) {
    final video = _videoElement();
    if (video == null) return false;

    _removeTracks(video);
    if (vtt.isEmpty) return true;

    final blob = web.Blob(
      <JSAny>[vtt.toJS].toJS,
      web.BlobPropertyBag(type: 'text/vtt'),
    );
    final url = web.URL.createObjectURL(blob);

    final element = web.HTMLTrackElement()
      ..kind = 'subtitles'
      ..src = url
      ..srclang = language ?? ''
      ..label = label ?? '';
    video.append(element);

    // Setting the mode is what actually renders them; a <track> that is merely
    // present stays disabled.
    element.track.mode = 'showing';
    return true;
  }

  /// Removes every subtitle track from the element.
  static bool clearSubtitles() {
    final video = _videoElement();
    if (video == null) return false;
    _removeTracks(video);
    return true;
  }

  /// media_kit renders into a single platform-view `<video>`, and this app never
  /// has two players alive at once.
  static web.HTMLVideoElement? _videoElement() =>
      web.document.querySelector('video') as web.HTMLVideoElement?;

  static void _removeTracks(web.HTMLVideoElement video) {
    final tracks = video.querySelectorAll('track');
    for (var i = tracks.length - 1; i >= 0; i--) {
      final node = tracks.item(i);
      if (node == null) continue;
      final track = node as web.HTMLTrackElement;
      // Blob URLs stay alive until revoked; a subtitle swap per episode would
      // otherwise leak the whole .vtt for the life of the tab.
      if (track.src.startsWith('blob:')) {
        web.URL.revokeObjectURL(track.src);
      }
      track.remove();
    }
  }
}
