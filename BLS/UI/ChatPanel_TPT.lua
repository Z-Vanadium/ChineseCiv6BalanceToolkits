-- =================================================================================
-- Import base file
-- =================================================================================
-- CCB 2.0 适配：旧 CCB 会先尝试 include("chatpanel_MPH.lua")（来自已废弃的 Multiplayer Helper 移植层）。
-- 本仓库不再随包提供该文件，缺文件会让 include 报错，因此只保留游戏原生的 ChatPanel.lua 作为底座。
local files = {
    "ChatPanel.lua",
}

for _, file in ipairs(files) do
    include(file)
    if Initialize then
        print("Loading " .. file .. " as base file");
        break
    end
end

function TPT_LateInitialize()
	Controls.BlackListPanelButton:RegisterCallback(Mouse.eLClick, function() LuaEvents.Open_BlackListOanel() end);
end
TPT_LateInitialize()