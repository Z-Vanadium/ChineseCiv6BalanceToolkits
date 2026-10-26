"""Execute production frontend adapters in Lua 5.1 with native-control test doubles.

This verifies callback/context wiring and state presentation. It does not render Civ6.
Install the isolated test dependency: python -m pip install --target build/test_runtime lupa
"""
from pathlib import Path
import sys

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/"build/test_runtime"))
from lupa.lua51 import LuaRuntime

BOOT=r'''
calls={show=0,resize=0,update=0,chat=0,check=0,enter=0,leave=0,tick=0,scan=0}
function control()
  return setmetatable({hidden=false,y=300,offset=0}, {__index=function(t,k)
    if k=="SetText" then return function(self,v) self.text=v end end
    if k=="SetColor" then return function(self,v) self.color=v end end
    if k=="SetToolTipString" then return function(self,v) self.tooltip=v end end
    if k=="SetHide" then return function(self,v) self.hidden=v end end
    if k=="SetSizeY" then return function(self,v) self.y=v end end
    if k=="GetSizeY" then return function(self) return self.y end end
    if k=="SetOffsetY" then return function(self,v) self.offset=v end end
    if k=="GetOffsetY" then return function(self) return self.offset end end
    if k=="RegisterCallback" then return function(self,mouse,fn) self.click=fn end end
    if k=="SetDisabled" then return function(self,v) self.disabled=v end end
    return function() end
  end})
end
Controls=setmetatable({}, {__index=function(t,k) local v=control();rawset(t,k,v);return v end})
ContextPtr={SetUpdate=function(self,f) self.update=f end,ClearUpdate=function(self) self.update=nil end,SetHideHandler=function(self,f) self.hide=f end}
Locale={Lookup=function(k) return k end}
UI={GetColorValueFromHexLiteral=function(v) return v end}
Mouse={eLClick=1};SlotStatus={SS_OBSERVER=3}
ChatTargetTypes={CHATTARGET_ALL=0,CHATTARGET_PLAYER=1}
function GetNoPlayerTargetID() return -1 end
names={[0]="房主",[1]="玩家一",[2]="AI",[3]="观察者",[4]="断线"}
connected={[0]=true,[1]=true,[2]=true,[3]=true,[4]=false}
PlayerConfigurations={}
for i=0,4 do
 local id=i;PlayerConfigurations[id]={GetValue=function(self,k) return self[k] end,SetValue=function(self,k,v) self[k]=v end,
 GetPlayerName=function() return names[id] end,GetSteamID=function() return 100+id end,
 IsHuman=function() return id~=2 end,GetSlotStatus=function() return id==3 and 3 or 1 end}
end
Network={GetLocalPlayerID=function() return 0 end,GetGameHostPlayerID=function() return 0 end,GetSessionID=function() return 99 end,
 IsPlayerConnected=function(id) return connected[id] end,SendChat=function(...) calls.sent={...} end,
 BroadcastPlayerInfo=function() end,BroadcastGameConfig=function() end}
enabled={{Id="11111111-1111-1111-1111-111111111111",Version=1,Title="中文测试"}}
GameConfiguration={GetMultiplayerPlayerIDs=function() return {0,1,2,3,4} end,GetEnabledMods=function() return enabled end,
 IsHotseat=function() return false end,GetValue=function() end,SetValue=function() end,GetGameState=function() return 0 end}
Modding={GetInstalledMods=function() return enabled end}
rows={};function GetPlayerEntry(id)
 if not rows[id] then rows[id]={CCBModCheckLight=control(),CCBModCheckLampLabel=control()} end
 return rows[id]
end
function UpdatePlayerEntry(id) calls.update=calls.update+1 end
function BuildPlayerList() rows={} end
function OnShow() calls.show=calls.show+1;Resize() end
function OnShutdown() calls.shutdown=true end
function OnChat() calls.chat=calls.chat+1 end
function OnMultiplayerHostMigrated() end
function Resize() calls.resize=calls.resize+1;Controls.PrimaryStackGrid.y=300;Controls.PrimaryStackGrid.offset=-15;Controls.PrimaryPanelStack.offset=114 end
function RealizeGridSize() end
function OnUpdate(dt) calls.nativeUpdate=(calls.nativeUpdate or 0)+1 end
CCBModCheckVersion={display="工具箱 2.0.1-dev"}
function include() end
CCBModCheckController={New=function(adapter)
 savedAdapter=adapter
 return {Enter=function(self) calls.enter=calls.enter+1;roster=adapter.participants();mods=adapter.manifest();adapter.render({players={[1]={color="green",reason="完整一致"}},summary={text="一致 1 · 差异 0"},checking=false,canCheck=true}) end,
 Leave=function() calls.leave=calls.leave+1 end,Check=function() calls.check=calls.check+1 end,
 OnRosterChanged=function() calls.roster=true end,OnManifestChanged=function() calls.manifest=true end,
 OnHostChanged=function() calls.host=true end,Tick=function() calls.tick=calls.tick+1 end,
 OnChat=function(self,from,to,msg) return msg:sub(1,7)=="CCBMC1|" end}
end}
'''


