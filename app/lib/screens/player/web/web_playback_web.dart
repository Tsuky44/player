import 'dart:async';
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
/// statics, preserving `new` semantics) is far less legible than the JavaScript
/// it replaces.
const _bridgeSource = r'''
(function () {
  if (window.__playeurWeb) return;

  // Every hls.js instance ever constructed in this tab, ours and media_kit's
  // alike. media_kit builds one per open() and never destroys it, and exposes no
  // handle to it, so intercepting the constructor is the only way to reach them.
  var instances = [];

  // Bumped by every takeOverHls call, and the reason playback used to die after
  // a seek.
  //
  // A takeover that has to wait for the <video> element or for hls.js retries on
  // a timer for up to 30 seconds. This player rebuilds its HLS session on every
  // quality change, audio change and large seek, so a chain started by a session
  // that is already gone can still be pending — and when it finally fires it
  // attaches its OLD master URL over the live element. That session has been
  // destroyed server-side by then, so every segment it asks for is a 404 and
  // playback stops for good. Each chain carries the generation it was started
  // with and stands down as soon as a newer one exists.
  var generation = 0;

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

  // The retries and the error recovery below run outside the Dart call, so their
  // verdict would otherwise be invisible. Keeping the last one readable makes
  // "what is playback doing right now" answerable at any moment.
  function record(outcome) {
    window.__playeurWeb.lastOutcome = outcome;
    return outcome;
  }

  function destroyAll() {
    var released = 0;
    for (var i = 0; i < instances.length; i++) {
      try { instances[i].destroy(); released++; } catch (e) {}
    }
    instances = [];
    return released;
  }

  // hls.js configuration for a playlist that is being transcoded just in time.
  //
  // The defaults describe a finished VOD file sitting on a CDN. Four of them are
  // actively wrong against this server, and `{}` — what this bridge used to pass
  // — accepts all four:
  //
  //  * startPosition. FFmpeg cannot write #EXT-X-ENDLIST on a stream it is still
  //    producing, so the playlist is an EVENT one and hls.js treats it as LIVE:
  //    it starts three target durations BEHIND the last segment published. The
  //    server already seeked the input to where the user asked, so there is no
  //    live edge to chase — every session must start at 0 of its own timeline,
  //    which is also what the client's position maths assumes when it reports
  //    `hls position + session offset`.
  //  * the load timeouts and retry budgets. A segment request can legitimately
  //    block for seconds: rather than answer 404 for a segment the transcoder is
  //    about to write, the server holds the request open and only gives up at
  //    12s with a 503. Six retries against a 20s timeout turn a transcoder that
  //    is briefly behind into a fatal error.
  //  * maxBufferHole. On the copy path segments are cut on the source's own
  //    keyframes, so the video and audio renditions do not break at the same
  //    instants and sub-second gaps between them are normal. 0.1s treats those
  //    as stalls to nudge through one at a time; 0.5 steps over them.
  //  * testBandwidth. There is exactly one video variant, so probing the link to
  //    choose between variants buys nothing and costs an aborted first fragment.
  //
  // The *Loading* keys are the pre-1.4 spelling of the load policies. hls.js
  // still maps them onto the new shape (with a deprecation notice), and unlike
  // the policy objects they are understood by every 1.x the app might be served.
  //
  // maxBufferLength is left at its 30s default ON PURPOSE, and raising it is not
  // the free win it looks like: the server's throttler stops the transcoder once
  // it is 32s beyond the last segment the client asked for, so a client that
  // wants more than that asks for segments nothing is producing and spends its
  // retry budget waiting on them. The two numbers are one setting in two files.
  var CONFIG = {
    startPosition: 0,
    lowLatencyMode: false,
    testBandwidth: false,
    maxBufferHole: 0.5,
    nudgeMaxRetry: 10,
    appendErrorMaxRetry: 5,
    backBufferLength: 60,
    manifestLoadingTimeOut: 20000,
    manifestLoadingMaxRetry: 4,
    levelLoadingTimeOut: 20000,
    levelLoadingMaxRetry: 6,
    fragLoadingTimeOut: 30000,
    fragLoadingMaxRetry: 10,
    fragLoadingRetryDelay: 500,
    fragLoadingMaxRetryTimeout: 8000
  };

  // hls.js handles a great deal on its own, but a FATAL error is by design the
  // application's problem: the instance stops, and only startLoad() or
  // recoverMediaError() from outside restarts it. With no handler at all — the
  // shape media_kit ships, and the one this bridge used to build — the first
  // fatal error ends playback in silence. That is the spinner that never goes
  // away, and the reason a stream that stalled once never came back.
  function attachRecovery(hls, gen) {
    var Events = (window.Hls && window.Hls.Events) || {};
    var networkRestarts = 0;
    var mediaRecoveries = 0;

    hls.on(Events.ERROR || 'hlsError', function (_evt, data) {
      var detail = (data && data.details) || 'unknown';
      window.__playeurWeb.lastError =
        ((data && data.fatal) ? 'fatal:' : 'warn:') + detail;
      if (!data || !data.fatal) return;
      // A newer session owns the element; this instance is on its way out.
      if (gen !== generation) return;

      // 'networkError' and 'mediaError' are the string values of
      // Hls.ErrorTypes.NETWORK_ERROR / MEDIA_ERROR. Compared as literals so this
      // keeps working even if the constructor wrapper loses a static.
      if (data.type === 'networkError') {
        // A playlist or segment the transcoder has not reached yet. hls.js has
        // already spent its own retry budget by the time an error is fatal, so
        // the only move left is to restart the loaders: the server is still
        // there, it was just slower than the budget allowed for. Backed off so a
        // genuinely dead session stops being hammered.
        if (networkRestarts < 8) {
          networkRestarts++;
          var delay = 1000 * networkRestarts;
          setTimeout(function () {
            if (gen !== generation) return;
            try { hls.startLoad(); } catch (e) {}
          }, delay);
          return record('recovering-network-' + networkRestarts);
        }
        return record('gave-up-network:' + detail);
      }

      if (data.type === 'mediaError') {
        if (mediaRecoveries < 3) {
          mediaRecoveries++;
          try {
            // From the second attempt on, swap the audio codec first: that is
            // hls.js's documented escape from an append the source buffer keeps
            // refusing.
            if (mediaRecoveries > 1 && hls.swapAudioCodec) hls.swapAudioCodec();
            hls.recoverMediaError();
            return record('recovering-media-' + mediaRecoveries);
          } catch (e) {
            return record('gave-up-media:' + detail);
          }
        }
        return record('gave-up-media:' + detail);
      }

      return record('fatal:' + detail);
    });
  }

  // One attempt at adopting `url`, retried on a timer until the pieces exist.
  function step(url, gen, attempt) {
    if (gen !== generation) return record('superseded');

    var video = document.querySelector('video');
    var hlsReady = (typeof window.Hls === 'function');

    // Two things land at their own pace: the platform view holding the <video>
    // (entering the player screen for the first time can take seconds) and
    // hls.js itself, which media_kit injects with an async <script>.
    //
    // media_kit's own `element.src = <playlist>` is deliberately NOT waited for.
    // It runs synchronously inside the open() this is called after, so there is
    // nothing left to race — and the check that used to stand in for that wait
    // ("is video.src set?") could not fail anyway: the empty string media_kit
    // assigns in stop() resolves against the page URL and reads back truthy.
    if (!video || !hlsReady) {
      if (attempt < 300) { // 30s of budget
        setTimeout(function () { step(url, gen, attempt + 1); }, 100);
        return record(!video ? 'waiting-for-video' : 'waiting-for-hlsjs');
      }
      return record('gave-up-waiting');
    }

    // Safari genuinely speaks HLS, media_kit's native path is right there, and
    // MSE is not available to take over with in the first place.
    if (!window.Hls.isSupported()) return record('native');

    // Everything constructed before this call is finished, media_kit's instance
    // included. Leaving any of them alive is not a leak but a fault: each keeps
    // its own loaders and error handlers running against the one shared <video>,
    // and one from a previous session points at a session the server has already
    // destroyed. This used to be a "destroy all but the newest" pass fired from
    // Dart, which ran BEFORE the retry loop had built the new instance — so the
    // newest was the stale one, and it was the one thing kept.
    destroyAll();

    // Deliberately NOT clearing src first. Removing the attribute and calling
    // load() empties the element, which fires a fatal "Empty src attribute"
    // error; media_kit forwards it and the player screen closes on the spot.
    // attachMedia() points src at its own MediaSource blob anyway, so the old
    // playlist URL is superseded without ever passing through an empty state.
    var hls = new window.Hls(CONFIG);
    attachRecovery(hls, gen);
    hls.loadSource(url);
    hls.attachMedia(video);

    // Always resume: a transcoding session is only ever opened with play:true,
    // and the element's paused flag at this instant says nothing — media_kit's
    // own play() may not have run yet. There is a user gesture behind every one
    // of these, so autoplay policy lets it through.
    //
    // Driven off the element's own `canplay` rather than an Hls event, so it does
    // not depend on the constructor's statics surviving the wrapper.
    var tryPlay = function () {
      var p = video.play();
      if (p && p.catch) p.catch(function () {});
    };
    video.addEventListener('canplay', tryPlay, { once: true });
    tryPlay();
    return record('hlsjs-forced');
  }

  window.__playeurWeb = {
    lastOutcome: 'none',
    lastError: 'none',

    // Makes hls.js drive the playlist whenever it can, which is the order every
    // serious player uses and the one hls.js documents.
    //
    // media_kit asks the element first — `canPlayType('application/vnd.apple.
    // mpegurl') != ''` — and only reaches for hls.js when that comes back empty.
    // Chromium answers "maybe" to that question and has no native HLS
    // whatsoever, so media_kit assigns the .m3u8 straight to `src`, the browser
    // dribbles out a few segments and stalls for good. Safari is the one engine
    // that really means "maybe", and there `Hls.isSupported()` is false, so the
    // native path is kept for it.
    //
    // Returns which engine ended up in charge.
    takeOverHls: function (url) {
      return step(url, ++generation, 0);
    },

    instanceCount: function () { return instances.length; },

    // Tears every instance down, for teardown. The generation bump matters as
    // much as the destroy: without it a takeover still waiting on a timer would
    // build a fresh instance after the player screen is gone.
    releaseAllHls: function () {
      generation++;
      return destroyAll();
    },

    diagnostics: function () {
      return 'engine=' + window.__playeurWeb.lastOutcome +
             ' error=' + window.__playeurWeb.lastError +
             ' instances=' + instances.length;
    }
  };

  var wrapped = null;
  var existing = window.Hls;
  Object.defineProperty(window, 'Hls', {
    configurable: true,
    get: function () { return wrapped; },
    set: function (v) { wrapped = wrap(v); }
  });
  if (existing) window.Hls = existing;
})();
''';

@JS('__playeurWeb.takeOverHls')
external String _takeOverHls(String url);

@JS('__playeurWeb.releaseAllHls')
external int _releaseAllHls();

@JS('__playeurWeb.diagnostics')
external String _diagnostics();

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

  /// Puts hls.js in charge of [masterUrl], reclaiming whatever the previous
  /// session left attached to the same `<video>`.
  ///
  /// Call right after `player.open()` of a master playlist.
  static void adoptHlsSession(String masterUrl) {
    try {
      // The verdict here is only the FIRST one: adopting the element waits on
      // the platform view and on hls.js, so a session usually reports
      // 'waiting-for-…' and settles a few hundred milliseconds later.
      final engine = _takeOverHls(masterUrl);
      debugPrint('WebPlayback: HLS engine = $engine');
    } catch (e) {
      debugPrint('WebPlayback: takeOverHls failed: $e');
      return;
    }
    // Which engine ended up in charge, and whether it has hit anything, is the
    // one question worth answering when a stream misbehaves — and it is settled
    // by now, unlike the return value above.
    Timer(const Duration(seconds: 5), () {
      try {
        debugPrint('WebPlayback: ${_diagnostics()}');
      } catch (_) {}
    });
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
