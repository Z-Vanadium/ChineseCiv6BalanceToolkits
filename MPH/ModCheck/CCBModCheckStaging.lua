-- CCB-owned integration into the current native StagingRoom context.
include("CCBModCheckVersion");
include("CCBModCheckProtocol");
include("CCBModCheckController");
CCBModCheckStaging = {};
local M = CCBModCheckStaging;
local controller, snapshot, selected, active, elapsed = nil, nil, nil, false, 0;
local rows, generation, lastConnected = {}, {}, {};
local rosterKey, manifestKey;
local function try(fn, default) local ok,v=pcall(fn); if ok and v~=nil then return v end return default end
local function text(key, ...) return Locale.Lookup(key, ...) end
local function clean(s)
  s=tostring(s or ""):gsub("%[[^%]]*%]", ""):gsub("[%c]", " ");
  if #s<=180 then return s end
  local n=180;
  -- Lua 5.1 has no utf8 library. Never split a multibyte player/mod name.
  while n>0 and s:byte(n+1)>=128 and s:byte(n+1)<192 do n=n-1 end
  return s:sub(1,n).."…";
end
local function idof(m) return m.Id or m.ID or m.id or m.ModId or m.ModID or m.PackageId end
local function normalize(s) return tostring(s or ""):lower():gsub("[{}]", "") end
local function participants()
  local result, connected = {}, {};
  for _,id in ipairs(try(function() return GameConfiguration.GetMultiplayerPlayerIDs() end, {})) do
    local pc=PlayerConfigurations[id];
    if pc and try(function() return Network.IsPlayerConnected(id) end, false) then
      local observer=try(function() return pc:GetSlotStatus()==SlotStatus.SS_OBSERVER end,false);
      if observer or try(function() return pc:IsHuman() end,false) then
        connected[id]=true;
        if not lastConnected[id] then generation[id]=(generation[id] or 0)+1 end
        local identity=try(function() return pc:GetNetworkIdentifer() end,nil);
        if not identity or tostring(identity)=="0" then identity=try(function() return pc:GetSteamID() end,nil) end
        if not identity or tostring(identity)=="0" then identity="name:"..clean(try(function() return pc:GetPlayerName() end,tostring(id))) end
        result[#result+1]={id=id,name=clean(try(function() return pc:GetPlayerName() end,tostring(id))),identity=tostring(identity),observer=observer};
      end
    end
  end
  lastConnected=connected;
  table.sort(result,function(a,b) return a.id<b.id end);
  return result;
end
local function manifest()
  local installed=try(function() return Modding.GetInstalledMods() end,{});
  local result={};
  for _,mod in ipairs(try(function() return GameConfiguration.GetEnabledMods() end,{})) do
    local id=idof(mod); local version=mod.Version or mod.version; local matches={};
    local title=try(function() return Locale.Lookup(mod.Title or mod.Name or "") end,"");
    for _,candidate in ipairs(installed) do
      if (id and normalize(idof(candidate))==normalize(id)) or
         (not id and title~="" and try(function() return Locale.Lookup(candidate.Title or candidate.Name or "") end,"")==title) then matches[#matches+1]=candidate end
    end
    if not id and #matches==1 then id=idof(matches[1]) end
    if version==nil and #matches==1 then
      version=matches[1].Version or matches[1].version;
      if version==nil and matches[1].Handle then
        for _,property in ipairs({"Version","version","VERSION"}) do
          if version==nil then version=try(function() return Modding.GetModProperty(matches[1].Handle,property) end,nil) end
        end
      end
    end
    if not id then return nil,"MANIFEST_UNAVAILABLE" end
    -- Civ6's room list supplies IDs but no Version; native code resolves the
    -- version only after proving a unique physical copy for each requested ID.
    result[#result+1]={id=normalize(id),version=version~=nil and version~=false and tostring(version) or nil,name=clean(mod.Title or mod.Name or id)};
  end
  table.sort(result,function(a,b) return a.id<b.id end);
  if #result==0 then return nil,"EMPTY_MANIFEST" end
  return result;
end
local function rowState(id)
  return snapshot and snapshot.players and snapshot.players[id] or {color="yellow",reason=text("LOC_CCBMC_NOT_CHECKED")};
end
local colors={green=0xFF00DD44,red=0xFF4444EE,yellow=0xFF33DDEE};
local reasons={
  ["ok"]="LOC_CCBMC_REASON_OK",["diff"]="LOC_CCBMC_REASON_DIFF",["digest-mismatch"]="LOC_CCBMC_REASON_DIFF",
  ["checking"]="LOC_CCBMC_CHECKING",["waiting"]="LOC_CCBMC_NOT_CHECKED",["waiting-round"]="LOC_CCBMC_NOT_CHECKED",
  ["no-core"]="LOC_CCBMC_REASON_CORE",["host-no-core"]="LOC_CCBMC_REASON_CORE",["core-unavailable"]="LOC_CCBMC_REASON_CORE",
  ["no-response"]="LOC_CCBMC_REASON_RESPONSE",["host-no-response"]="LOC_CCBMC_REASON_RESPONSE",
  ["scan-error"]="LOC_CCBMC_REASON_ERROR",["scan-timeout"]="LOC_CCBMC_REASON_TIMEOUT",
  ["stale-round"]="LOC_CCBMC_REASON_STALE",["no-manifest"]="LOC_CCBMC_REASON_MANIFEST",["incompatible"]="LOC_CCBMC_CORE_ERROR",
};
local function reason(s) return reasons[s] and text(reasons[s]) or tostring(s or text("LOC_CCBMC_NOT_CHECKED")) end
local function updateReason()
  if not Controls.CCBModCheckReason then return end
  local s=selected and rowState(selected);
  Controls.CCBModCheckReasonBox:SetHide(not s);
  Controls.CCBModCheckSummary:SetHide(s~=nil);
  if s then
    local name=try(function() return PlayerConfigurations[selected]:GetPlayerName() end,tostring(selected));
    local detail=reason(s.reason);
    if type(s.details)=="table" then
      local parts={}; for i=1,math.min(3,#s.details) do parts[#parts+1]=tostring(s.details[i].name or s.details[i].id or s.details[i].reason or s.details[i]) end
      if #parts>0 then detail=detail.." "..table.concat(parts,", ") end
      if #s.details>3 then detail=detail.." (+"..tostring(#s.details-3)..")" end
    end
    Controls.CCBModCheckReason:SetText(clean(name)..": "..clean(detail));
    Controls.CCBModCheckReason:SetToolTipString(clean(name)..": "..clean(detail));
  end
end
function M.BindRow(id)
  local entry=GetPlayerEntry(id); if not entry or not entry.CCBModCheckLight then return end
  rows[id]=entry;
  local human=false; for _,p in ipairs(participants()) do if p.id==id then human=true;break end end
  entry.CCBModCheckLight:SetHide(not human);
  if not human then return end
  local s=rowState(id); local color=s.color or "yellow";
  -- Native online-pip glyph supplies the circular mark; tooltip gives non-colour meaning.
  entry.CCBModCheckLampLabel:SetText("[ICON_OnlinePip]");
  entry.CCBModCheckLampLabel:SetColor(UI.GetColorValueFromHexLiteral(colors[color] or colors.yellow));
  entry.CCBModCheckLight:SetToolTipString(text("LOC_CCBMC_SHORT")..": "..reason(s.reason));
  entry.CCBModCheckLight:RegisterCallback(Mouse.eLClick,function() selected=(selected==id) and nil or id;updateReason() end);
end
local function render(value)
  snapshot=value or {players={}};
  if selected and snapshot.players and not snapshot.players[selected] then selected=nil end
  for id in pairs(rows) do M.BindRow(id) end
  if Controls.CCBModCheckSummary then
    local summary=snapshot.summary;
    Controls.CCBModCheckSummary:SetText(type(summary)=="table" and tostring(summary.text or text("LOC_CCBMC_NOT_CHECKED")) or tostring(summary or text("LOC_CCBMC_NOT_CHECKED")));
    Controls.CCBModCheckButton:SetDisabled(snapshot.checking or snapshot.canCheck==false);
    local host=try(function() return Network.GetLocalPlayerID()==Network.GetGameHostPlayerID() end,false);
    Controls.CCBModCheckButton:SetText(snapshot.checking and text("LOC_CCBMC_CHECKING") or text(host and "LOC_CCBMC_CHECK" or "LOC_CCBMC_RECHECK_SELF"));
  end
  updateReason();
end
local function refreshChanges()
  local p=participants(); local parts={}; for _,v in ipairs(p) do parts[#parts+1]=tostring(v.id)..":"..v.identity end
  local r=table.concat(parts,"|"); if rosterKey and r~=rosterKey then controller:OnRosterChanged() end;rosterKey=r;
  local mods=manifest(); parts={};
  if mods then for _,v in ipairs(mods) do parts[#parts+1]=v.id..":"..tostring(v.version or "") end else parts[1]="unavailable" end
  parts[#parts+1]=tostring(try(function() return GameConfiguration.GetValue("RULESET") end,""));
  parts[#parts+1]=tostring(try(function() return GameConfiguration.GetGameState() end,""));
  local k=table.concat(parts,"|");if manifestKey and k~=manifestKey then controller:OnManifestChanged() end;manifestKey=k;
end
local function ensureController()
  if controller then return end
  local adapter={
    now=function() return os.time() end,
    localId=function() return Network.GetLocalPlayerID() end,
    hostId=function() return Network.GetGameHostPlayerID() end,
    sessionId=function() return tostring(Network.GetSessionID()) end,
    participants=participants, manifest=manifest,
    getCore=function() return CCBModCheck end,
    getPlayerValue=function(pid,key) local pc=PlayerConfigurations[pid];return pc and pc:GetValue(key) end,
    setPlayerValue=function(key,value) local id=Network.GetLocalPlayerID();local pc=PlayerConfigurations[id];if pc then if pc:GetValue(key)~=value then pc:SetValue(key,value);Network.BroadcastPlayerInfo(id) end return true end return false end,
    getRoomValue=function(key) return GameConfiguration.GetValue(key) end,
    setRoomValue=function(key,value) if Network.GetLocalPlayerID()==Network.GetGameHostPlayerID() then if GameConfiguration.GetValue(key)~=value then GameConfiguration.SetValue(key,value);Network.BroadcastGameConfig() end return true end return false end,
    sendWhisper=function(pid,message) Network.SendChat(message,ChatTargetTypes.CHATTARGET_PLAYER,pid);return true end,
    sendReminder=function(pid,message) if Network.GetLocalPlayerID()==Network.GetGameHostPlayerID() then
      -- Normal chat, deliberately visible even to a player with no toolkit.
      Network.SendChat(clean(message),ChatTargetTypes.CHATTARGET_ALL,GetNoPlayerTargetID());
      return true;
    end return false end,
    render=render,log=function(message) print("[CCBModCheck] "..tostring(message)) end,
  };
  controller=CCBModCheckController.New(adapter);
end
local function leave()
  active=false;selected=nil;rosterKey=nil;manifestKey=nil;
  if controller then controller:Leave() end
  rows={}; ContextPtr:ClearUpdate();
end
function M.Install()
  local nativeShow,nativeShutdown,nativeUpdate,nativeBuild,nativeChat,nativeHost,nativeResize=OnShow,OnShutdown,UpdatePlayerEntry,BuildPlayerList,OnChat,OnMultiplayerHostMigrated,Resize;
  function Resize(...)
    nativeResize(...);
    local hotseat=GameConfiguration.IsHotseat();
    Controls.CCBModCheckBar:SetHide(hotseat);
    if not hotseat then
      -- Reserve a strip below the player list using its actual scaled geometry.
      Controls.PrimaryStackGrid:SetSizeY(math.max(150,Controls.PrimaryStackGrid:GetSizeY()-38));
      Controls.PrimaryPanelStack:CalculateSize();RealizeGridSize();
      Controls.CCBModCheckBar:SetOffsetY(Controls.PrimaryPanelStack:GetOffsetY()+Controls.PrimaryStackGrid:GetOffsetY()+Controls.PrimaryStackGrid:GetSizeY()+2);
    end
  end
  function UpdatePlayerEntry(id) nativeUpdate(id); M.BindRow(id) end
  function BuildPlayerList(...) rows={};return nativeBuild(...) end
  function OnChat(from,to,message,target,playSounds)
    if active and controller and controller:OnChat(from,to,message,target) then return end
    return nativeChat(from,to,message,target,playSounds);
  end
  function OnShow(...)
    nativeShow(...);
    if GameConfiguration.IsHotseat() then leave();return end
    ensureController();active=true;selected=nil;rosterKey=nil;manifestKey=nil;controller:Enter();
    Controls.CCBModCheckButton:RegisterCallback(Mouse.eLClick,function() controller:Check() end);
    Controls.CCBModCheckReasonClose:RegisterCallback(Mouse.eLClick,function() selected=nil;updateReason() end);
    ContextPtr:SetUpdate(function(dt) elapsed=elapsed+(tonumber(dt) or 0);if elapsed>=0.25 then elapsed=0;refreshChanges();controller:Tick() end end);
    if ContextPtr.SetHideHandler then ContextPtr:SetHideHandler(leave) end
  end
  function OnMultiplayerHostMigrated(...) nativeHost(...);if active and controller then controller:OnHostChanged() end end
  function OnShutdown(...) leave();return nativeShutdown(...) end
end
