// Keep queue progression outside the iframe's automatic playlist advancement.
class NeedleQueue {
  constructor(ids = []) {
    this.original = ids.slice();
    this.remote = ids.slice();
    this.items = ids.slice();
    this.index = 0;
    this.repeat = "off";
    this.shuffled = false;
  }
  get current() { return this.items[this.index]; }
  ended() {
    if (!this.items.length) return false;
    if (this.repeat === "one") return true;
    if (this.index + 1 < this.items.length) { this.index++; return true; }
    if (this.repeat === "all") { this.index = 0; return true; }
    return false;
  }
  step(delta) {
    if (!this.items.length) return false;
    const next = this.index + delta;
    if (next >= 0 && next < this.items.length) this.index = next;
    else if (this.repeat === "all") this.index = (next + this.items.length) % this.items.length;
    else return false;
    return true;
  }
  shuffle(enabled, random = Math.random) {
    const current = this.current;
    this.shuffled = enabled;
    this.items = this.original.slice();
    if (enabled) {
      this.items.splice(this.items.indexOf(current), 1);
      for (let i = this.items.length - 1; i > 0; i--) {
        const j = Math.floor(random() * (i + 1));
        [this.items[i], this.items[j]] = [this.items[j], this.items[i]];
      }
      this.items.unshift(current);
    }
    this.index = Math.max(0, this.items.indexOf(current));
  }
  move(from, to) {
    if (from < 0 || to < 0 || from >= this.items.length || to >= this.items.length) return;
    const currentIndex = this.index;
    this.items.splice(to, 0, this.items.splice(from, 1)[0]);
    if (from === currentIndex) this.index = to;
    else if (from < currentIndex && to >= currentIndex) this.index--;
    else if (from > currentIndex && to <= currentIndex) this.index++;
    this.original = this.items.slice();
    this.shuffled = false;
  }
  sync(ids) {
    if (!ids.length || JSON.stringify(ids) === JSON.stringify(this.remote)) return false;
    const current = this.current;
    const remaining = ids.slice();
    this.remote = ids.slice();
    this.original = ids.slice();
    if (this.shuffled) {
      this.items = this.items.filter(id => {
        const i = remaining.indexOf(id);
        if (i < 0) return false;
        remaining.splice(i, 1);
        return true;
      }).concat(remaining);
    } else this.items = ids.slice();
    this.index = Math.max(0, this.items.indexOf(current));
    return this.current !== current;
  }
}

if (typeof module !== "undefined") module.exports = NeedleQueue;

if (typeof window !== "undefined" && window.needleConfig) {
  const config = window.needleConfig;
  const post = data => window.webkit.messageHandlers.playback.postMessage({...data, session:config.session});
  let player, queue = new NeedleQueue(config.videoID ? [config.videoID] : []);
  let ready = false, bootstrapped = !!config.videoID, transitioning = false;
  let probe = null, probeTimeout = null;
  function showCurrent(playing = true, seconds = 0) {
    if (!queue.current) return;
    transitioning = true;
    post({quality:""});
    player[playing ? "loadVideoById" : "cueVideoById"]({videoId:queue.current, startSeconds:seconds});
  }
  function report() {
    if (!ready) return;
    if (!bootstrapped) {
      const ids = player.getPlaylist() || [];
      if (!ids.length) return;
      queue = new NeedleQueue(ids);
      bootstrapped = true;
      showCurrent(false);
    }
    const data = player.getVideoData() || {};
    const matches = data.video_id === queue.current;
    post({
      state:player.getPlayerState(), current:matches ? player.getCurrentTime() : 0,
      duration:matches ? player.getDuration() : 0,
      title:matches ? data.title || "" : "", artist:matches ? data.author || "YouTube" : "YouTube",
      videoID:queue.current || "", playlist:config.playlistID ? queue.items : [], index:queue.index,
      repeat:queue.repeat, shuffled:queue.shuffled, ready:bootstrapped
    });
  }
  function stateChanged(event) {
    if (!bootstrapped) { report(); return; }
    if ([1, 5].includes(event.data)) transitioning = false;
    if (event.data === 0 && !transitioning) {
      transitioning = true;
      if (queue.ended()) showCurrent(true);
    }
    report();
  }
  window.onYouTubeIframeAPIReady = () => {
    player = new YT.Player("player", {
      videoId:config.videoID || "",
      playerVars:{...(config.playlistID ? {listType:"playlist",list:config.playlistID} : {}),
        playsinline:1, controls:0, rel:0, origin:"https://app.codex.needle", widget_referrer:"https://app.codex.needle/"},
      events:{onReady:() => { ready = true; report(); },
        onPlaybackQualityChange:({data,target}) => {
          if (target.getVideoData()?.video_id !== queue.current) return;
          const labels = {small:"240p", medium:"360p", large:"480p", hd720:"720p", hd1080:"1080p",
            hd1440:"1440p", hd2160:"4K", hd2880:"2880p", hd4320:"8K", highres:"고해상도"};
          post({quality:labels[data] || ""});
        },
        onStateChange:stateChanged, onError:e => post({error:e.data})}
    });
  };
  window.needle = {
    play:() => { if (ready) player.getPlayerState() === 1 ? player.pauseVideo() : player.playVideo(); },
    seek:seconds => {
      if (!ready || !Number.isFinite(seconds) || player.getDuration() <= 0) return;
      player.seekTo(Math.max(0, Math.min(seconds, player.getDuration())), true);
    },
    step:delta => {
      if (!ready || !bootstrapped) return;
      if (!config.playlistID) window.needle.seek(player.getCurrentTime() + delta * 10);
      else if (queue.step(delta)) showCurrent();
    },
    select:index => {
      if (!ready || !Number.isInteger(index) || index < 0 || index >= queue.items.length) return;
      queue.index = index; showCurrent(); report();
    },
    repeat:mode => { if (["off","one","all"].includes(mode)) queue.repeat = mode; report(); },
    shuffle:enabled => { if (queue.items.length > 1) queue.shuffle(enabled); report(); },
    move:(from,to) => { queue.move(from,to); report(); }
  };
  function cleanupProbe() {
    clearTimeout(probeTimeout);
    if (probe) probe.destroy();
    probe = null;
    document.getElementById("sync-probe").replaceChildren();
  }
  function refreshRemotePlaylist() {
    if (!ready || !bootstrapped || !config.playlistID || probe) return;
    const host = document.getElementById("sync-probe");
    host.innerHTML = '<div id="sync-player"></div>';
    probe = new YT.Player("sync-player", {
      width:200,height:200,
      playerVars:{listType:"playlist",list:config.playlistID,autoplay:0,origin:"https://app.codex.needle"},
      events:{onReady:() => {
        const read = () => {
          if (!probe) return;
          const ids = probe.getPlaylist() || [];
          if (!ids.length) { setTimeout(read,250); return; }
          const playing = player.getPlayerState() === 1;
          if (queue.sync(ids)) showCurrent(playing);
          cleanupProbe(); report();
        };
        read();
      }, onError:cleanupProbe}
    });
    probeTimeout = setTimeout(cleanupProbe,10000);
  }
  setInterval(report,250);
  setInterval(refreshRemotePlaylist,30000);
}
