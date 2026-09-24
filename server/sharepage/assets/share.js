// Page d'un lien de partage public (ADR-0037).
//
// Le code du lien est dans le fragment de l'adresse (#code) : le navigateur ne
// l'envoie jamais au serveur, il ne finit donc dans aucun journal. La page le
// présente elle-même, dans le corps des requêtes /api/shared/*.
//
// La lecture passe toujours par HLS, sans déclarer de capacités : le serveur
// rend alors du H.264 + AAC stéréo en MPEG-TS, que tout navigateur lit (avec
// hls.js, ou nativement sur Safari). Il recopie l'image quand elle est déjà en
// H.264, et ne réencode que sinon.
(function () {
  'use strict';

  // La version que media_kit charge pour l'app web : une seule hls.js à suivre.
  var HLS_SRC = 'https://cdnjs.cloudflare.com/ajax/libs/hls.js/1.4.10/hls.min.js';
  var QUALITY = '1080p';
  var PROGRESS_EVERY_MS = 15000;
  var CHROME_IDLE_MS = 3000;

  // Réglages hls.js pour une playlist transcodée à la volée : les mêmes que le
  // pont web de l'app (app/lib/screens/player/web/web_playback_web.dart), qui
  // explique chacun. En deux mots : la session commence à 0 de sa propre
  // chronologie, et un segment peut mettre plusieurs secondes à arriver.
  var HLS_CONFIG = {
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

  function $(id) { return document.getElementById(id); }

  var code = '';
  try { code = decodeURIComponent(location.hash.slice(1)).trim(); } catch (e) { code = ''; }

  // Le stockage peut manquer (navigation privée) : la page marche sans, elle
  // oublie seulement la position et la réservation au rechargement.
  var storage = {
    get: function (key) { try { return localStorage.getItem(key); } catch (e) { return null; } },
    set: function (key, value) { try { localStorage.setItem(key, value); } catch (e) { /* sans */ } },
    remove: function (key) { try { localStorage.removeItem(key); } catch (e) { /* sans */ } }
  };
  var viewerKey = 'onyx-share-viewer:' + code;
  var positionKey = 'onyx-share-position:' + code;

  var state = {
    info: null,
    access: null,
    session: null,
    hls: null,
    duration: 0,
    generation: 0,
    renewTimer: 0,
    progressTimer: 0,
    idleTimer: 0,
    dragging: false,
    consumed: false,
    ended: false,
    lastSaved: 0
  };

  var video = $('video');
  var player = $('player');

  // ---------------------------------------------------------------- API

  function api(path, body) {
    var payload = Object.assign({ code: code }, body || {});
    return fetch('/api/shared/' + path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
      cache: 'no-store',
      credentials: 'omit'
    }).then(function (res) {
      return res.text().then(function (text) {
        var data = null;
        try { data = text ? JSON.parse(text) : null; } catch (e) { data = null; }
        if (!res.ok) {
          var err = new Error((data && data.error) || 'Le serveur ne répond pas. Réessayez dans un moment.');
          err.status = res.status;
          throw err;
        }
        return data;
      });
    }, function () {
      var err = new Error('Impossible de joindre le serveur. Vérifiez votre connexion.');
      err.status = 0;
      throw err;
    });
  }

  // ------------------------------------------------------------ Accueil

  function showMessage(text, info) {
    var el = $('message');
    el.textContent = text;
    el.classList.toggle('info', !!info);
    el.hidden = !text;
  }

  function formatTime(seconds) {
    seconds = Math.max(0, Math.floor(seconds || 0));
    var h = Math.floor(seconds / 3600);
    var m = Math.floor((seconds % 3600) / 60);
    var s = seconds % 60;
    var mm = h > 0 && m < 10 ? '0' + m : String(m);
    return (h > 0 ? h + ':' : '') + mm + ':' + (s < 10 ? '0' : '') + s;
  }

  function formatDate(iso) {
    try {
      return new Date(iso).toLocaleString('fr-FR', { day: 'numeric', month: 'long', hour: '2-digit', minute: '2-digit' });
    } catch (e) {
      return iso;
    }
  }

  function renderMedia(media) {
    var title = media.title || (media.needs_password ? 'Contenu protégé' : 'Média partagé');
    $('title').textContent = title;
    document.title = (media.title ? media.title + ' · ' : '') + 'Onyx';
    var subtitle = $('subtitle');
    subtitle.textContent = media.subtitle || '';
    subtitle.hidden = !media.subtitle;
    $('player-title').textContent = media.title || '';
    $('player-subtitle').textContent = media.subtitle || '';

    if (media.poster_url) {
      var url = 'url("' + media.poster_url.replace(/"/g, '%22') + '")';
      $('poster').style.backgroundImage = url;
      $('poster').classList.add('has-art');
      $('backdrop').style.backgroundImage = url;
    }

    var badges = [];
    if (media.duration) badges.push(formatTime(media.duration));
    if (media.single_use) badges.push('Lien à usage unique');
    if (media.expires_at) badges.push('Expire le ' + formatDate(media.expires_at));
    var list = $('badges');
    list.textContent = '';
    badges.forEach(function (label) {
      var li = document.createElement('li');
      li.textContent = label;
      list.appendChild(li);
    });
  }

  function savedPosition(duration) {
    var saved = parseFloat(storage.get(positionKey) || '0');
    if (!(saved > 30)) return 0;
    if (duration > 0 && saved > duration * 0.95) return 0;
    return saved;
  }

  function renderPlayButton(media) {
    var resume = savedPosition(media.duration || 0);
    $('play-label').textContent = resume > 0 ? 'Reprendre à ' + formatTime(resume) : 'Regarder';
    $('play').hidden = false;
  }

  function init() {
    if (!code) {
      $('title').textContent = 'Lien incomplet';
      showMessage('Il manque la fin de l’adresse. Demandez à la personne qui vous l’a envoyée de la copier à nouveau.');
      return;
    }
    api('info', { viewer: storage.get(viewerKey) || '' }).then(function (info) {
      state.info = info;
      renderMedia(info);
      if (info.needs_password) {
        $('password-form').hidden = false;
        $('password').focus();
      } else {
        renderPlayButton(info);
        $('play').focus();
      }
    }, function (err) {
      $('title').textContent = err.status === 410 ? 'Lien expiré' : 'Lien indisponible';
      showMessage(err.message);
    });

    if (window.MediaSource || window.WebKitMediaSource) loadHls();
  }

  var hlsLoading = null;
  function loadHls() {
    if (hlsLoading) return hlsLoading;
    hlsLoading = new Promise(function (resolve) {
      var script = document.createElement('script');
      script.src = HLS_SRC;
      script.crossOrigin = 'anonymous';
      script.onload = function () { resolve(true); };
      script.onerror = function () { resolve(false); };
      document.head.appendChild(script);
    });
    return hlsLoading;
  }

  function open(password) {
    var button = $('play');
    var submit = $('password-form').querySelector('button');
    button.disabled = submit.disabled = true;
    showMessage('');
    api('open', { password: password || '', viewer: storage.get(viewerKey) || '' }).then(function (access) {
      state.access = access;
      storage.set(viewerKey, access.viewer);
      renderMedia(access.media);
      enterPlayer();
    }, function (err) {
      button.disabled = submit.disabled = false;
      showMessage(err.message);
      if (err.status === 401) {
        $('password').select();
      }
    });
  }

  $('password-form').addEventListener('submit', function (event) {
    event.preventDefault();
    open($('password').value);
  });
  $('play').addEventListener('click', function () { open(''); });

  // ------------------------------------------------------------ Lecteur

  function setLoading(on) { player.classList.toggle('loading', !!on); }

  function showNotice(text, sticky) {
    var el = $('notice');
    el.textContent = text;
    el.hidden = !text;
    if (text && !sticky) {
      setTimeout(function () { if (el.textContent === text) el.hidden = true; }, 7000);
    }
  }

  function position() {
    return (state.session ? state.session.offset : 0) + (video.currentTime || 0);
  }

  function enterPlayer() {
    $('landing').hidden = true;
    player.hidden = false;
    var every = Math.max(60, state.access.renew_after_seconds || 300) * 1000;
    state.renewTimer = setInterval(renew, every);
    state.progressTimer = setInterval(function () { if (!video.paused) report(); }, PROGRESS_EVERY_MS);
    state.duration = state.access.media.duration || 0;
    wakeChrome();
    startSession(savedPosition(state.duration));
  }

  // Le serveur construit ses URL d'après l'en-tête Host et le schéma qu'il
  // voit ; derrière un proxy TLS qui ne le dit pas, ce serait du http:// dans
  // une page https://. Seul le chemin sert : l'origine est celle de la page.
  function sameOrigin(url) {
    var parsed = new URL(url, location.href);
    return parsed.pathname + parsed.search;
  }

  function streamUrl(path, params) {
    var query = new URLSearchParams(Object.assign({ ticket: state.access.ticket }, params || {}));
    return '/api/v1/stream/' + state.access.media_id + path + '?' + query.toString();
  }

  function destroyPlayback() {
    if (state.hls) {
      try { state.hls.destroy(); } catch (e) { /* déjà détruite */ }
      state.hls = null;
    }
    var old = state.session;
    state.session = null;
    if (old) {
      fetch(streamUrl('/' + old.id), { method: 'DELETE', credentials: 'omit' }).catch(function () {
        // Le serveur la supprime de lui-même quand plus personne ne la lit.
      });
    }
  }

  function startSession(at) {
    var generation = ++state.generation;
    setLoading(true);
    state.ended = false;
    destroyPlayback();
    video.removeAttribute('src');

    var start = Math.max(0, Math.floor(at || 0));
    fetch(streamUrl('/start', { quality: QUALITY, start: String(start) }), {
      method: 'POST',
      credentials: 'omit'
    }).then(function (res) {
      if (!res.ok) {
        var err = new Error(res.status === 503
          ? 'Le serveur est occupé par d’autres lectures. Réessayez dans un moment.'
          : res.status === 401
            ? 'Ce lien n’est plus valide : la lecture ne peut pas reprendre.'
            : 'La lecture n’a pas pu démarrer. Rechargez la page.');
        err.status = res.status;
        throw err;
      }
      return res.json();
    }).then(function (session) {
      if (generation !== state.generation) return;
      state.session = { id: session.session_id, offset: session.start_offset || 0 };
      if (session.duration > 0) state.duration = session.duration;
      attach(sameOrigin(session.master_url), generation);
    }).catch(function (err) {
      if (generation !== state.generation) return;
      setLoading(false);
      showNotice(err.message || 'La lecture n’a pas pu démarrer.', true);
    });
  }

  function attach(url, generation) {
    var useHls = function () {
      return window.Hls && window.Hls.isSupported();
    };
    var go = function () {
      if (generation !== state.generation) return;
      if (useHls()) {
        var hls = new window.Hls(HLS_CONFIG);
        state.hls = hls;
        hls.on(window.Hls.Events.ERROR, function (_, data) {
          if (!data || !data.fatal || state.hls !== hls) return;
          if (data.type === window.Hls.ErrorTypes.NETWORK_ERROR) {
            var status = data.response && data.response.code;
            if (status === 401 || status === 404) {
              checkAccess(hls);
            } else {
              hls.startLoad();
            }
          } else if (data.type === window.Hls.ErrorTypes.MEDIA_ERROR) {
            hls.recoverMediaError();
          } else {
            showNotice('La lecture s’est interrompue. Rechargez la page.', true);
          }
        });
        hls.loadSource(url);
        hls.attachMedia(video);
      } else if (video.canPlayType('application/vnd.apple.mpegurl')) {
        video.src = url;
      } else {
        setLoading(false);
        showNotice('Ce navigateur ne sait pas lire cette vidéo. Essayez avec Chrome, Firefox ou Safari.', true);
        return;
      }
      play();
    };
    if (window.MediaSource || window.WebKitMediaSource) {
      loadHls().then(go);
    } else {
      go();
    }
  }

  function play() {
    var attempt = video.play();
    if (attempt && attempt.catch) {
      attempt.catch(function () {
        // Le navigateur refuse de lancer le son sans un geste : le prochain
        // appui sur Lecture le fournira.
        setLoading(false);
        updateToggle();
      });
    }
  }

  function seek(target) {
    var duration = state.duration || 0;
    target = Math.max(0, duration > 0 ? Math.min(target, duration - 1) : target);
    var local = target - (state.session ? state.session.offset : 0);
    var end = 0;
    if (video.seekable && video.seekable.length) {
      end = video.seekable.end(video.seekable.length - 1);
    }
    // Dans ce que la session a déjà produit : un simple déplacement. Au-delà,
    // ou avant son début, une nouvelle session repart de là.
    if (state.session && local >= 0 && local <= end - 1) {
      video.currentTime = local;
    } else {
      startSession(target);
    }
    updateTime(target);
  }

  // Un segment refusé veut dire un ticket mort : lien supprimé, expiré, ou
  // ticket arrivé à échéance. Le renouveler tranche entre relancer et
  // s'arrêter, au lieu de laisser hls.js réessayer sans fin.
  function checkAccess(hls) {
    api('renew', { viewer: state.access.viewer, ticket: state.access.ticket }).then(function () {
      if (state.hls === hls) hls.startLoad();
    }, function () {
      if (state.hls !== hls) return;
      destroyPlayback();
      setLoading(false);
      video.pause();
      clearInterval(state.renewTimer);
      showNotice('Ce lien a été supprimé ou a expiré : la lecture s’est arrêtée.', true);
    });
  }

  function renew() {
    if (!state.access) return;
    api('renew', { viewer: state.access.viewer, ticket: state.access.ticket }).then(function (res) {
      state.access.expires_at = res.expires_at;
    }, function (err) {
      if (err.status === 404 || err.status === 410 || err.status === 409 || err.status === 401) {
        clearInterval(state.renewTimer);
        showNotice('Ce lien n’est plus valide : la lecture s’arrêtera bientôt.', true);
      }
    });
  }

  function report() {
    if (!state.access || !state.session) return;
    var at = Math.floor(position());
    api('progress', {
      viewer: state.access.viewer,
      ticket: state.access.ticket,
      position_seconds: at,
      duration_seconds: Math.floor(state.duration || 0)
    }).then(function (res) {
      if (res && res.consumed && !state.consumed) {
        state.consumed = true;
        if (state.access.media.single_use) {
          showNotice('Ce lien à usage unique est maintenant détruit. Vous pouvez finir la lecture.');
        }
      }
    }, function () { /* Une position perdue sera renvoyée au prochain tour. */ });
  }

  // ------------------------------------------------------------ Chrome

  function updateTime(at) {
    var now = typeof at === 'number' ? at : position();
    var duration = state.duration || 0;
    $('time').textContent = formatTime(now) + ' / ' + formatTime(duration);
    if (!state.dragging && duration > 0) {
      $('seek').value = String(Math.round((now / duration) * 1000));
    }
  }

  function updateToggle() {
    var paused = video.paused;
    $('toggle-icon').setAttribute('d', paused ? 'M8 5.5v13l11-6.5z' : 'M7 5h4v14H7zm6 0h4v14h-4z');
    $('toggle').setAttribute('aria-label', paused ? 'Lecture' : 'Pause');
  }

  function updateMute() {
    $('mute-icon').setAttribute('d', video.muted
      ? 'M4 9v6h4l5 5V4L8 9H4zm12.6 3 2.7-2.7-1.4-1.4-2.7 2.7-2.7-2.7-1.4 1.4 2.7 2.7-2.7 2.7 1.4 1.4 2.7-2.7 2.7 2.7 1.4-1.4z'
      : 'M4 9v6h4l5 5V4L8 9H4zm12.5 3a4.5 4.5 0 0 0-2.5-4v8a4.5 4.5 0 0 0 2.5-4z');
    $('mute').setAttribute('aria-label', video.muted ? 'Rétablir le son' : 'Couper le son');
  }

  function wakeChrome() {
    player.classList.remove('idle');
    clearTimeout(state.idleTimer);
    state.idleTimer = setTimeout(function () {
      if (!video.paused && !state.dragging) player.classList.add('idle');
    }, CHROME_IDLE_MS);
  }

  function togglePlay() {
    if (video.paused) {
      if (state.ended) {
        startSession(0);
      } else {
        play();
      }
    } else {
      video.pause();
    }
  }

  function toggleFullscreen() {
    var doc = document;
    if (doc.fullscreenElement || doc.webkitFullscreenElement) {
      (doc.exitFullscreen || doc.webkitExitFullscreen).call(doc);
    } else if (player.requestFullscreen) {
      player.requestFullscreen().catch(function () { /* refusé */ });
    } else if (player.webkitRequestFullscreen) {
      player.webkitRequestFullscreen();
    } else if (video.webkitEnterFullscreen) {
      // iPhone : seule la vidéo elle-même passe en plein écran.
      video.webkitEnterFullscreen();
    }
  }

  video.addEventListener('timeupdate', function () {
    updateTime();
    var now = position();
    if (Math.abs(now - state.lastSaved) >= 5) {
      state.lastSaved = now;
      storage.set(positionKey, String(Math.floor(now)));
    }
  });
  video.addEventListener('playing', function () { setLoading(false); updateToggle(); wakeChrome(); });
  video.addEventListener('waiting', function () { setLoading(true); });
  video.addEventListener('pause', function () { updateToggle(); wakeChrome(); report(); });
  video.addEventListener('play', updateToggle);
  video.addEventListener('volumechange', updateMute);
  video.addEventListener('ended', function () {
    state.ended = true;
    storage.remove(positionKey);
    report();
    updateToggle();
    wakeChrome();
  });

  var seekBar = $('seek');
  seekBar.addEventListener('input', function () {
    state.dragging = true;
    updateTime((seekBar.value / 1000) * (state.duration || 0));
  });
  seekBar.addEventListener('change', function () {
    state.dragging = false;
    seek((seekBar.value / 1000) * (state.duration || 0));
  });

  $('toggle').addEventListener('click', togglePlay);
  $('back10').addEventListener('click', function () { seek(position() - 10); });
  $('fwd10').addEventListener('click', function () { seek(position() + 10); });
  $('mute').addEventListener('click', function () { video.muted = !video.muted; });
  $('fullscreen').addEventListener('click', toggleFullscreen);
  video.addEventListener('click', togglePlay);
  video.addEventListener('dblclick', toggleFullscreen);
  player.addEventListener('mousemove', wakeChrome);
  player.addEventListener('touchstart', wakeChrome, { passive: true });

  document.addEventListener('keydown', function (event) {
    if (player.hidden || event.target.tagName === 'INPUT' && event.target !== seekBar) return;
    var handled = true;
    switch (event.key) {
      case ' ':
      case 'k':
        togglePlay();
        break;
      case 'ArrowLeft':
        seek(position() - 10);
        break;
      case 'ArrowRight':
        seek(position() + 10);
        break;
      case 'f':
        toggleFullscreen();
        break;
      case 'm':
        video.muted = !video.muted;
        break;
      default:
        handled = false;
    }
    if (handled) {
      event.preventDefault();
      wakeChrome();
    }
  });

  // La page se ferme : le ticket est révoqué tout de suite plutôt qu'à son
  // échéance, et le serveur arrête la session qui le portait.
  window.addEventListener('pagehide', function () {
    if (!state.access) return;
    storage.set(positionKey, String(Math.floor(position())));
    var body = JSON.stringify({ code: code, ticket: state.access.ticket });
    if (navigator.sendBeacon) {
      navigator.sendBeacon('/api/shared/close', new Blob([body], { type: 'application/json' }));
    }
  });

  window.addEventListener('hashchange', function () { location.reload(); });

  init();
})();
