-- Catch-up discoveries stay silent; a new host discovery still notifies the guest.
return function(T)
    local L=require("scenarios.sessionlib")(T)
    local got={}
    local function poll() while true do local k,d=PTNative_MsgPoll("t."); if not k then return end; got[k]=d end end
    local function book() return T.first("BP_ProgressionManager_C").LogBook end
    local function toastCount()
        local n=0
        for _,w in ipairs(FindAllOf("UMG_LogBook_NotifMain_C") or {}) do
            if w:IsValid() and w:IsInViewport() then n=n+w.LogbookToastAdded:GetArrayNum() end
        end
        -- NotifMain is a nested widget, so IsInViewport is false; count only live HUD children instead of the designer template.
        if n==0 then
            for _,w in ipairs(FindAllOf("UMG_LogBook_NotifMain_C") or {}) do
                if w:IsValid() and w:GetFullName():find("/Engine/Transient",1,true) then n=n+w.LogbookToastAdded:GetArrayNum() end
            end
        end
        return n
    end
    if T.ROLE=="host" then
        local steps={}; local function add(s) steps[#steps+1]=s end
        for _,s in ipairs(T.loadFixture("garage")) do add(s) end
        add({check="guest_joined",timeout=240,cond=function() return T.netMode()=="listen" and L.guestChar()~=nil end})
        add({run=function() PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(),"t.baseline",tostring(#book().Entries)) end})
        add({check="history_synced_without_toasts",timeout=60,cond=function() poll(); return got["t.quiet"]=="1" end})
        add({run=function()
            local have={}
            for i=1,#book().Entries do local d=book().Entries[i].DataObject; if d:IsValid() then have[d:GetAddress()]=true end end
            local fresh
            for _,d in ipairs(FindAllOf("LogBookDataGeneric") or {}) do
                if d:IsValid() and not d:GetFullName():find("Default__",1,true) and not have[d:GetAddress()] then fresh=d; break end
            end
            assert(fresh,"no undiscovered logbook fixture entry")
            PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(),"t.fresh","1")
            book():AddEntry(fresh)
        end})
        add({check="new_discovery_still_notifies",timeout=30,cond=function() poll(); return got["t.notified"]=="1" end})
        add({run=function() PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(),"t.done","1") end})
        add({wait=3})
        return steps
    end
    return {T.onMap("RB_MainMenu",90),
        {check="guest_in_garage",timeout=400,cond=function() return T.netMode()=="client" and T.map()=="RB_Garage" end},
        {check="guest_finished",timeout=400,tick=function()
            poll()
            if tonumber(got["t.baseline"]) and #book().Entries>=tonumber(got["t.baseline"]) and toastCount()==0 then PTNative_MsgToHost(T.localPC():GetAddress(),"t.quiet","1") end
            if got["t.fresh"] and toastCount()>0 then PTNative_MsgToHost(T.localPC():GetAddress(),"t.notified","1") end
        end,cond=function() return got["t.done"]~=nil end}}
end
