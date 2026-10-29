# 玩家头像资源（avatar_1.svg ~ avatar_20.svg）

- 来源：同仓库的 Web 版项目 `feixinqi-web` —— `frontend/assets/emojis.js` 中的表情 SVG（20 个：smile/sad/faintsmile/cute/surprised/angry/dead/sorrow/happy/nerd/wink/sweat/grin/cool/cry/naughty/scorn/speechless/kiss/bot）。
- 处理：从 emojis.js 抽取原 SVG，`currentColor` 改为白色 `#ffffff`，尺寸统一为 160×160（viewBox 0 0 20 20），供本项目按玩家色圆形底 + 白色表情绘制。
- 版权与许可：素材属于 `feixinqi-web` 项目，项目根目录 LICENSE 为 **GNU AGPL v3**（README 标注 GPLv3，具体以 [feixinqi-web/LICENSE](../../../../feixinqi-web/LICENSE) 为准）。本项目与 Web 版为同一作者作品，复用时保留此出处说明；如对外分发请遵循 AGPL/GPL 条款。
- 顺序对应：avatar_1=smile、avatar_2=sad … avatar_20=bot（与 web `emojis.js` 中定义顺序一致）。