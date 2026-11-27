const assert = require("node:assert/strict");
const vm = require("node:vm");
const fs = require("node:fs");
const messages = [], calls = [], intervals = [];
let main, probe;
class Player {
  constructor(id, options) {
    this.options = options; this.state = 5; this.video = "a"; this.time = 0;
    if (id === "player") main = this; else probe = this;
  }
  getPlaylist() { return ["a", "b", "c"]; }
  getVideoData() { return {video_id:this.video, title:this.video, author:"channel"}; }
  getPlayerState() { return this.state; }
  getCurrentTime() { return this.time; }
  getDuration() { return 100; }
  cueVideoById(value) { this.load(value); }
  loadVideoById(value) { this.load(value); }
  load(value) { this.video = value.videoId; this.time = value.startSeconds; calls.push(value); }
  playVideo() { this.emit(1); }
  pauseVideo() { this.emit(2); }
  seekTo(value, ahead) { this.time = value; assert.equal(ahead,true); }
  emit(state) { this.state = state; this.options.events.onStateChange({data:state}); }
  destroy() {}
}
const context = {
  window:{needleConfig:{playlistID:"test",session:"session"},
    webkit:{messageHandlers:{playback:{postMessage:data => messages.push(data)}}}},
  YT:{Player}, document:{getElementById:() => ({replaceChildren(){}})},
  setInterval:(fn,ms) => intervals.push({fn,ms}), setTimeout:() => 1, clearTimeout(){}
};
vm.runInNewContext(fs.readFileSync(require.resolve("../Sources/Needle/Resources/Player.js"),"utf8"),context);
context.window.onYouTubeIframeAPIReady(); main.options.events.onReady(); main.emit(5);
const controls = context.window.needle;
const last = () => messages.at(-1);
assert.equal(last().ready,true); assert.equal(last().session,"session");
controls.play(); assert.equal(main.state,1);
controls.play(); assert.equal(main.state,2);
controls.seek(70); assert.equal(main.time,70); assert.equal(main.state,2);
controls.seek(-10); assert.equal(main.time,0);
controls.seek(120); assert.equal(main.time,100);
controls.seek(NaN); assert.equal(main.time,100);
controls.repeat("one"); main.emit(1); main.emit(0);
assert.equal(calls.at(-1).videoId,"a"); assert.equal(calls.at(-1).startSeconds,0);
const repeatCalls = calls.length;
main.emit(0); assert.equal(calls.length,repeatCalls); // Duplicate ended must not advance twice.
main.emit(1); controls.step(1); main.emit(1);
assert.equal(last().videoID,"b");
controls.repeat("off"); controls.select(2); main.emit(1);
const beforeEnd = calls.length; main.emit(0);
assert.equal(calls.length,beforeEnd); assert.equal(last().videoID,"c");
controls.repeat("all"); main.emit(1); main.emit(0);
assert.equal(calls.at(-1).videoId,"a"); main.emit(1);
controls.shuffle(true);
const order = JSON.stringify(last().playlist), beforeSync = calls.length;
intervals.find(value => value.ms === 30000).fn(); probe.options.events.onReady();
assert.equal(JSON.stringify(last().playlist),order);
assert.equal(last().shuffled,true); assert.equal(calls.length,beforeSync);
controls.shuffle(false); assert.equal(JSON.stringify(last().playlist),'["a","b","c"]');
console.log("Player bridge checks passed: seek, pause, repeat events, next, shuffle and refresh.");
