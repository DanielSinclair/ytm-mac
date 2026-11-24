// Injected into music.youtube.com. Bridges playback state to the native app
// and exposes window.__ytm for native commands.
(() => {
  if (window.__ytm) return;
  const post = (m) => window.webkit?.messageHandlers?.ytm?.postMessage(m);
  const video = () => document.querySelector('video');
  const player = () => document.getElementById('movie_player');
  const click = (sel) => document.querySelector(sel)?.click();

  const syncSlider = (v) => {
    for (const id of ['#volume-slider', '#expand-volume-slider']) {
      const s = document.querySelector(id);
      if (s) s.value = String(v > 0 && v < 5 ? 5 : v);
    }
  };

  window.__ytm = {
    play: () => video()?.play(),
    pause: () => video()?.pause(),
    toggle: () => { const v = video(); if (v) v.paused ? v.play() : v.pause(); },
    next: () => click('.next-button'),
    previous: () => click('.previous-button'),
    seek: (t) => { const v = video(); if (v) v.currentTime = t; },
    volume: (delta) => {
      const p = player();
      if (!p?.setVolume) return;
      const v = Math.max(0, Math.min(100, p.getVolume() + delta));
      p.setVolume(v);
      if (v > 0 && p.isMuted?.()) p.unMute();
      syncSlider(v);
    },
    // Opens YTM's own Settings dialog via the avatar (or ⋮) menu.
    settings: async () => {
      document.querySelector('ytmusic-settings-button #button')?.click();
      for (let i = 0; i < 30; i++) {
        await new Promise((r) => setTimeout(r, 100));
        const item = [...document.querySelectorAll('ytd-compact-link-renderer')]
          .find((e) => e.data?.icon?.iconType === 'SETTINGS');
        if (item) { (item.querySelector('tp-yt-paper-item') || item).click(); return; }
      }
    },
  };

  let last = '';
  const report = () => {
    const v = video();
    const md = navigator.mediaSession?.metadata;
    if (!v || !md) return;
    const art = md.artwork?.length ? md.artwork[md.artwork.length - 1].src : '';
    const state = {
      title: md.title || '',
      artist: md.artist || '',
      album: md.album || '',
      artwork: art,
      duration: Number.isFinite(v.duration) ? v.duration : 0,
      position: v.currentTime || 0,
      playing: !v.paused,
    };
    // Throttle: only post on track/state change or every ~5s of position.
    const key = `${state.title}|${state.playing}|${Math.floor(state.position / 5)}`;
    if (key === last) return;
    last = key;
    post(state);
  };

  const hook = (v) => {
    if (v.__ytmHooked) return;
    v.__ytmHooked = true;
    for (const e of ['play', 'pause', 'seeked', 'loadedmetadata', 'durationchange', 'timeupdate']) {
      v.addEventListener(e, () => { if (e !== 'timeupdate') last = ''; report(); });
    }
  };

  // Window chrome: push the nav bar below the traffic lights (not in full screen),
  // hide scrollbars, and let empty nav-bar space drag/zoom the window like a title bar.
  const style = document.createElement('style');
  style.textContent = `
    html:not(.ytm-fullscreen) ytmusic-app-layout#layout { --ytmusic-nav-bar-height: 80px !important; }
    html:not(.ytm-fullscreen) ytmusic-nav-bar { padding-top: 16px !important; }
    html, * { scrollbar-width: none !important; }
    ::-webkit-scrollbar { display: none !important; width: 0 !important; height: 0 !important; }
    ytmusic-cast-button { display: none !important; }`;
  document.head.appendChild(style);
  const chrome = (m) => window.webkit?.messageHandlers?.ytmWindow?.postMessage(m);
  const isBar = (t) => t?.matches?.('ytmusic-nav-bar, ytmusic-nav-bar > .left-content, ytmusic-nav-bar > .center-content, ytmusic-nav-bar > .right-content');
  document.addEventListener('mousedown', (e) => { if (e.button === 0 && e.detail === 1 && isBar(e.target)) chrome('drag'); }, true);
  document.addEventListener('dblclick', (e) => { if (isBar(e.target)) chrome('zoom'); }, true);

  // Login state, from YTM's own config plus its "Sign back in" dialog (shown when
  // the session dies while the page is open). Reported to the app on change.
  let lastAuth = null;
  const signBackIn = () => [...document.querySelectorAll('tp-yt-paper-dialog')].some((d) =>
    d.opened && /signInEndpoint|ServiceLogin/.test(JSON.stringify(d.querySelector('yt-confirm-dialog-renderer')?.data || {})));
  setInterval(() => {
    const loggedIn = window.ytcfg?.get?.('LOGGED_IN');
    const auth = loggedIn === false || signBackIn() ? 'signedOut' : loggedIn === true ? 'signedIn' : null;
    if (auth && auth !== lastAuth) { lastAuth = auth; chrome('auth:' + auth); }
  }, 3000);

  // Start with the sidebar collapsed, once: YTM remembers the user's choice
  // afterwards in its PREF cookie (guide_collapsed=true).
  const collapseGuideOnce = setInterval(() => {
    const button = document.querySelector('ytmusic-nav-bar #guide-button');
    if (!button) return;
    clearInterval(collapseGuideOnce);
    try {
      if (localStorage.getItem('ytmMacGuideInit')) return;
      localStorage.setItem('ytmMacGuideInit', '1');
    } catch { return; }
    if (!/guide_collapsed=true/.test(document.cookie)) button.click();
  }, 500);

  // Cheap poll instead of a subtree MutationObserver (YTM mutates constantly).
  setInterval(() => { const v = video(); if (v) hook(v); }, 1000);
})();
