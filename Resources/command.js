// Isla · 播放控制
// 用法：osascript -l JavaScript command.js <0|1|2|4|5>
// 0 播放 / 1 暂停 / 2 切换 / 4 下一首 / 5 上一首
ObjC.import('Foundation');

function run(argv) {
  const cmd = parseInt(argv[0] || '2', 10);
  const bundle = $.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/');
  if (!bundle || !bundle.load) return;

  const Controller = $.NSClassFromString('MRNowPlayingController');
  if (!Controller) return;

  const controller = Controller.localRouteController;
  if (!controller) return;

  const options = $.NSDictionary.alloc.init;
  controller.sendCommandOptionsCompletion(cmd, options, null);
}
