# MOD Check 本地实施与分层验收

日期：2026-10-26。工具箱分支 `feature/ccb2-modcheck-loader`，版本 `2.0.2-dev` / 202；GUID 保持 `a7026192-7310-4733-a297-9f90564b6466`。原生源提交 `PVPCore/f8502f8`，扫描插件 `0.1.1.0`，公共 Shell/Runtime `1.0.1`。

## 已实现

- 公共加载器安全安装/更新：拒绝外来 version.dll、不清理持久备份、失败回滚；1.0.1 依原协议优先于旧 1.0.0。
- 独立 Global 扫描插件，使用 RegisterGlobalScript；只暴露 GetInfo、BeginScan、PollScan、CancelScan，不链接旧代理、上传或账号模块。
- 当前房间 ID 集合限定扫描范围，SQLite 只定位唯一副本及其版本；多路径、多版本、读取/枚举失败、覆盖空白、扫描中变化和取消均不能产生一致资格。两遍 fresh SHA-256，不复用 size/mtime 内容缓存；Unicode 路径不转 ANSI。
- 原玩家行准备圆钮左侧灯、房主检查/客机重查、单条原因、按需逐 Mod 详单、探针与扫描分离超时、提醒去重/限速、连接 token 与请求绑定、旧包拒绝和有界发送队列。
- 主菜单独立词缀与首装说明，1Hz/20次检测当前接口；不通过检测触发扫描。

## 实际运行的门禁

| 层 | 结果 | 证据 |
|---|---|---|
| 公共安装安全、旧版/多候选选举 | 56 检查，0 失败 | PVPCore/build/shared_loader/install_policy_tests.log |
| 生产扫描、Unicode、同元数据变更、歧义、取消、版本缺省等 | 206 检查，0 失败 | PVPCore/build/ccb_modcheck/scanner_test.log |
| C++ Lua 接口返回及参数契约 | 44 检查，0 失败 | PVPCore/build/ccb_modcheck/lua_test.log |
| 真实 DLL + 模拟 HookAPI 宿主动态装载/卸载 | 352 检查，0 失败 | PVPCore/build/shared_loader/modcheck_host_smoke.log |
| 生产协议/控制器多节点模拟 | 25 场景，0 失败 | build/modcheck-tests.log |
| 房间/菜单适配及真实控制器，含无 rawget/_G 环境 | 通过 | tests/frontend/test_frontend.py |
| 新 Lua 与当前原生基线的语法 | 7/7 通过 | 知识库 tools/lua_check.cjs |
| 房间 XML 样式/字体 | 0 error / 0 warn | 知识库 tools/ui-corpus/lint.js |
| 主菜单 XML | 未新增 lint error；继承官方的 auto ScrollPanel 提示 | 与官方 MainMenu.xml 对照 |

多节点模拟没有经过 Civ6 网络；动态宿主也没有经过真实公共 Runtime/游戏 Lua 注册点。

## DX12 实机证据与修正

1. 首包 201 的主菜单已显示 `CCB 工具箱 2.0.1-dev | 未检测到核心`；发现实际 HavokScript 没有 rawget/_G，控制器导入失败，已改直接全局引用并加入回归。
2. 实测 GetEnabledMods 元素只有 Id/Title/Official，GetInstalledMods/GetModInfo 及 GetModProperty("Version") 不给版本。四个 API 不变，BeginScan 允许缺省 version；原生证明安装副本唯一后读取实际版本并纳入结果/总哈希，不从磁盘启用组补充清单。
3. 重启包 202 后，FireTuner 确认 MainMenu 词缀为 `CCB 工具箱 2.0.2-dev | 未检测到核心`；StagingRoom 内 Controller、Protocol、Staging 三个模块均为 table，两个新增主控件存在。
4. 通过官方 OnLANGame → OnHostButtonClick → OnConfirmClick 创建了风云变幻局域网房间；Lua.log 记录 OnJoinGameComplete、StagingRoom/CheckGameAutoStart，未再出现生产 CCB 脚本加载错误。进入多人后 FireTuner 关闭，不能继续读取灯号和控件状态。

日志在 `build/acceptance/20261026-first-run` 与 `build/acceptance/20261026-dx12-room`。日志中有探测命令自身使用错误枚举名 ServerTypes 的报错；它来自 Tuner 字符串，不是产品脚本，也不作为通过证据。未调用真实网络聊天提醒、未进入实际对局、未直接安装游戏目录的 Runtime。

## 交付

- 本地包：`release/CCBToolkits_2.0.2-dev_20261026-202356.zip`。
- SHA-256：`93738c93efb66cb10d996f4c2300a20d41b604909fa83f91294f504de24b1e1f`。
- 完整报告：`build/modcheck-delivery-20261026-202356.json`。
- 118 文件的源码、staging、ZIP 解包内容、部署 SHA 完全一致，本地 Mods 中 GUID 仅一份；工坊订阅区搜索也没有第二份该 GUID。
- 原开发前版本 200 回退副本：`D:/A-Developing/tmp/ccb-modcheck-rollback/20261026-201037-local-mod`。后续包 201 及 staging 也保留在该回退目录，未放进 Mods。

上游 BRS/NHK 保留原样：报告记录 2 处既有 XML 标准解析问题和 9 处 BOM；只有 Git 对比证明与 375e9cd 基线完全相同才允许作为既有警告。新增/修改 XML 和所有新前端文件均不享受此豁免。该记录不代表这些旧模块重新做过完整兼容验收。

## 尚未验收

- 公共 Shell 的真实首次进入 XP2 安装、完全重启、Global 插件注册到真实游戏 Lua，以及卸载/更新闭环。
- DX11 实机、各 UI 缩放、8/12+ 槽位、长名字/滚动/观察者的完整视觉与交互。
- 独立双机的绿/红/黄、同版本不同内容、真实消息送达、重连/换房主/槽位复用、无工具箱/缺核心与提醒去重。
- 迁移后的城邦缔造者/GhostFix 与示例插件组合；旧 GameCore 代理版不能计为兼容通过。
- 公共依赖再分发授权。本轮没有工坊发布，也没有推送到远端。
