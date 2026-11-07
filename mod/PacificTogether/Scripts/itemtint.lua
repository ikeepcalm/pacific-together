-- Paint belongs to an item instance, including when no manifestation exists (storage, hands, drops).
local UEHelpers = require("UEHelpers")
local common = require("common")
local M = {}
local CLASS = "/Game/Gameplay/Inventory/GenericItemProperties/Components/BP_TintableComponent.BP_TintableComponent_C"
local NOTAG = { TagName = FName("None") }
local lease
local function asset(p)
    if not p or p == "-" then return nil end
    if #p > 1024 or not p:match("^/Game/[%w_/%.-]+$") then return nil end
    local o = StaticFindObject(p)
    if not o:IsValid() then pcall(LoadAsset,p);o=StaticFindObject(p) end
    return common.identity(o) and o or nil
end
local function reader(it)
    local actor=it:GetActorManifestation()
    local cls=asset(CLASS)
    if common.identity(actor) and cls then
        for _,w in ipairs(actor:K2_GetComponentsByClass(cls)) do
            local c=w:get()
            if common.identity(c.Instance) and c.Instance:GetAddress()==it:GetAddress() then return c,false end
        end
    end
    local c=common.resolve(lease)
    if not c then
        local pc=UEHelpers.GetPlayerController()
        local cls=asset(CLASS)
        if not common.identity(pc) or not cls then return nil end
        c=pc:AddComponentByClass(cls,false,{Rotation={X=0,Y=0,Z=0,W=1},Translation={X=0,Y=0,Z=0},Scale3D={X=1,Y=1,Z=1}},false)
        lease=common.lease(c)
    end
    c:SetItemInstance(it,false)
    return c,true
end
local function properties(c)
    local p,t,d,v={},{},{},{}
    c:GetTintableProperties(p,t,d,v)
    if not v.Valid then return nil end
    local function path(o)return common.identity(o) and o:GetFullName():gsub("^%S+ ","") or "-" end
    return path(p.Paint),t.TintingEnabled and "1" or "0",path(d.DecalPalette)
end
function M.spec(it)
    if os.getenv("PT_MUTATE")=="noitemtint" then return "" end
    local c,temporary=reader(it);if not c then return "" end
    local p,t,d=properties(c);if temporary then c:SetItemInstance(nil,false) end
    return p and (":p"..p..":t"..t..":c"..d) or ""
end
local function palettePath(p,folder)
    return p=='-' or (#p<=1024 and p:match('^/Game/BaseArt/Palettes/'..folder..'/[%w_/%.-]+_C$')~=nil)
end
function M.set(it,s)
    local p,t,d=s:match(":p([^:]+):t([01]):c([^:]+)")
    if not p or not palettePath(p,"Paints") or not palettePath(d,"Decals") or os.getenv("PT_MUTATE")=="noitemtint" then return end
    local paint,decal=asset(p),asset(d)
    if (p~="-" and not paint) or (d~="-" and not decal) then return end
    local c,temporary=reader(it);if not c then return end
    local old,enabled,dec=properties(c)
    if old then
        if old~=p then c:SetPaint(paint,NOTAG) end
        if dec~=d then c:SetDecal(decal,NOTAG) end
        if enabled~=t then c:SetTintingEnabled(t=="1") end
    end
    if temporary then c:SetItemInstance(nil,false) end
end
local function materialPalette(mid,palette,layer,fields)
    if not common.identity(palette)then return end
    local defaults=palette:GetCDO()
    local layerAsset=asset('/Game/BaseArt/LayerLibrary/Gameplay/ML_Palette_'..layer..'.ML_Palette_'..layer)
    if not layerAsset then return end
    for _,field in ipairs(fields)do
        local info=mid:GetParameterInfo(0,FName(field[1]),layerAsset)
        if info.Index>=0 then mid['Set'..field[3]..'ParameterValueByInfo'](mid,info,defaults[field[2]])end
    end
end
local paintFields={
    {'Palette_Paint_Color','Paint Color Tint','Vector'},
    {'Palette_Paint_Texture','Paint Combo Texture','Texture'},
    {'Palette_Paint_ColorAmount','Paint Color Amount','Scalar'},
    {'Palette_Paint_Roughness','Paint Roughness','Scalar'},
    {'Palette_Paint_Metallic','Paint Metallic','Scalar'},
    {'Palette_Paint_Spec','Paint Spec','Scalar'},
    {'Palette_Paint_UVTileRate','Paint UV Tile Rate','Scalar'},
}
local decalFields={
    {'Palette_Decal_Diffuse_Texture','Decal Diffuse Texture','Texture'},
    {'Palette_Decal_Mask_Texture','Decal Mask Texture','Texture'},
    {'Palette_Paint_Color','Decal Tint','Vector'},
    {'Palette_Decal_DiffuseBoost','Decal Diffuse Boost','Scalar'},
    {'Palette_Decal_Roughness','Decal Roughness','Scalar'},
    {'Palette_Decal_Metallic','Decal Metallic','Scalar'},
    {'Palette_Decal_Spec','Decal Spec','Scalar'},
}

function M.material(mid,paint,decal,enabled)
    materialPalette(mid,paint,'Paint',paintFields)
    materialPalette(mid,decal,'Decal',decalFields)
    if enabled==false then
        local layer=asset('/Game/BaseArt/LayerLibrary/Gameplay/ML_Palette_Paint.ML_Palette_Paint')
        if layer then local info=mid:GetParameterInfo(0,FName('Palette_Paint_ColorAmount'),layer)
            if info.Index>=0 then mid:SetScalarParameterValueByInfo(info,0) end
        end
    end
end
function M.mesh(mesh,s)
    local p,t,d=s:match(":p([^:]+):t([01]):c([^:]+)")
    if not p or not palettePath(p,"Paints") or not palettePath(d,"Decals") then return end
    local paint,decal=asset(p),asset(d)
    for i=0,mesh:GetNumMaterials()-1 do
        local mid=mesh:GetMaterial(i)
        if not mid:IsA(StaticFindObject('/Script/Engine.MaterialInstanceDynamic')) then mid=mesh:CreateDynamicMaterialInstance(i,nil,FName('None')) end
        if common.identity(mid) then M.material(mid,paint,decal,t=="1") end
    end
end
return M
