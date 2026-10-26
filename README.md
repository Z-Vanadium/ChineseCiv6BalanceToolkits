# CCB 工具箱 2.0

本项目以号码菌最新 Multiplayer Toolkits 快照为基础，重放 CCB 用户需要的默认配置与多人日常功能。

当前版本保留 CCB 适配层与上游 UI 模块的分离，暂不包含比赛/BP 平台、静默自动更新或推广资产。

历史适配原则：

1. 为适配号码菌的后续更新，不修改上游模块的行为，CCB 改动集中在适配层。
2. 通过配置数据库和可选门控使预设符合 CCB 游玩习惯。
3. `MPH/` 承载 CCB 配置与独立适配；`MPH/ModCheck/` 是工具箱自有的赛前校验，不引入 MPH 比赛/BP 平台。

## MOD Check 本地开发版

本轮位于 `feature/ccb2-modcheck-loader`，显示版本由 `.modinfo` 的 `CCBDisplayVersion` 生成，GUID 保持不变。当前交付与尚未完成的实机验收见 [CURRENT_STATE.md](CURRENT_STATE.md)。

联机房间的原准备圆钮左侧显示三色校验灯。房主点击“检查MOD”才开始扫描，客机自动响应；点灯查看一条原因。主菜单右下角显示版本、当前核心接口及首装说明。检查不改变准备状态或阻止开始。

首装步骤：安装并启用工具箱，首次进入一局风云变幻完成公共核心初始化，完全退出并重启。已有公共 Runtime 时复用。检测到外来 `version.dll` 会明确拒绝覆盖；详细错误在公共 Loader 日志中。本开发包没有工坊订阅链接。

公共依赖及扫描器源码位于相邻 `A-C6-Mod/PVPCore`，使用固定公共 Shell/Runtime 和 `Binaries/Win64/Plugins/Global/CCBModCheck.dll`；不携带旧 PVPCore 代理、账号或上传模块。依赖来源、补丁及再分发状态见该仓 `docs/CCB-ModCheck-loader-provenance.md`。当前只作本地开发，未发布工坊。

构建与验证：

```text
PVPCore/scripts/build_shared_loader.cmd
PVPCore/scripts/build_ccb_modcheck.cmd
python -m pip install --target build/test_runtime lupa
python tests/frontend/test_frontend.py
python tests/modcheck/run_tests.py
python tools/package_modcheck.py
python tools/package_modcheck.py --deploy
```

前两项在 PVPCore 仓运行，其余在本仓运行。打包只取 `.modinfo` 声明的文件，并逐文件核对 SHA-256。`--deploy` 要求游戏已退出，将原本地 Mod 和旧 staging 的回滚副本放在 `D:/A-Developing/tmp/ccb-modcheck-rollback`，不在 `Mods` 内保留重复 GUID。工具不会直接改官方 XML、安装游戏目录的 Runtime，或发布工坊。

`tools/modcheck_frontend.py` 从当前官方文件生成本仓自有 StagingRoom/MainMenu 副本，在版本记录中保存原件 SHA；它不会写官方目录。游戏更新后先审查基线差异，再重新生成。

——Vanadium
