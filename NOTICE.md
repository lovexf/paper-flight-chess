# 授权与致谢 / License & Attribution

本仓库是《极简飞行棋》的 **Godot 4 重制版**，规则、棋盘坐标与原始视觉资产来自下方的 MinimalistAeroplaneChess 项目。

## 本项目授权：AGPL-3.0

本作品采用 **GNU Affero 通用公共许可证第 3 版（AGPL-3.0）**，全文见 [LICENSE](./LICENSE)。

选择 AGPL-3.0 的原因：本项目的规则引擎移植自下方开源项目，按 Copyleft 要求，
**衍生作品必须以相同许可证发布，并向使用者提供完整源代码**。

### 这对使用者意味着什么

| 场景 | 义务 |
|---|---|
| 自己玩 / 朋友间互相安装 | 无需做任何事 |
| 把安装包发给别人 | 需同时提供**完整源代码**（本仓库即为源码） |
| 修改后再分发 | 修改后的版本同样必须是 AGPL-3.0，且提供源码 |
| 架设服务器供他人游玩 | 需向使用者提供源码（AGPL 的网络条款） |

---

## 第三方来源

### 1. MinimalistAeroplaneChess（规则引擎 + 棋盘坐标）

- **项目**：https://github.com/ZTMYO/MinimalistAeroplaneChess
- **作者**：ZTMYO
- **授权**：AGPL-3.0
- **本项目使用的内容**：
  - `scripts/engine.gd` —— **移植自**该项目的 `shared/engine.mjs`
  - `data/board_classic_52.json` —— 棋盘的 52 格逐格坐标**提取自**该项目 `frontend/game.html` 的 SVG `<use>` 元素
  - 规则常量（`RING_LEN` / `RING_ENTRY` / `JUMP_RELS` / `FLY_ENTRY` / `FLY_EXIT` / `CROSS_STEP`）来自该项目

**致谢**：该项目的规则引擎把"跳子 / 飞棋 / 叠子 / 交叉点阻挡"这些边界情况处理得很完整，
为本次移植省下了大量试错时间。原项目的 52 格坐标表也让棋盘得以精确复刻。

### 2. Godot Engine

- **项目**：https://godotengine.org
- **授权**：MIT
- 本项目的游戏引擎。

---

## 移植说明

`scripts/engine.gd` 是 `shared/engine.mjs` 的 **GDScript 移植版本**，不是独立实现。
移植过程中保持了原有的函数划分与判定顺序，以便与原项目逐条比对。

已知的编号差异：原项目 SVG 把外圈第 51、52 格标注为 `-3`、`-2`（表示"1 号玩家到不了"），
而引擎的 `cellOf()` 返回 51、52。本项目在棋盘数据中同时保留两套编号
（`cpos` 用引擎编号，`svgCpos` 保留 SVG 原始标注）。