def staging():
    lua=LuaRuntime(unpack_returned_tuples=True)
    lua.execute(BOOT)
    lua.execute((ROOT/"MPH/ModCheck/CCBModCheckStaging.lua").read_text(encoding="utf-8"))
    lua.execute(r'''
CCBModCheckStaging.Install();OnShow();UpdatePlayerEntry(0);UpdatePlayerEntry(1);UpdatePlayerEntry(2);UpdatePlayerEntry(3);UpdatePlayerEntry(4)
assert(calls.show==1 and calls.enter==1 and #roster==3)
assert(#mods==1 and mods[1].version=="1")
assert(not rows[1].CCBModCheckLight.hidden and rows[2].CCBModCheckLight.hidden)
assert(not rows[3].CCBModCheckLight.hidden and rows[4].CCBModCheckLight.hidden)
assert(rows[1].CCBModCheckLampLabel.text=="[ICON_OnlinePip]" and rows[1].CCBModCheckLampLabel.color==0xFF00DD44)
assert(Controls.CCBModCheckSummary.text=="一致 1 · 差异 0")
assert(Controls.PrimaryStackGrid.y==262 and Controls.CCBModCheckBar.offset==363)
Resize();assert(Controls.PrimaryStackGrid.y==262)
rows[1].CCBModCheckLight.click();assert(not Controls.CCBModCheckReasonBox.hidden and Controls.CCBModCheckSummary.hidden)
assert(Controls.CCBModCheckReason.text=="玩家一: 完整一致")
Controls.CCBModCheckReasonClose.click();assert(Controls.CCBModCheckReasonBox.hidden)
Controls.CCBModCheckButton.click();assert(calls.check==1)
OnChat(1,0,"正常聊天",0,true);OnChat(1,0,"CCBMC1|packet",1,true);assert(calls.chat==1)
savedAdapter.sendReminder(1,"@玩家一 安装并启用");assert(calls.sent[2]==0 and calls.sent[3]==-1)
ContextPtr.update(0.25);assert(calls.tick==1)
BuildPlayerList();UpdatePlayerEntry(1);assert(not rows[1].CCBModCheckLight.hidden)
names[1]=string.rep("中文",80);UpdatePlayerEntry(1);assert(#savedAdapter.participants()[2].name<=183)
enabled={{Title="来源不明"}};local missing,why=savedAdapter.manifest();assert(missing==nil and why=="MANIFEST_UNAVAILABLE")
ContextPtr.hide();assert(ContextPtr.update==nil and calls.leave==1)
OnShow();assert(calls.enter==2);OnShutdown();assert(calls.shutdown and calls.leave==2)
''')


