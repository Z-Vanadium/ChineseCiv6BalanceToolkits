-- CCB 2.0 适配：旧 CCB 的 TPT Settings 双轨面板已随魔女 Settings/Config_UI.* 统一入口移除，
-- 本模块不再有 "ForcedEndButton_Show" 高级设置开关，因此默认直接显示按钮。
-- TODO(P1)：若需要在魔女 Settings UI 中提供该开关，请：
--   1) 在 Settings/Config_UI.xml 增加 Parameters/Row（Domain="bool"，ConfigurationId 如 "FORCED_ENDBUTTON_SHOW"）
--   2) 在 Settings/Config_UI_Text.xml 补 NAME/DESC 文案
--   3) 把下面的 Show_FEB 初值改为 GameConfiguration.GetValue("FORCED_ENDBUTTON_SHOW") == true
local Show_FEB = true

-- 兼容遗留事件：旧面板曾广播 LuaEvents.TPT_Settings_Toggle("ForcedEndButton_Show", v)，
-- 现在没有发送方，保留监听以便将来接线时不改本文件。
function OnTPT_Settings_Toggle(ParameterId, Value)
	if ParameterId == "ForcedEndButton_Show" then
		Show_FEB = Value
		if Controls and Controls.ForcedEnd_Button then
			Controls.ForcedEnd_Button:SetHide(not Show_FEB)
		end
		return
	end
end

function LateInitialize()
	local ctr = ContextPtr:LookUpControl("/InGame/ActionPanel")
	Controls.ForcedEnd_Button:ChangeParent(ctr)
	Controls.ForcedEnd_Button:SetToolTipString(Locale.Lookup("LOC_FORCEEND_TT"))
	Controls.ForcedEnd_Button:RegisterCallback(	Mouse.eLClick, function() UI.RequestAction(ActionTypes.ACTION_ENDTURN, { REASON = "UserForced" } ); end);
	Controls.ForcedEnd_Button:RegisterCallback(	Mouse.eRClick, function() LuaEvents.ForcedEndTurn(); end);
	Controls.ForcedEnd_Button:SetHide(not Show_FEB)
end

function Initialize()
	Events.LoadScreenClose.Add(LateInitialize)
	LuaEvents.TPT_Settings_Toggle.Add(OnTPT_Settings_Toggle)
end
Initialize()