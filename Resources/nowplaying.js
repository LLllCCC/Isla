// Isla · 正在播放读取器
// 由 /usr/bin/osascript 执行（平台二进制，可穿透 macOS 15.4+ 对 MediaRemote 的签名门禁）。
// 输出：一行 JSON。无会话时输出 {"none":true}。
//
// 字段说明（为什么同时给「位置」和「锚点」两套）：
//   elapsed       = calculatedPlaybackPosition，MediaRemote 用「锚点 + 流逝时间 × rate」算出来的
//                   外推值。播放时它一直在走；暂停时只要播放器没上报 rate=0，它照样走——
//                   所以不能单独拿它判断「到底有没有在播」。
//   anchorElapsed = 播放器最后一次上报的原始位置（elapsedTime）。
//   anchorAge     = 距那次上报过了多少秒（now - elapsedTimeTimestamp）。
//                   anchorAge 持续增长 = 播放器没再上报过，我们只能靠外推。
//   rate          = 播放器上报的播放速率。QQ 音乐暂停后仍可能保持 1（实测），只能当参考。
//   pid / bundle  = 播放器进程，用来做「进程还活着吗」「这个进程还在出声吗」两道硬校验。
ObjC.import('Foundation');

function emit(obj) {
  const s = JSON.stringify(obj) + "\n";
  const d = $(s).dataUsingEncoding($.NSUTF8StringEncoding);
  $.NSFileHandle.fileHandleWithStandardOutput.writeData(d);
}

function str(v) {
  try {
    if (v === null || v === undefined) return '';
    if (v.js !== undefined) return String(v.js);
    return String(v);
  } catch (e) {
    return '';
  }
}

function num(v) {
  const n = Number(str(v));
  return isFinite(n) ? n : 0;
}

function run() {
  const bundle = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/');
  if (!bundle || !bundle.load) { emit({ error: 'framework' }); return; }

  const Req = $.NSClassFromString('MRNowPlayingRequest');
  if (!Req) { emit({ error: 'class' }); return; }

  let item = null;
  try { item = Req.localNowPlayingItem; } catch (e) { item = null; }
  if (!item) { emit({ none: true }); return; }

  const md = item.metadata;
  if (!md) { emit({ none: true }); return; }

  let app = '';
  let pid = 0;
  let bundleID = '';
  try {
    const client = Req.localNowPlayingPlayerPath.client;
    app = str(client.displayName);
    bundleID = str(client.bundleIdentifier);
    pid = num(client.processIdentifier);
  } catch (e) {}

  const now = $.NSDate.date.timeIntervalSinceReferenceDate;
  const anchorAt = num(md.elapsedTimeTimestamp);

  emit({
    title: str(md.title),
    artist: str(md.trackArtistName) || str(md.artist),
    album: str(md.albumName),
    duration: num(md.duration),
    elapsed: num(md.calculatedPlaybackPosition),
    anchorElapsed: num(md.elapsedTime),
    anchorAge: anchorAt > 0 ? Math.max(0, now - anchorAt) : -1,
    rate: num(md.playbackRate),
    live: str(md.isAlwaysLive) === '1',
    app: app,
    bundle: bundleID,
    pid: pid
  });
}