def menu():
    lua=LuaRuntime(unpack_returned_tuples=True)
    lua.execute(BOOT)
    lua.execute((ROOT/"MPH/ModCheck/CCBModCheckMainMenu.lua").read_text(encoding="utf-8"))
    lua.execute(r'''
CCBModCheckMainMenu.Install();OnShow()
for i=1,30 do OnUpdate(1) end
assert(Controls.CCBToolkitVersion.text:find("CORE_MISSING") and calls.nativeUpdate==30)
function goodInfo() calls.info=(calls.info or 0)+1;return {available=true,apiVersion=1,coverage="ccb-code-v1",provider="Civ6DllLoader",buildId="fixture"} end
CCBModCheck={GetInfo=goodInfo,BeginScan=function() calls.scan=calls.scan+1 end,PollScan=function() end,CancelScan=function() end}
OnShow();for i=1,30 do OnUpdate(1) end
assert(Controls.CCBToolkitVersion.text:find("CORE_LOADED") and Controls.CCBToolkitCoreHint.hidden)
assert(calls.info==1 and calls.scan==0)
CCBModCheck.CancelScan=nil;OnShow();assert(Controls.CCBToolkitVersion.text:find("CORE_ERROR"))
CCBModCheck.GetInfo=function() error("fixture") end;OnShow();assert(Controls.CCBToolkitVersion.text:find("CORE_ERROR"))
CCBModCheck.GetInfo=function() return {available=true,apiVersion=1,coverage="ccb-code-v1",provider="wrong",buildId="fixture"} end
CCBModCheck.CancelScan=function() end;OnShow();assert(Controls.CCBToolkitVersion.text:find("CORE_ERROR"))
''')


def real_controller():
    """Catch parameter/return mismatches across the real UI/controller boundary."""
    lua=LuaRuntime(unpack_returned_tuples=True)
    lua.execute(BOOT)
    lua.execute(r'''
clock=100;os.time=function() return clock end
CCBModCheck={
 GetInfo=function() return {available=true,apiVersion=1,coverage="ccb-code-v1",provider="Civ6DllLoader",buildId="fixture",pluginVersion="0.1.0"} end,
 BeginScan=function(manifest)
   assert(type(manifest)=="table" and #manifest==1 and manifest[1].version=="1","native BeginScan expects manifest as first argument")
   calls.scan=calls.scan+1;return calls.scan
 end,
 PollScan=function(job)
   assert(type(job)=="number","native PollScan expects job id as first argument")
   return {state="done",coverage="ccb-code-v1",total=string.rep("a",64),mods={{id=enabled[1].Id,version="1",name="中文测试",official=false,hash=string.rep("b",64)}}}
 end,
 CancelScan=function(job) assert(type(job)=="number");return true end,
}
''')
    for name in ("CCBModCheckProtocol", "CCBModCheckController", "CCBModCheckStaging"):
        # Actual Civ6 FE probe: rawget and _G are absent in HavokScript.
        lua.execute("rawget=nil;_G=nil")
        lua.execute((ROOT/f"MPH/ModCheck/{name}.lua").read_text(encoding="utf-8"))
    lua.execute(r'''
CCBModCheckStaging.Install();OnShow();assert(calls.scan==0,"enter must not scan")
Controls.CCBModCheckButton.click();assert(calls.scan==1,"one click starts exactly one native scan")
UpdatePlayerEntry(0);ContextPtr.update(0.25)
assert(rows[0].CCBModCheckLampLabel.color==0xFF00DD44,"host should be green after complete scan")
assert(Controls.CCBModCheckSummary.text:find("一致 1"),"real snapshot must render summary text")
assert(not Controls.CCBModCheckButton.disabled,"completed host can manually check again")
OnShutdown()
''')

    # Actual GameConfiguration.GetEnabledMods omits Version. Resolve by room ID
    # and let the native scanner prove a unique installed version.
    lua.execute(r'''
OnShow();enabled={{Id="11111111-1111-1111-1111-111111111111",Title="中文测试"}}
CCBModCheck.BeginScan=function(manifest)
 assert(#manifest==1 and manifest[1].version==nil)
 calls.scan=calls.scan+1;return calls.scan
end
ContextPtr.update(0.25);Controls.CCBModCheckButton.click();assert(calls.scan==2)
OnShutdown()
''')


if __name__=="__main__":
    staging();menu();real_controller()
    print("PASS staging + menu + real-controller integration; production Lua 5.1; engine rendering NOT covered")
