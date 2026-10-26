# CCB 工具箱 MOD Check 当前状态

更新：2026-10-26；分支 `feature/ccb2-modcheck-loader`。

本轮用户已批准公共 Civ6DllLoader + Global 扫描插件路线，替代先前独立 dxgi 载体/安装器方案。保留 GUID `a7026192-7310-4733-a297-9f90564b6466`，最终 `.modinfo` 版本 202，显示 `2.0.2-dev`；首包 201 的实机接口差异已修正并重新部署。

## 实现位置

- `MPH/ModCheck/CCBModCheckController.lua`：房间轮次、成员状态、超时、提醒和按需详单。
- `MPH/ModCheck/CCBModCheckProtocol.lua`：有界序列化、分片和请求/连接绑定。
- `MPH/ModCheck/CCBModCheckStaging.lua`：原生房间适配，三色灯、检查按钮和单条原因。
- `MPH/ModCheck/CCBModCheckMainMenu.lua`：主菜单词缀、当前接口检测和首装提示。
- `MPH/ModCheck/UI/`：当前官方前端基线副本；由 `tools/modcheck_frontend.py` 生成。
- 相邻 `A-C6-Mod/PVPCore/src/ccb_modcheck/`：独立 Global 插件，不链接旧代理和上传业务。
- 相邻 `A-C6-Mod/PVPCore/vendor/Civ6DllLoader/`：固定公共依赖，安装安全修补和版本选举仍沿用公共协议。

## 验收状态

实现与本地包已交付：公共1.0.1安装/选举56项、扫描0.1.1核心206项、Lua接口44项、生产DLL模拟宿主352项、多节点25场景及前端适配门禁通过。DX12实测主菜单词缀、房间模块加载和进入局域网房间；当前未检测到已安装核心，尚未执行真实首装和重启闭环。完整记录见 [docs/MODCheck-acceptance-2026-10-26.md](docs/MODCheck-acceptance-2026-10-26.md)。

需要分别取得证据：实际首装和重启、主菜单/房间接口、DX11/DX12、独立双机、迁移后的城邦缔造者/GhostFix 组合。离线通过不能替代上述验收；旧 GameCore 代理版不计入兼容通过。公开依赖再分发依据仍待确认，本轮不发布工坊。

## 本地交付与回退

`tools/package_modcheck.py` 生成 `torelease/CCB工具箱2.0`、带时间戳的 `release/*.zip` 及 `build/modcheck-delivery-*.json`。实际部署与回滚路径以最新交付报告为准。备份必须留在 Mods 之外，防止游戏扫描到重复 GUID。

最新包 `release/CCBToolkits_2.0.2-dev_20261026-202356.zip`，118文件四份哈希一致；报告 `build/modcheck-delivery-20261026-202356.json`。原版200回退副本 `D:/A-Developing/tmp/ccb-modcheck-rollback/20261026-201037-local-mod`。原生源码已提交 `PVPCore/f8502f8`；两仓均在实施分支，未推送。
