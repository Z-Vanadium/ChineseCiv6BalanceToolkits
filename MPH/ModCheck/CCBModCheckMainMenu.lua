include("CCBModCheckVersion");
CCBModCheckMainMenu={};
local elapsed,attempts,done=0,0,false;
local function L(key,...) return Locale.Lookup(key,...) end
local function poll()
  attempts=attempts+1;
  local core=CCBModCheck;local status="LOC_CCBMC_CORE_MISSING";local good=false;
  if core and type(core.GetInfo)=="function" then
    local ok,info=pcall(core.GetInfo);
    good=ok and type(info)=="table" and info.available==true and info.apiVersion==1 and info.coverage=="ccb-code-v1" and info.provider=="Civ6DllLoader" and type(info.buildId)=="string" and #info.buildId>0 and
      type(core.BeginScan)=="function" and type(core.PollScan)=="function" and type(core.CancelScan)=="function";
    status=good and "LOC_CCBMC_CORE_LOADED" or "LOC_CCBMC_CORE_ERROR";
  elseif attempts<20 then status="LOC_CCBMC_CORE_DETECTING" end
  done=good or attempts>=20;
  Controls.CCBToolkitVersion:SetText("CCB "..tostring(CCBModCheckVersion.display).." | "..L(status));
  Controls.CCBToolkitVersion:SetToolTipString(L("LOC_CCBMC_CORE_INSTALL_HELP"));
  Controls.CCBToolkitCoreHint:SetHide(good);
  Controls.CCBToolkitCoreHint:SetText(L("LOC_CCBMC_CORE_HINT"));
end
function CCBModCheckMainMenu.Install()
  local nativeShow,nativeUpdate=OnShow,OnUpdate;
  function OnShow(...)
    nativeShow(...);elapsed=0;attempts=0;done=false;poll();
  end
  function OnUpdate(dt)
    nativeUpdate(dt);
    if not done then elapsed=elapsed+(tonumber(dt) or 0);if elapsed>=1 then elapsed=0;poll() end end
  end
end
