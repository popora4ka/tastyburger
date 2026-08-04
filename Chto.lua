print("I know you r trying to deobfuscate my code")
print("I don't give a fuck skid")
--==================================================================--
--  Woloko SPAWNER
--  (engine v5.3 — persistent inventory cards, rifle pose, gun-up fix)
--  Data sources per weapon (best first):
--   1. mm2_meshes_data.lua  (rich multi-part model dumps, ~897 weapons)
--   2. mm2_rich_cache.json  (own rich captures incl. FX)
--   3. mm2_real_texture_cache.json (live-learned displays)
--   4. era-based base mesh fallback
--==================================================================--
local Players     = game:GetService("Players")
local RS          = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local LocalPlayer = Players.LocalPlayer
-- require() falls back to getgc scan for executors that don't support it
local Sync
do
	local ok, r = pcall(function()
		return require(RS:WaitForChild("Database"):WaitForChild("Sync"))
	end)
	if ok and type(r) == "table" and type(r.Item) == "table" then
		Sync = r
	elseif getgc then
		for _, v in ipairs(getgc(true)) do
			if type(v) == "table" and type(rawget(v, "Item")) == "table" and type(rawget(v, "Rarities")) == "table" then
				Sync = v
				break
			end
		end
	end
	if not Sync then
		error("[Woloko Spawner] Could not load MM2 Database — use an executor with require() support (e.g. Delta, Xeno, Synapse)")
	end
end

-- Remove any previous instance of GUI or old spawner script
for _, container in ipairs({(gethui and gethui()) or nil, game:GetService("CoreGui"), LocalPlayer:FindFirstChild("PlayerGui")}) do
	for _, gname in ipairs({"MM2VisualSpawnerGui", "YomogiScriptsGui"}) do
		local old = container and container:FindFirstChild(gname)
		if old then pcall(function() old:Destroy() end) end
	end
end
if _G.MM2SpawnerCleanup then pcall(_G.MM2SpawnerCleanup) end

-- remove inventory/trade cards injected by a previous run (their
-- category placement or naming may have changed between versions)
pcall(function()
	local weapons = LocalPlayer.PlayerGui.MainGUI.Game.Inventory.Main.Weapons
	for _, d in ipairs(weapons.Items.Container:GetDescendants()) do
		if d.Name:sub(1, 9) == "ZZVisual_" then d:Destroy() end
	end
end)
-- clean any trade cards left over from older versions (feature removed)
pcall(function()
	local tg = LocalPlayer.PlayerGui:FindFirstChild("TradeGUI")
	if tg then
		for _, d in ipairs(tg:GetDescendants()) do
			if d.Name:sub(1, 9) == "ZZVisual_" or d.Name:sub(1, 10) == "AAAWoloko_" then d:Destroy() end
		end
	end
end)

--------------------------------------------------------------------
-- Load data sources (LAZY): parsing mm2_meshes_data.lua (~1MB) and
-- JSON-decoding the caches is what made injection lag. We defer all of
-- it until the first actual spawn, so injecting the hub is instant.
--------------------------------------------------------------------
local RICH = {}
local Learned = {}
local RichJson = {}
local DataLoaded = false
local Weapons -- forward-declared so ensureDataLoaded can back-fill it

---------------------------------------------------------------------
-- Remote data URLs — fetch from GitHub so any device gets mesh data.
-- Falls back to local Potassium workspace files if URLs are blank.
---------------------------------------------------------------------
local DATA_URLS = {
	meshes      = "https://raw.githubusercontent.com/popora4ka/tastyburger/refs/heads/main/mm2_meshes_data.lua",
	richJson    = "https://raw.githubusercontent.com/popora4ka/tastyburger/refs/heads/main/mm2_rich_cache.json",
	textureCache= "https://raw.githubusercontent.com/popora4ka/tastyburger/refs/heads/main/mm2_real_texture_cache.json",
}
local function fetchText(url, filename)
	if url and url ~= "" then
		local ok, res = pcall(function() return game:HttpGet(url, true) end)
		if ok and type(res) == "string" and #res > 10 then return res end
	end
	if isfile and filename and isfile(filename) then
		local ok, res = pcall(readfile, filename)
		if ok and type(res) == "string" then return res end
	end
	return nil
end

local function loadLearned()
	pcall(function()
		local raw = fetchText(DATA_URLS.textureCache, "mm2_real_texture_cache.json")
		if raw then
			local d = HttpService:JSONDecode(raw)
			if typeof(d) == "table" then Learned = d end
		end
	end)
end

local function loadRichJson()
	pcall(function()
		local raw = fetchText(DATA_URLS.richJson, "mm2_rich_cache.json")
		if raw then
			local d = HttpService:JSONDecode(raw)
			if typeof(d) == "table" then RichJson = d end
		end
	end)
end

-- called on the first spawn; safe to call repeatedly (no-op after load)
local function ensureDataLoaded()
	if DataLoaded then return end
	DataLoaded = true
	pcall(function()
		local raw = fetchText(DATA_URLS.meshes, "mm2_meshes_data.lua")
		if raw then
			local d = loadstring(raw)()
			if typeof(d) == "table" then
				RICH = d
				-- back-fill entries that were created before data loaded
				for _, e in pairs(Weapons) do
					if e.Rich == nil then e.Rich = RICH[e.Id] end
				end
			end
		end
	end)
	loadLearned()
	loadRichJson()
end

--------------------------------------------------------------------
-- Weapon entries from the game DB
--------------------------------------------------------------------
local DEFAULT_GRIP = {
	Knife = CFrame.new(0, -1, -0.1),
	Gun   = CFrame.new(0, -0.27, 0.727),
}

-- Hardcoded gun shot sounds ripped from the UGC MM2 remake's asset
-- manifest (SharedServices.Framework). Keyed by a lowercase fragment of
-- the DB dataId; only applied to ItemType == "Gun" entries. These play
-- instantly on GunFired — no need to wait for the learn-cache to hear
-- another player's gun first.
local GUN_SOUNDS = {
	gingerscope = "rbxassetid://10209803", -- user-confirmed live shot sound
}
local GUN_RELOAD_SOUNDS = {
	gingerscope = "rbxassetid://4753414199", -- bolt cycle after each shot
}
-- Custom hold animation played while the gun is drawn
local GUN_HOLD_ANIMS = {
	gingerscope = "rbxassetid://76543778750449",
}

-- Per-gun holds: how the gun sits in the fist. Live-captured from the
-- remake's real Gingerscope tool: Grip = (0, -0.4, 0.9), identity
-- rotation. GINGERSCOPE ONLY — every other gun keeps its existing
-- behavior. (Harvester's scythe hold stays in applyToTool via MountCF.)
local GUN_HOLDS = {
	gingerscope = CFrame.new(0, -0.4, 0.9),
}

-- Custom shot beams live-captured from real tools — used as a fallback
-- when the MM2 dump has no CustomBeam props for the gun. The game's own
-- GunBeams.CreateBeam clones handle.CustomBeam per shot.
local GUN_BEAMS = {
	gingerscope = {
		Texture = "rbxassetid://15374653796",
		TextureLength = 1.5,
		TextureSpeed = 0,
		TextureMode = Enum.TextureMode.Wrap,
		Color = ColorSequence.new(Color3.new(1, 1, 1)),
		Transparency = NumberSequence.new(0),
		Width0 = 1,
		Width1 = 1,
		LightEmission = 1,
		LightInfluence = 0,
		FaceCamera = false,
		Segments = 10,
	},
}

-- Live-captured weapon skins (keyed by dataId). Modern MM2 Summer weapons are
-- single MeshParts skinned with a SurfaceAppearance ColorMap (PBR) or a plain
-- TextureID — neither the mesh dump nor the simple texture cache has them yet,
-- so the overlay engine builds these directly. Meshes load at native scale, so
-- Size is REQUIRED (native size * MM2's ~0.0701 import scale). Captured
-- 2026-07-23 off real equipped tools (Beachy knife, Sands gun).
local HARDCODED_SKINS = {
	Beachy         = {MeshId = "rbxassetid://88652423673547", Surface = "rbxassetid://128146857850145", Size = Vector3.new(0.3694, 3.5048, 1.2594)},
	-- Chroma variants: NO SurfaceAppearance (it would hide the recolor). The
	-- engine's chroma loop rainbow-cycles the untextured mesh's Color, matching
	-- the in-game chroma look (blue Beachy / teal Sands / rainbow Icecream are
	-- just frames of that cycle). Base Color set from the screenshots for the
	-- brief moment before the cycle takes over.
	-- BeachyChroma: real chroma is a Decal named "Chroma" (wrap texture 73559105239250,
	-- Face Left) the game hue-shifts — captured live off Jakob_D3. The chroma loop
	-- cycles it for genuine in-game rainbow instead of a flat color.
	BeachyChroma   = {MeshId = "rbxassetid://88652423673547", Chroma = true, BaseTexture = "rbxassetid://128146857850145", ChromaDecal = "rbxassetid://73559105239250", ChromaFace = Enum.NormalId.Left, Scale = Vector3.new(0.0701, 0.0701, 0.0701), Size = Vector3.new(0.3694, 3.5048, 1.2594)},
	Icecream       = {MeshId = "rbxassetid://82044527712515", TextureId = "rbxassetid://133533169721039", Size = Vector3.new(0.8022, 3.3766, 0.9748)},
	IcecreamChroma = {MeshId = "rbxassetid://82044527712515", Chroma = true, BaseTexture = "rbxassetid://133533169721039", ChromaDecal = "rbxassetid://98918130519475", ChromaFace = Enum.NormalId.Left, Scale = Vector3.new(0.696, 0.696, 0.696)},
	-- Sands (Godly Gun): captured from WeaponDisplays.GunDisplay (the Tool Handle
	-- carries only the generic base mesh 6600918074 — the real skin is on the
	-- display). Single MeshPart + SurfaceAppearance.
	Sands          = {MeshId = "rbxassetid://104658283027428", Surface = "rbxassetid://138720590976364", Size = Vector3.new(0.4099, 1.3663, 1.9086)},
	SandsChroma    = {MeshId = "rbxassetid://104658283027428", Chroma = true, BaseTexture = "rbxassetid://138720590976364", ChromaDecal = "rbxassetid://92831262223446", ChromaFace = Enum.NormalId.Left, Scale = Vector3.new(0.037926, 0.037926, 0.037926), Size = Vector3.new(0.4099, 1.3663, 1.9086)},
}

local function rarityColor(rarityName)
	local r = Sync.Rarities and Sync.Rarities[rarityName]
	if r and r.Hex then
		local ok, c = pcall(Color3.fromHex, r.Hex)
		if ok then return c end
	end
	return Color3.fromRGB(106, 106, 106)
end

local function fallbackMesh(it)
	local year = tonumber(it.Year) or 0
	if it.ItemType == "Knife" then
		if year >= 2022 then return "rbxassetid://6600901997", Vector3.new(1, 1, 1) end
		return "http://www.roblox.com/asset/?id=121944778", Vector3.new(1, 1, 1)
	else
		if year >= 2025 then return "rbxassetid://6600918074", Vector3.new(1, 1, 1) end
		return "http://www.roblox.com/asset/?id=79401392", Vector3.new(1.5, 1.5, 1.5)
	end
end

-- Resolve the real MM2 inventory tab from database/dump data.
-- The DB and mesh dump carry an explicit Event field ("Christmas" /
-- "Halloween") — use it instead of guessing from names. Tabs in the
-- live inventory are: Classic, Holiday (with Christmas + Halloween
-- sections inside), Current ("Season 1").
local function getCategoryTab(it, dataId)
	local idLower = tostring(dataId):lower()
	local rich = RICH[dataId]
	local event = it.Event or (rich and rich.Meta and rich.Meta.Event)
	if event == "Christmas" or it.Holiday == "Christmas" or it.Christmas then
		return "Christmas"
	elseif event == "Halloween" or it.Holiday == "Halloween" or it.Halloween then
		return "Halloween"
	elseif event then
		-- Any other event (Summer, etc.) is the live/current event: the game
		-- files these under "Current" (see InventoryModule.GenerateInventoryTables:
		-- Event ~= Christmas/Halloween -> "Current"). Without this, new Summer
		-- weapons wrongly landed in "Classic".
		return "Current"
	elseif it.Season == 1 or it.Season == "1" or it.SeasonOne or idLower:find("season") then
		return "Current"
	else
		return "Classic"
	end
end

-- MM2's old thumbnail URLs (Thumbs/Asset.ashx) don't render in ImageLabels
-- or tool icons in-game; convert them to rbxthumb so icons work everywhere
-- (weapon cards, hotbar slot, end-of-round screen).
local function normalizeImage(img)
	img = tostring(img or "")
	if img:find("Asset%.ashx") then
		local id = img:match("assetId=(%d+)")
		if id then return "rbxthumb://type=Asset&id=" .. id .. "&w=150&h=150" end
	end
	return img
end

-- Holiday weapons whose DB entry is MISSING the Event field (found by
-- scanning the live DB) — force their badge + inventory tab here.
local EVENT_OVERRIDES = {
	Batwing          = {Event = "Halloween", Year = "2017"},
	GhostKnife       = {Event = "Halloween"},
	PumpkinPie_K_2023 = {Event = "Halloween", Year = "2023"},
	SlouseClown      = {Event = "Halloween"},
	SlouseClownGun   = {Event = "Halloween"},
	StickersT2025    = {Event = "Halloween", Year = "2025"},
	Dartbringer      = {Event = "Christmas", Year = "2021"},
	Gifted           = {Event = "Christmas"},
	StickersX25      = {Event = "Christmas", Year = "2025"},
}

-- Strictly loads only valid Knife/Gun items parsed from the database
Weapons = {}
for dataId, it in pairs(Sync.Item) do
	if typeof(it) == "table" and (it.ItemType == "Knife" or it.ItemType == "Gun") then
		-- Chroma variants carry Chroma=true in the DB but share the plain
		-- ItemName (e.g. "Bauble" for BaubleChroma) — flag + rename them.
		local baseName = tostring(it.ItemName or dataId)
		local isChroma = (it.Chroma == true)
			or tostring(dataId):lower():find("chroma") ~= nil
			or tostring(it.Rarity) == "Chroma"
		-- keep the plain name like the real game; the rainbow "Chroma"
		-- tag bar on the card marks chroma variants instead of a rename
		local entry = {
			Id          = dataId,
			Type        = it.ItemType,
			DisplayName = baseName,
			Rarity      = tostring(it.Rarity or "?"),
			Image       = normalizeImage(it.Image),
			GuiColor    = rarityColor(it.Rarity),
			Grip        = DEFAULT_GRIP[it.ItemType],
			Rich        = RICH[dataId],
			Category    = getCategoryTab(it, dataId),
			Chroma      = isChroma,
			FX          = false, -- FX badge reserved for Gingerscope (user preference)
			Evo         = (it.Evo ~= nil),
			Year        = tostring(it.Year or (RICH[dataId] and RICH[dataId].Meta and RICH[dataId].Meta.Year) or ""),
		}
		local cf, has = CFrame.new(), false
		if typeof(it.Offset) == "table" and it.Offset.X then
			cf = CFrame.new(it.Offset.X, it.Offset.Y, it.Offset.Z); has = true
		end
		if typeof(it.Angles) == "table" and it.Angles.X then
			cf = cf * CFrame.Angles(it.Angles.X, it.Angles.Y, it.Angles.Z); has = true
		end
		if has then entry.AttCF = cf end
		-- Per-gun hold + shot/reload sound from the hardcoded tables
		-- above (chroma variants match too — "GingerscopeChroma" etc.)
		if it.ItemType == "Gun" then
			local idl = tostring(dataId):lower()
			for key, cf in pairs(GUN_HOLDS) do
				if idl:find(key, 1, true) then
					entry.Grip = cf
					break
				end
			end
			for key, sid in pairs(GUN_SOUNDS) do
				if idl:find(key, 1, true) then
					entry.Sound = sid
					entry.ReloadSound = GUN_RELOAD_SOUNDS[key]
					break
				end
			end
			for key, bp in pairs(GUN_BEAMS) do
				if idl:find(key, 1, true) then
					entry.Beam = bp
					break
				end
			end
			for key, aid in pairs(GUN_HOLD_ANIMS) do
				if idl:find(key, 1, true) then
					entry.HoldAnim = aid
					break
				end
			end
			-- Gingerscope card: FX badge on, snowflake off (user preference)
			if idl:find("gingerscope", 1, true) then
				entry.FX = true
				entry.HideEvent = true
			end
		end
		local ov = EVENT_OVERRIDES[dataId]
		if ov then
			entry.Category = ov.Event
			if ov.Year and entry.Year == "" then entry.Year = ov.Year end
		end
		-- Newer weapons ship a CustomAttachment inside their model whose
		-- RelCF is the game's exact display-mount seat — prefer it over
		-- the legacy Offset/Angles when present.
		local rm = entry.Rich and entry.Rich.Model
		if rm and rm.Children then
			for _, ch in ipairs(rm.Children) do
				if ch.Class == "Attachment" and ch.Name == "CustomAttachment"
					and ch.Props and typeof(ch.Props.RelCF) == "CFrame" then
					entry.MountCF = ch.Props.RelCF
					break
				end
			end
		end
		Weapons[dataId] = entry
	end
end

-- Some weapons exist in multiple years with the same name (Evergun 2023 vs
-- 2025) — tag duplicates with their year so they can be told apart.
do
	local nameCount = {}
	for _, e in pairs(Weapons) do
		local k = e.Type .. "|" .. (e.Chroma and "C|" or "") .. e.DisplayName
		nameCount[k] = (nameCount[k] or 0) + 1
	end
	for id, e in pairs(Weapons) do
		local k = e.Type .. "|" .. (e.Chroma and "C|" or "") .. e.DisplayName
		if nameCount[k] > 1 then
			local yr = Sync.Item[id] and Sync.Item[id].Year
			if yr then e.DisplayName = e.DisplayName .. " (" .. tostring(yr) .. ")" end
		end
	end
end

-- Include every weapon. (We used to prune ones with no visual data, but
-- data now loads lazily on first spawn, so at this point nothing has data
-- yet — pruning here would wrongly drop everything. Weapons that end up
-- with no data just fall back to a plain mesh.)
local SortedList = {}
for _, e in pairs(Weapons) do
	table.insert(SortedList, e)
end
table.sort(SortedList, function(a, b)
	if a.DisplayName == b.DisplayName then return a.Id < b.Id end
	return a.DisplayName < b.DisplayName
end)

--------------------------------------------------------------------
-- Visual engine: hide original, weld an overlay model
--------------------------------------------------------------------
local Equipped    = {Knife = nil, Gun = nil}
local Hidden      = {}   -- [Instance] = original state to restore
local OverlayRoot = {}   -- [BasePart] = list of created instances
local OverlayBaseTx = {} -- [Instance] = built transparency (BasePart/Decal)
local OverlayBaseEn = {} -- [Instance] = built Enabled (Beams/FX/lights)
local SavedAttCF  = {}
local SavedGrips  = {}
local SavedToolTx = {}
local ApplyTokens = {Knife = 0, Gun = 0}
local Connections = {}
local HoldTrack, HoldTrackId -- custom gun hold animation (Gingerscope)
local InjectedEntries = {}   -- [entry]=true: cards to keep alive in the inventory
local HookedRealCards = setmetatable({}, {__mode = "k"}) -- weak: auto-clears when cards are destroyed

-- Two-hand rifle pose fallback: Roblox refuses to load another game's
-- animation asset, and MM2's rigs use AnimationConstraint joints whose
-- C0/C1 are READ-ONLY — so offset the left shoulder's Transform every
-- physics step instead (Stepped fires after animations compose, so the
-- offset layers cleanly on top of the game's own animations).
local RunServiceS = game:GetService("RunService")
local RIFLE_POSE_OFF = CFrame.Angles(math.rad(70), math.rad(-45), 0)
local RiflePoseConn
local function setRiflePose(_, on)
	if on then
		if RiflePoseConn then return end
		RiflePoseConn = RunServiceS.Stepped:Connect(function()
			local c = LocalPlayer.Character
			local sh = c and c:FindFirstChild("LeftUpperArm")
			sh = sh and sh:FindFirstChild("LeftShoulder")
			if sh then sh.Transform = sh.Transform * RIFLE_POSE_OFF end
		end)
	elseif RiflePoseConn then
		RiflePoseConn:Disconnect()
		RiflePoseConn = nil
	end
end
local FAKE_PREFIX = "ZZVisual_"

-- forward declarations so click handlers defined earlier in the file
-- capture these as upvalues instead of resolving to nil globals.
local updateEquippedSlot, applyToDisplay, scanTools, updateFooter, bumpSpawnCount
-- assigned by the trade module (modded games only): writes a spawned
-- weapon into the real ProfileData inventory so it shows up in trades.
local realSpawnItem
-- true once the modded trade module confirms real ProfileData spawns work.
-- When true we skip the engine's fake inventory card, so a spawn creates
-- ONE real item (visible in inventory + trade) instead of a real + a fake.
local RealSpawnSupported = false

local function track(c) table.insert(Connections, c) return c end

-- true if the instance is (or lives inside) one of OUR overlay parts —
-- hideOriginal gets re-run to fight the game un-hiding the real weapon,
-- and must never touch the overlay's own decals/FX.
local function isOverlayPiece(inst)
	while inst do
		local n = inst.Name
		if n == "VisualPart" or n:sub(1, 4) == "ZZV_" then return true end
		if inst.GetAttribute and inst:GetAttribute("ZZV") then return true end
		inst = inst.Parent
	end
	return false
end

local function hideOriginal(part)
	if Hidden[part] == nil then Hidden[part] = {Transparency = part.Transparency} end
	part.Transparency = 1
	for _, d in ipairs(part:GetDescendants()) do
		if not isOverlayPiece(d) then
			if d:IsA("BasePart") then
				-- multi-part real weapons (scopes etc.) must vanish too
				if Hidden[d] == nil then Hidden[d] = {Transparency = d.Transparency} end
				d.Transparency = 1
			elseif d:IsA("Decal") or d:IsA("Texture") then
				if Hidden[d] == nil then Hidden[d] = {Transparency = d.Transparency} end
				d.Transparency = 1
			elseif d:IsA("ParticleEmitter") or d:IsA("Beam") or d:IsA("Trail") or d:IsA("Fire") or d:IsA("Sparkles") or d:IsA("Smoke") then
				if Hidden[d] == nil then Hidden[d] = {Enabled = d.Enabled} end
				d.Enabled = false
			elseif d:IsA("PointLight") or d:IsA("SurfaceLight") or d:IsA("SpotLight") then
				if Hidden[d] == nil then Hidden[d] = {Enabled = d.Enabled} end
				d.Enabled = false
			end
		end
	end
end

-- restore + forget only the hidden state that lives under one anchor,
-- so resetting the Knife doesn't un-hide the Gun's original (and vice versa)
local function restoreHiddenUnder(anchor)
	for inst, state in pairs(Hidden) do
		if inst == anchor or (inst.Parent and inst:IsDescendantOf(anchor)) then
			pcall(function()
				if state.Transparency ~= nil then inst.Transparency = state.Transparency end
				if state.Enabled ~= nil then inst.Enabled = state.Enabled end
			end)
			Hidden[inst] = nil
		end
	end
end

local function clearOverlay(part)
	if OverlayRoot[part] then
		for _, inst in ipairs(OverlayRoot[part]) do
			OverlayBaseTx[inst] = nil
			OverlayBaseEn[inst] = nil
			pcall(function() inst:Destroy() end)
		end
		OverlayRoot[part] = nil
	end
end

local function newOverlayPart(anchor, made)
	local p = Instance.new("Part")
	p.Name = "VisualPart"
	p.CanCollide, p.CanQuery, p.CanTouch = false, false, false
	p.Massless = true
	p.Anchored = false
	p.Size = Vector3.new(0.2, 0.2, 0.2)
	table.insert(made, p)
	return p
end

-- Normalize any asset reference ("http://...?id=123", "123", "rbxassetid://123")
-- CreateMeshPartAsync often rejects the long URL form, which made those
-- weapons fail to build and fall back to a plain white mesh.
local function normalizeAssetId(id)
	if id == nil then return nil end
	local n = tostring(id):match("%d+")
	if not n or n == "0" then return nil end
	return "rbxassetid://" .. n
end

local MeshPartCache = {}
local function newOverlayMeshPart(meshId, made)
	if not meshId or meshId == "" then return nil end
	local norm = normalizeAssetId(meshId) or meshId
	local tmpl = MeshPartCache[norm]
	if tmpl == false then return nil end
	if not tmpl then
		local ok, mp = pcall(function()
			return game:GetService("AssetService"):CreateMeshPartAsync(Content.fromUri(norm))
		end)
		if not ok or not mp then
			ok, mp = pcall(function()
				return game:GetService("AssetService"):CreateMeshPartAsync(norm)
			end)
		end
		if (not ok or not mp) and norm ~= meshId then
			ok, mp = pcall(function()
				return game:GetService("AssetService"):CreateMeshPartAsync(Content.fromUri(meshId))
			end)
		end
		if ok and mp then
			MeshPartCache[norm] = mp
			tmpl = mp
		else
			MeshPartCache[norm] = false
			return nil
		end
	end
	local p = tmpl:Clone()
	p.Name = "VisualPart"
	p.CanCollide, p.CanQuery, p.CanTouch = false, false, false
	p.Massless = true
	p.Anchored = false
	table.insert(made, p)
	return p
end

local function weldTo(anchor, p)
	local w = Instance.new("WeldConstraint")
	w.Part0, w.Part1, w.Parent = anchor, p, p
end

local function applyBasePartProps(p, props)
	if props.Color then pcall(function() p.Color = props.Color end) end
	if props.Material then pcall(function() p.Material = props.Material end) end
	if props.Reflectance then p.Reflectance = props.Reflectance end
	if props.Transparency then p.Transparency = props.Transparency end
	if props.Size then pcall(function() p.Size = props.Size end) end
end

local function addFileMesh(p, meshId, textureId, scale, offset, vertexColor)
	local m = Instance.new("SpecialMesh")
	m.MeshType = Enum.MeshType.FileMesh
	-- normalize ids: long-URL/whitespace forms silently fail to load and
	-- leave the weapon black or white
	m.MeshId = normalizeAssetId(meshId) or ""
	m.TextureId = normalizeAssetId(textureId) or ""
	m.Scale = scale or Vector3.new(1, 1, 1)
	m.Offset = offset or Vector3.new(0, 0, 0)
	m.VertexColor = vertexColor or Vector3.new(1, 1, 1)
	m.Parent = p
	return m
end

local function jv3(a) return a and Vector3.new(a[1], a[2], a[3]) or nil end
local function jc3(a) return a and Color3.fromRGB(a[1], a[2], a[3]) or nil end
local function jcf(a) return a and CFrame.new(unpack(a)) or nil end
local function jcolorseq(kps)
	local list = {}
	for _, k in ipairs(kps) do table.insert(list, ColorSequenceKeypoint.new(k[1], jc3(k[2]))) end
	return ColorSequence.new(list)
end
local function jnumseq(kps)
	local list = {}
	for _, k in ipairs(kps) do table.insert(list, NumberSequenceKeypoint.new(k[1], k[2], k[3] or 0)) end
	return NumberSequence.new(list)
end

local function buildJsonTree(anchor, tree, made, baseCF)
	local rootCF = baseCF or anchor.CFrame
	local attachments = {}
	local beams = {}

	local function buildNode(node, parentPart, isRoot)
		local c, p = node.c, node.p or {}
		local myPart = parentPart
		if c == "Part" or c == "MeshPart" then
			local part
			if c == "MeshPart" then
				part = newOverlayMeshPart(p.MeshId, made)
				if part then pcall(function() part.TextureID = normalizeAssetId(p.TextureID) or "" end) end
				if not part and isRoot then error("mesh part creation failed") end
				if not part then return end
			else
				part = newOverlayPart(anchor, made)
			end
			-- keep the source name (prefixed) so FX loops can find LightParts
			if node.n then part.Name = "ZZV_" .. tostring(node.n) end
			pcall(function()
				if p.Size then part.Size = jv3(p.Size) end
				if p.Color then part.Color = jc3(p.Color) end
				if p.Material then part.Material = Enum.Material[p.Material] end
				if p.Transparency then part.Transparency = p.Transparency end
				if p.Reflectance then part.Reflectance = p.Reflectance end
			end)
			part.CFrame = isRoot and rootCF or (rootCF * (jcf(p.RelCF) or CFrame.new()))
			part.Parent = anchor
			weldTo(anchor, part)
			myPart = part
		elseif c == "SpecialMesh" or c == "FileMesh" then
			if myPart and not myPart:FindFirstChildOfClass("SpecialMesh") then
				addFileMesh(myPart, p.MeshId, p.TextureId, jv3(p.Scale), jv3(p.Offset), jv3(p.VertexColor))
			end
		elseif c == "Decal" then
			if myPart then
				local d = Instance.new("Decal")
				d.Name = node.n or "Decal" -- keep "Chroma" decals findable for the hue loop
				pcall(function()
					d.Texture = normalizeAssetId(p.Texture) or ""
					if p.Face then d.Face = Enum.NormalId[p.Face] end
					if p.Color3 then d.Color3 = jc3(p.Color3) end
					if p.Transparency then d.Transparency = p.Transparency end
				end)
				d.Parent = myPart
			end
		elseif c == "Attachment" then
			if myPart then
				local a = Instance.new("Attachment")
				a.Name = node.n or "Attachment"
				a.CFrame = jcf(p.RelCF) or CFrame.new()
				a.Parent = myPart
				if not attachments[a.Name] then attachments[a.Name] = a end
				table.insert(made, a)
			end
		elseif c == "Beam" then
			if myPart then
				local b = Instance.new("Beam")
				pcall(function()
					b.Texture = p.Texture or ""
					if p.TextureLength then b.TextureLength = p.TextureLength end
					if p.TextureSpeed then b.TextureSpeed = p.TextureSpeed end
					if p.TextureMode then b.TextureMode = Enum.TextureMode[p.TextureMode] end
					if p.ColorSeq then b.Color = jcolorseq(p.ColorSeq) end
					if p.TranspSeq then b.Transparency = jnumseq(p.TranspSeq) end
					if p.Width0 then b.Width0 = p.Width0 end
					if p.Width1 then b.Width1 = p.Width1 end
					if p.LightEmission then b.LightEmission = p.LightEmission end
					if p.FaceCamera ~= nil then b.FaceCamera = p.FaceCamera end
					if p.Segments then b.Segments = p.Segments end
					if p.CurveSize0 then b.CurveSize0 = p.CurveSize0 end
					if p.CurveSize1 then b.CurveSize1 = p.CurveSize1 end
					if p.ZOffset then b.ZOffset = p.ZOffset end
					if p.Enabled ~= nil then b.Enabled = p.Enabled end
				end)
				b.Parent = myPart
				table.insert(made, b)
				table.insert(beams, {beam = b, a0 = p.A0, a1 = p.A1})
			end
		elseif c == "ParticleEmitter" then
			if myPart then
				local pe = Instance.new("ParticleEmitter")
				pcall(function()
					pe.Texture = p.Texture or ""
					if p.ColorSeq then pe.Color = jcolorseq(p.ColorSeq) end
					if p.TranspSeq then pe.Transparency = jnumseq(p.TranspSeq) end
					if p.SizeSeq then pe.Size = jnumseq(p.SizeSeq) end
					if p.Lifetime then pe.Lifetime = NumberRange.new(p.Lifetime[1], p.Lifetime[2]) end
					if p.Rate then pe.Rate = p.Rate end
					if p.Speed then pe.Speed = NumberRange.new(p.Speed[1], p.Speed[2]) end
					if p.SpreadAngle then pe.SpreadAngle = Vector2.new(p.SpreadAngle[1], p.SpreadAngle[2]) end
					if p.RotSpeed then pe.RotSpeed = NumberRange.new(p.RotSpeed[1], p.RotSpeed[2]) end
					if p.Rotation then pe.Rotation = NumberRange.new(p.Rotation[1], p.Rotation[2]) end
					if p.LightEmission then pe.LightEmission = p.LightEmission end
					if p.LockedToPart ~= nil then pe.LockedToPart = p.LockedToPart end
					if p.EmissionDirection then pe.EmissionDirection = Enum.NormalId[p.EmissionDirection] end
					if p.Acceleration then pe.Acceleration = jv3(p.Acceleration) end
					if p.ZOffset then pe.ZOffset = p.ZOffset end
					if p.Enabled ~= nil then pe.Enabled = p.Enabled end
				end)
				pe.Parent = myPart
				table.insert(made, pe)
			end
		elseif p.LightClass then
			if myPart then
				local li = Instance.new(p.LightClass)
				pcall(function()
					if p.Brightness then li.Brightness = p.Brightness end
					if p.LightColor then li.Color = jc3(p.LightColor) end
					if p.Range then li.Range = p.Range end
					if p.Enabled ~= nil then li.Enabled = p.Enabled end
				end)
				li.Parent = myPart
				table.insert(made, li)
			end
		end
		if node.ch then
			for _, child in ipairs(node.ch) do buildNode(child, myPart, false) end
		end
	end

	buildNode(tree, nil, true)
	for _, b in ipairs(beams) do
		local a0 = b.a0 and attachments[b.a0]
		local a1 = b.a1 and attachments[b.a1]
		if a0 and a1 then
			b.beam.Attachment0 = a0
			b.beam.Attachment1 = a1
		else
			b.beam:Destroy()
		end
	end
end

local function buildFullTree(anchor, model, made, baseCF)
	local rootCF = baseCF or anchor.CFrame
	local attachList = {}
	local beamList = {}
	local function buildNode(node, parentPart)
		local class = node.Class
		local props = node.Props or {}
		local myPart = parentPart
		if class == "Part" or class == "MeshPart" then
			local p
			if class == "MeshPart" then
				p = newOverlayMeshPart(props.MeshId, made)
				if p then
					pcall(function() p.TextureID = normalizeAssetId(props.TextureID or props.TextureId) or "" end)
				end
			end
			if not p then p = newOverlayPart(anchor, made) end
			if node.Name then p.Name = "ZZV_" .. tostring(node.Name) end
			applyBasePartProps(p, props)
			local rel = props.RelCF or CFrame.new()
			p.CFrame = rootCF * rel
			p.Parent = anchor
			weldTo(anchor, p)
			myPart = p
		elseif class == "SpecialMesh" or class == "FileMesh" then
			if parentPart then
				addFileMesh(parentPart, props.MeshId, props.TextureId or props.TextureID, props.Scale, props.Offset, props.VertexColor)
			end
		elseif class == "Decal" then
			if parentPart then
				local d = Instance.new("Decal")
				d.Name = node.Name or "Decal"
				pcall(function()
					if props.Texture then d.Texture = normalizeAssetId(props.Texture) or props.Texture end
					if props.Face then d.Face = props.Face end
					if props.Color3 then d.Color3 = props.Color3 end
					if props.Transparency then d.Transparency = props.Transparency end
				end)
				d.Parent = parentPart
			end
		elseif class == "Attachment" then
			if parentPart then
				local a = Instance.new("Attachment")
				a.Name = node.Name or "Attachment"
				pcall(function() a.CFrame = props.RelCF or CFrame.new() end)
				a.Parent = parentPart
				table.insert(made, a)
				table.insert(attachList, a)
			end
		elseif class == "Beam" then
			if parentPart then
				local b = Instance.new("Beam")
				pcall(function()
					for k, v in pairs(props) do
						pcall(function() b[k] = v end)
					end
				end)
				b.Parent = parentPart
				table.insert(made, b)
				table.insert(beamList, b)
			end
		end
		if node.Children then
			for _, child in ipairs(node.Children) do
				buildNode(child, myPart)
			end
		end
	end
	local props = model.Props or {}
	local rootOverlay
	if model.Class == "MeshPart" then
		rootOverlay = newOverlayMeshPart(props.MeshId, made)
		if rootOverlay then
			pcall(function() rootOverlay.TextureID = props.TextureID or props.TextureId or "" end)
		end
	end
	if not rootOverlay then
		if model.Class == "MeshPart" then error("mesh part creation failed") end
		rootOverlay = newOverlayPart(anchor, made)
	end
	applyBasePartProps(rootOverlay, props)
	rootOverlay.CFrame = rootCF
	rootOverlay.Parent = anchor
	weldTo(anchor, rootOverlay)
	if model.Children then
		for _, child in ipairs(model.Children) do
			buildNode(child, rootOverlay)
		end
	end
	for _, b in ipairs(beamList) do
		if attachList[1] and attachList[2] then
			b.Attachment0 = attachList[1]
			b.Attachment1 = attachList[2]
		else
			b:Destroy()
		end
	end
end

local function buildOldFlat(anchor, display, made, baseCF)
	local rootCF = baseCF or anchor.CFrame
	local rootOverlay
	for _, elem in ipairs(display) do
		local class = elem.Class
		local props = elem.Props or {}
		if (class == "Part" or class == "MeshPart") and elem.Path == "(root)" then
			if class == "MeshPart" then
				rootOverlay = newOverlayMeshPart(props.MeshId, made)
				if rootOverlay then
					pcall(function() rootOverlay.TextureID = normalizeAssetId(props.TextureID or props.TextureId) or "" end)
				else
					error("mesh part creation failed")
				end
			else
				rootOverlay = newOverlayPart(anchor, made)
			end
			if elem.Name then rootOverlay.Name = "ZZV_" .. tostring(elem.Name) end
			applyBasePartProps(rootOverlay, props)
			rootOverlay.CFrame = rootCF
			rootOverlay.Parent = anchor
			weldTo(anchor, rootOverlay)
		elseif class == "SpecialMesh" or class == "FileMesh" then
			if rootOverlay and not rootOverlay:FindFirstChildOfClass("SpecialMesh") then
				addFileMesh(rootOverlay, props.MeshId, props.TextureId or props.TextureID, props.Scale, props.Offset, props.VertexColor)
			end
		elseif class == "Decal" then
			if rootOverlay then
				local d = Instance.new("Decal")
				-- keep the name + Color3: chroma weapons are a Decal named
				-- "Chroma" whose Color3 the game hue-shifts
				d.Name = elem.Name or "Decal"
				pcall(function()
					if props.Texture then d.Texture = normalizeAssetId(props.Texture) or props.Texture end
					if props.Face then d.Face = props.Face end
					if props.Color3 then d.Color3 = props.Color3 end
					if props.Transparency then d.Transparency = props.Transparency end
				end)
				d.Parent = rootOverlay
			end
		end
	end
end

local function buildSimple(anchor, e, made, baseCF)
	local p
	if e.Size then
		p = newOverlayMeshPart(e.MeshId, made)
		if p then
			-- separate pcalls — a bad texture id must never stop the
			-- Size from applying (that's what caused giant white weapons)
			pcall(function() p.TextureID = e.TextureId or "" end)
			pcall(function() p.Size = e.Size end)
		end
	end
	if not p then
		p = newOverlayPart(anchor, made)
		p.Transparency = 0
		addFileMesh(p, e.MeshId, e.TextureId, e.Scale, e.Offset, e.VertexColor)
	end
	p.CFrame = baseCF or anchor.CFrame
	p.Parent = anchor
	weldTo(anchor, p)
end

local function resolveSimple(e)
	local c = Learned[e.Id]
	if c then
		return {
			MeshId = c.MeshId, TextureId = c.TextureId or "",
			Scale = Vector3.new(c.Scale[1], c.Scale[2], c.Scale[3]),
			Offset = Vector3.new(c.Offset[1], c.Offset[2], c.Offset[3]),
			VertexColor = Vector3.new(c.VertexColor[1], c.VertexColor[2], c.VertexColor[3]),
			Size = (c.MeshPart and c.Size) and Vector3.new(c.Size[1], c.Size[2], c.Size[3]) or nil,
		}
	end
	local it = Sync.Item[e.Id] or {}
	local fm, fs = fallbackMesh(it)
	return {MeshId = fm, TextureId = "", Scale = fs, Offset = Vector3.new(), VertexColor = Vector3.new(1, 1, 1)}
end

-- No MM2 weapon is anywhere near this big. If an overlay part exceeds it,
-- the mesh loaded at native scale (Size prop missing/failed) — reject the
-- build and fall to the next data source instead of showing a giant.
local MAX_WEAPON_EXTENT = 12

local function overlayTooBig(made)
	for _, inst in ipairs(made) do
		if inst:IsA("BasePart") then
			local s = inst.Size
			if math.max(s.X, s.Y, s.Z) > MAX_WEAPON_EXTENT then return true end
		end
	end
	return false
end

local function clampOverlaySize(made)
	for _, inst in ipairs(made) do
		if inst:IsA("BasePart") then
			local s = inst.Size
			local m = math.max(s.X, s.Y, s.Z)
			if m > MAX_WEAPON_EXTENT then
				pcall(function() inst.Size = s * (4 / m) end)
			end
		end
	end
end

-- Build a single-MeshPart overlay from a HARDCODED_SKINS entry: applies the
-- captured Size (native meshes load giant), a SurfaceAppearance ColorMap (the
-- PBR skin modern MM2 weapons use) and/or a plain TextureID.
local function buildHardcodedSkin(anchor, skin, made, baseCF)
	-- Real chroma skin: build a Part + SpecialMesh (FileMesh) so the "Chroma"
	-- decal WRAPS the whole mesh via its UVs. A Decal on a MeshPart only paints
	-- ONE face and leaves the rest of the weapon grey — this is that fix. The
	-- engine's chroma loop hue-shifts the decal's Color3 for the rainbow.
	if skin.ChromaDecal then
		local cp = newOverlayPart(anchor, made)
		cp.Transparency = 0
		-- base skin is the SpecialMesh's TextureId (coral/starfish); Scale =
		-- displaySize / nativeMeshSize so it renders at the right size (NOT giant).
		addFileMesh(cp, skin.MeshId, skin.BaseTexture, skin.Scale, nil, nil)
		pcall(function()
			local d = Instance.new("Decal")
			d.Name = "Chroma"
			d.Texture = normalizeAssetId(skin.ChromaDecal) or skin.ChromaDecal
			d.Face = skin.ChromaFace or Enum.NormalId.Left
			d.Transparency = skin.ChromaTransp or 0
			d.Parent = cp
		end)
		cp.CFrame = baseCF or anchor.CFrame
		cp.Parent = anchor
		weldTo(anchor, cp)
		return true
	end
	local p = newOverlayMeshPart(skin.MeshId, made)
	if not p then error("skin mesh creation failed") end
	pcall(function()
		if skin.Size then p.Size = skin.Size end
		if skin.TextureId then p.TextureID = normalizeAssetId(skin.TextureId) or "" end
		if skin.Color then p.Color = skin.Color end
	end)
	-- Chroma variants deliberately skip the SurfaceAppearance: it would override
	-- the part Color and hide the engine's rainbow chroma cycle.
	if skin.Surface and not skin.Chroma then
		pcall(function()
			local sa = Instance.new("SurfaceAppearance")
			sa.ColorMap = normalizeAssetId(skin.Surface) or skin.Surface
			sa.Parent = p
		end)
	end
	p.CFrame = baseCF or anchor.CFrame
	p.Parent = anchor
	weldTo(anchor, p)
	return true
end

-- Guard against overlapping builds: mesh creation yields, so two builds
-- racing on the same anchor used to stack two weapons on top of each
-- other. Only the newest build for an anchor is allowed to finish.
local BuildTokens = {}
local Building = {}

local function applyVisual(anchor, e, baseCF)
	if not anchor then return end
	ensureDataLoaded() -- first spawn only: parse the heavy mesh/cache files
	BuildTokens[anchor] = (BuildTokens[anchor] or 0) + 1
	local myTok = BuildTokens[anchor]
	Building[anchor] = myTok
	clearOverlay(anchor)
	hideOriginal(anchor)
	local made = {}
	local function wipe()
		for _, inst in ipairs(made) do pcall(function() inst:Destroy() end) end
		made = {}
	end
	local function stale()
		if BuildTokens[anchor] ~= myTok then
			wipe()
			return true
		end
		return false
	end
	local usedRich = false
	-- Live-captured skins take priority over the dump/cache (SurfaceAppearance
	-- PBR weapons the other sources can't represent).
	local skin = HARDCODED_SKINS[e.Id]
	if skin then
		usedRich = pcall(buildHardcodedSkin, anchor, skin, made, baseCF)
		if stale() then return end
		if usedRich and overlayTooBig(made) then usedRich = false end
		if not usedRich then wipe() end
	end
	local rj = RichJson[e.Id]
	if not usedRich and rj then
		usedRich = pcall(buildJsonTree, anchor, rj, made, baseCF)
		if stale() then return end
		if usedRich and overlayTooBig(made) then usedRich = false end
		if not usedRich then wipe() end
	end
	local rich = e.Rich
	if not usedRich and rich then
		if rich.Model then
			usedRich = pcall(buildFullTree, anchor, rich.Model, made, baseCF)
			if stale() then return end
			if usedRich and overlayTooBig(made) then usedRich = false end
			if not usedRich then wipe() end
		end
		if not usedRich and rich.Display and (rich.Complete or not Learned[e.Id]) then
			usedRich = pcall(buildOldFlat, anchor, rich.Display, made, baseCF)
			if stale() then return end
			if usedRich and overlayTooBig(made) then usedRich = false end
			if not usedRich then wipe() end
		end
	end
	if not usedRich then
		local simple = resolveSimple(e)
		buildSimple(anchor, {Id = e.Id, MeshId = simple.MeshId, TextureId = simple.TextureId, Scale = simple.Scale, Offset = simple.Offset, VertexColor = simple.VertexColor, Size = simple.Size}, made, baseCF)
		if stale() then return end
		clampOverlaySize(made) -- last resort: never let anything render giant
	end
	-- remember each piece's built visibility so the maintenance loop can
	-- hide/show the whole overlay to mirror holstered vs drawn state
	-- (decals render even on invisible parts, so capture them too)
	for _, inst in ipairs(made) do
		if inst:IsA("BasePart") then
			pcall(function() OverlayBaseTx[inst] = inst.Transparency end)
			for _, d in ipairs(inst:GetDescendants()) do
				if d:IsA("Decal") or d:IsA("Texture") then
					pcall(function() OverlayBaseTx[d] = d.Transparency end)
				end
			end
		elseif inst:IsA("Decal") or inst:IsA("Texture") then
			pcall(function() OverlayBaseTx[inst] = inst.Transparency end)
		elseif inst:IsA("Beam") or inst:IsA("ParticleEmitter") or inst:IsA("Trail")
			or inst:IsA("PointLight") or inst:IsA("SurfaceLight") or inst:IsA("SpotLight") then
			pcall(function() OverlayBaseEn[inst] = inst.Enabled end)
		end
	end
	OverlayRoot[anchor] = made
	if Building[anchor] == myTok then Building[anchor] = nil end
end

--------------------------------------------------------------------
-- HUD Equipped Slot + Grid Synchronizer
--------------------------------------------------------------------
local function getInventory()
	local pg = LocalPlayer:FindFirstChild("PlayerGui")
	local mg = pg and pg:FindFirstChild("MainGUI")
	local game_ = mg and mg:FindFirstChild("Game")
	local inv = game_ and game_:FindFirstChild("Inventory")
	local main = inv and inv:FindFirstChild("Main")
	return main and main:FindFirstChild("Weapons")
end

-- Live inventory layout: Items.Container.{Classic,Current}.Container are
-- grids; holiday weapons live in Items.Container.Holiday.Container.
-- {Christmas,Halloween}.Container sections.
local function getCategoryGrid(tabs, category)
	if category == "Christmas" or category == "Halloween" then
		local hol = tabs:FindFirstChild("Holiday")
		local cont = hol and hol:FindFirstChild("Container")
		local sec = cont and cont:FindFirstChild(category)
		return sec and sec:FindFirstChild("Container")
	end
	local f = tabs:FindFirstChild(category)
	return f and f:FindFirstChild("Container")
end

-- Real-game tag badges: every inventory card template ships a Tags frame
-- (UIListLayout, stacks bottom-up above the name bar) with ready-made
-- children: Chroma (rainbow bar), Christmas/Halloween (icon + Year),
-- FX, Evo, Unique. Toggle them per weapon like the game does.
local function applyTags(tags, e)
	if not tags then return end
	local function setTag(name, on)
		local tf = tags:FindFirstChild(name)
		if not tf then return end
		tf.Visible = (on == true)
		if on then
			-- make sure the tag text ("Chroma"/"FX") actually shows
			local tn = tf:FindFirstChild("TagName")
			if tn then tn.Visible = true end
			-- always overwrite the template's placeholder year ("2018") —
			-- blank when we don't know the real year
			local yr = (e.Year and e.Year ~= "") and e.Year or ""
			local y = tf:FindFirstChild("Year")
			if y then y.Text = yr; y.Visible = true end
			local y2 = tf:FindFirstChild("Year2")
			if y2 then y2.Text = yr end
		end
	end
	setTag("Chroma", e.Chroma)
	setTag("Christmas", e.Category == "Christmas" and not e.HideEvent)
	setTag("Halloween", e.Category == "Halloween" and not e.HideEvent)
	setTag("FX", e.FX)
	setTag("Evo", e.Evo)
	setTag("Unique", false)
end

-- the game's own Tags frame, cloned onto spawner GUI cards so badges
-- look pixel-identical to the real inventory
local TagsTemplate
do
	local im = RS:FindFirstChild("Modules")
	im = im and im:FindFirstChild("InventoryModule")
	local ni = im and im:FindFirstChild("NewItem")
	TagsTemplate = ni and ni:FindFirstChild("Tags")
end

local function injectIntoInventoryGrid(e)
	-- In modded games real spawns write a genuine inventory item, so a fake
	-- card here would double it. Skip when real spawning is available.
	if RealSpawnSupported then return end
	local weapons = getInventory()
	if not weapons then return end
	local items = weapons:FindFirstChild("Items")
	local tabs = items and items:FindFirstChild("Container")
	if not tabs then return end

	local grid = getCategoryGrid(tabs, e.Category or "Classic")
		or getCategoryGrid(tabs, "Classic")
	if not grid then return end

	local cardName = FAKE_PREFIX .. e.Id
	InjectedEntries[e] = true -- persistence loop re-injects after the game rebuilds the grid
	if grid:FindFirstChild(cardName) then
		return
	end

	local template = grid:FindFirstChild("NewItem")
	if not template then
		-- holiday sections may be empty — borrow a card from Classic
		local classic = getCategoryGrid(tabs, "Classic")
		template = classic and classic:FindFirstChild("NewItem")
	end
	if not template then
		local im = RS:FindFirstChild("Modules")
		im = im and im:FindFirstChild("InventoryModule")
		template = im and im:FindFirstChild("NewItem")
	end
	if not template then return end

	local f = template:Clone()
	f.Name = cardName
	f.LayoutOrder = -100
	f.Visible = true

	local itemName = f:FindFirstChild("ItemName")
	if itemName then
		itemName.BackgroundColor3 = e.GuiColor
		local label = itemName:FindFirstChild("Label")
		if label then label.Text = e.DisplayName end
	end
	applyTags(f:FindFirstChild("Tags"), e)
	local cont = f:FindFirstChild("Container")
	if cont then
		local icon = cont:FindFirstChild("Icon")
		if icon then icon.Image = e.Image end
		local amount = cont:FindFirstChild("Amount")
		if amount then amount.Text = "" end
		local tradeAmount = cont:FindFirstChild("TradeAmount")
		if tradeAmount then tradeAmount.Text = "" end
		local btn = cont:FindFirstChild("ActionButton")
		if btn then
			btn.MouseButton1Click:Connect(function()
				-- equip only — duping happens from the spawner GUI cards
				Equipped[e.Type] = e
				updateEquippedSlot(e)
				applyToDisplay(e.Type)
				scanTools()
				if updateFooter then updateFooter() end
			end)
		end
	end
	f.Parent = grid
end

function updateEquippedSlot(e)
	local weapons = getInventory()
	if not weapons then return end
	local slotFrame = weapons:FindFirstChild("Equipped")
	slotFrame = slotFrame and slotFrame:FindFirstChild("Container")
	slotFrame = slotFrame and slotFrame:FindFirstChild(e.Type)
	slotFrame = slotFrame and slotFrame:FindFirstChild("Container")
	if not slotFrame then return end
	local itemName = slotFrame:FindFirstChild("ItemName")
	if itemName then
		itemName.BackgroundColor3 = e.GuiColor
		local label = itemName:FindFirstChild("Label")
		if label then label.Text = e.DisplayName end
	end
	local cont = slotFrame:FindFirstChild("Container")
	local icon = cont and cont:FindFirstChild("Icon")
	if icon then icon.Image = e.Image end
	applyTags(slotFrame:FindFirstChild("Tags"), e)

	injectIntoInventoryGrid(e)
end

local function resetEquippedSlot(itemType)
	local weapons = getInventory()
	if not weapons then return end
	local slotFrame = weapons:FindFirstChild("Equipped")
	slotFrame = slotFrame and slotFrame:FindFirstChild("Container")
	slotFrame = slotFrame and slotFrame:FindFirstChild(itemType)
	slotFrame = slotFrame and slotFrame:FindFirstChild("Container")
	if not slotFrame then return end

	local actualName = "Default " .. itemType
	local actualImage = itemType == "Knife" and "rbxassetid://501150965" or "rbxassetid://501151240"

	local itemName = slotFrame:FindFirstChild("ItemName")
	if itemName then
		itemName.BackgroundColor3 = Color3.fromRGB(106, 106, 106)
		local label = itemName:FindFirstChild("Label")
		if label then label.Text = actualName end
	end
	local cont = slotFrame:FindFirstChild("Container")
	local icon = cont and cont:FindFirstChild("Icon")
	if icon then icon.Image = actualImage end
end

--------------------------------------------------------------------
-- Displays + tools apply
--------------------------------------------------------------------
local function myDisplay(kind)
	local char = LocalPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local folder = workspace:FindFirstChild("WeaponDisplays")
	if not folder then return nil end
	local best, bestDist
	for _, d in ipairs(folder:GetChildren()) do
		if d.Name == kind then
			local rc = d:FindFirstChild("RigidConstraint")
			local a0 = rc and rc.Attachment0
			if a0 and char and a0:IsDescendantOf(char) then return d end
			if hrp then
				local dist = (d.Position - hrp.Position).Magnitude
				if dist < 7 and (not bestDist or dist < bestDist) then best, bestDist = d, dist end
			end
		end
	end
	return best
end

function applyToDisplay(slot)
	local e = Equipped[slot]
	if not e then return end
	ApplyTokens[slot] += 1
	local myToken = ApplyTokens[slot]
	task.spawn(function()
		local target
		for _ = 1, 40 do
			if ApplyTokens[slot] ~= myToken or Equipped[slot] ~= e then return end
			target = myDisplay(slot .. "Display")
			if target then break end
			task.wait(0.25)
		end
		if not target or ApplyTokens[slot] ~= myToken or Equipped[slot] ~= e then return end
		applyVisual(target, e)
		local att = target:FindFirstChild("Attachment")
		if att then
			if SavedAttCF[att] == nil then SavedAttCF[att] = att.CFrame end
			-- Seat priority: the model's CustomAttachment RelCF (the game's
			-- exact mount seat) > legacy Offset/Angles > identity.
			local seat = e.MountCF or e.AttCF
			-- Back-mounted knives with only legacy holster Angles (45° rolls
			-- meant for the hip) would sink into the torso — sit those
			-- straight like every other back knife instead.
			if slot == "Knife" and not e.MountCF then
				local rc = target:FindFirstChild("RigidConstraint")
				local mountName = rc and rc.Attachment0 and rc.Attachment0.Name or ""
				if mountName:lower():find("back") then seat = nil end
			end
			pcall(function()
				att.CFrame = seat or CFrame.new()
			end)
		end
	end)
end

-- The default Roblox hotbar caches the tool icon when the tool registers,
-- so besides setting Tool.TextureId we also rewrite any slot icon that
-- still shows the original (default knife/gun) texture.
local function patchHotbarIcons(tool, e)
	local orig = tostring(SavedToolTx[tool] or "")
	local origId = orig:match("%d+")
	if e.Image == "" or orig == "" then return end
	task.spawn(function()
		for _, t in ipairs({0.2, 0.5, 1, 2, 4}) do
			task.wait(t)
			if Equipped[tool.Name] ~= e then return end
			pcall(function()
				-- ONLY the hotbar gui — never sweep MainGUI: its VS/end
				-- screens legitimately show "Default Knife/Gun" panels
				-- (other players' weapons) that must stay untouched
				local bp = game:GetService("CoreGui"):FindFirstChild("BackpackGui")
				if not bp then return end
				for _, d in ipairs(bp:GetDescendants()) do
					if d:IsA("ImageLabel") or d:IsA("ImageButton") then
						local img = tostring(d.Image)
						if img ~= e.Image and img ~= "" then
							if img == orig or (origId and (img:match("id=(%d+)") or img:match("%d+")) == origId) then
								d.Image = e.Image
							end
						end
					end
				end
			end)
		end
	end)
end

--------------------------------------------------------------------
-- Thrown knife: the projectile (and the knife left stuck in the
-- floor) is a fresh server part using the real knife's mesh — reskin
-- it as it appears so the throw looks like the spawned knife.
--------------------------------------------------------------------
local ThrownAnchors = {}
local RealKnifeMesh = "121944778" -- default knife mesh; updated from the real tool
local PendingLand = {}

local function meshDigits(part)
	local id = ""
	if part:IsA("MeshPart") then
		id = part.MeshId
	else
		local sm = part:FindFirstChildOfClass("SpecialMesh")
		id = sm and sm.MeshId or ""
	end
	return tostring(id):match("%d+") or ""
end

-- Beam properties for a weapon's CustomBeam (green Harvester beam,
-- Gingerscope tracer, etc.) from either dump format.
local function findCustomBeamProps(rich)
	if not rich then return nil end
	local m = rich.Model
	if m and m.Children then
		for _, ch in ipairs(m.Children) do
			if ch.Class == "Beam" and ch.Name == "CustomBeam" and ch.Props then
				return ch.Props
			end
		end
	end
	if rich.Display then
		for _, elem in ipairs(rich.Display) do
			if elem.Class == "Beam" and elem.Name == "CustomBeam" and elem.Props then
				return elem.Props
			end
		end
	end
	return nil
end

local function trySkinThrown(part)
	local e = Equipped.Knife
	if not e then return end
	if ThrownAnchors[part] ~= nil then return end
	if not part:IsDescendantOf(workspace) then return end
	if isOverlayPiece(part) then return end
	if part:FindFirstAncestorOfClass("Tool") then return end
	if part.Name:find("Display") then return end
	local wd = workspace:FindFirstChild("WeaponDisplays")
	if wd and part:IsDescendantOf(wd) then return end
	local digits = meshDigits(part)
	if digits == "" or (digits ~= RealKnifeMesh and digits ~= "121944778") then return end
	-- must be OUR throw: it appears near us, or near the spot where our
	-- projectile just vanished (projectile -> stuck-in-floor handoff)
	local char = LocalPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local ours = hrp and (part.Position - hrp.Position).Magnitude < 15
	if not ours then
		local now = os.clock()
		for _, pl in ipairs(PendingLand) do
			if now - pl.t < 2 and (part.Position - pl.pos).Magnitude < 10 then
				ours = true
				break
			end
		end
	end
	if not ours then return end
	ThrownAnchors[part] = "Knife"
	applyVisual(part, e)
	track(part.AncestryChanged:Connect(function()
		if not part:IsDescendantOf(game) then
			pcall(function()
				table.insert(PendingLand, {pos = part.Position, t = os.clock()})
				if #PendingLand > 6 then table.remove(PendingLand, 1) end
			end)
			ThrownAnchors[part] = nil
			OverlayRoot[part] = nil
		end
	end))
end

track(workspace.DescendantAdded:Connect(function(inst)
	if not Equipped.Knife then return end
	if inst:IsA("BasePart") then
		task.delay(0.05, function() pcall(trySkinThrown, inst) end)
	elseif inst:IsA("SpecialMesh") then
		local p = inst.Parent
		if p and p:IsA("BasePart") then
			task.delay(0.05, function() pcall(trySkinThrown, p) end)
		end
	end
end))

--------------------------------------------------------------------
-- Gun sounds: sound ids only exist server-side, but when ANOTHER
-- player's gun replicates to us its handle Sound comes with it.
-- Learn mesh->sound into mm2_sound_cache.json over time; when OUR
-- spawned gun fires (GunFired event), play the learned sound and
-- mute the default one.
--------------------------------------------------------------------
local SoundCache = {}
local SavedVolumes = {}
pcall(function()
	if isfile and isfile("mm2_sound_cache.json") then
		local d = HttpService:JSONDecode(readfile("mm2_sound_cache.json"))
		if typeof(d) == "table" then SoundCache = d end
	end
end)

local function saveSoundCache()
	pcall(function()
		if writefile then writefile("mm2_sound_cache.json", HttpService:JSONEncode(SoundCache)) end
	end)
end

-- root mesh digits for one of our weapon entries (same key the learner uses)
local function entryMeshDigits(e)
	local rich = e.Rich
	if rich then
		local m = rich.Model
		if m then
			local id = m.Props and m.Props.MeshId
			if not id and m.Children then
				for _, ch in ipairs(m.Children) do
					if (ch.Class == "SpecialMesh" or ch.Class == "FileMesh") and ch.Props and ch.Props.MeshId then
						id = ch.Props.MeshId
						break
					end
				end
			end
			if id then return tostring(id):match("%d+") end
		end
		if rich.Display then
			for _, elem in ipairs(rich.Display) do
				local p = elem.Props or {}
				if p.MeshId then return tostring(p.MeshId):match("%d+") end
			end
		end
	end
	local c = Learned[e.Id]
	if c and c.MeshId then return tostring(c.MeshId):match("%d+") end
	return nil
end

local function learnToolSound(tool)
	local char = LocalPlayer.Character
	if char and tool:IsDescendantOf(char) then return end -- ours is skinned, skip
	task.delay(0.5, function()
		pcall(function()
			local handle = tool:FindFirstChild("Handle")
			if not handle then return end
			local digits = meshDigits(handle)
			if not digits or digits == "" then return end
			for _, s in ipairs(handle:GetDescendants()) do
				if s:IsA("Sound") and s.SoundId ~= "" and not s:GetAttribute("ZZV") then
					if SoundCache[digits] ~= s.SoundId then
						SoundCache[digits] = s.SoundId
						saveSoundCache()
					end
					break
				end
			end
		end)
	end)
end

track(workspace.DescendantAdded:Connect(function(inst)
	if inst:IsA("Tool") and inst.Name == "Gun" then learnToolSound(inst) end
end))

-- play the learned sound when OUR gun fires
task.spawn(function()
	pcall(function()
		local cs = RS:WaitForChild("ClientServices", 10)
		local ws = cs and cs:WaitForChild("WeaponService", 10)
		local ev = ws and ws:WaitForChild("GunFired", 10)
		if not ev then return end
		track(ev.OnClientEvent:Connect(function(p4)
			local e = Equipped.Gun
			if not e then return end
			local char = LocalPlayer.Character
			if typeof(p4) ~= "Instance" or not p4:IsA("BasePart") then return end
			if not char or not p4:IsDescendantOf(char) then return end
			-- hardcoded sound (GUN_SOUNDS) wins; learned cache is the fallback
			local key = entryMeshDigits(e)
			local sid = e.Sound or (key and SoundCache[key])
			if not sid then return end
			local s = Instance.new("Sound")
			s:SetAttribute("ZZV", true)
			s.SoundId = sid
			s.Volume = 1
			s.Parent = p4
			s:Play()
			game:GetService("Debris"):AddItem(s, 4)
			-- guns with a distinct reload sound (Matrixscope): play it right
			-- after the shot, like the real weapon's shoot->reload cycle
			if e.ReloadSound then
				task.delay(0.35, function()
					if Equipped.Gun ~= e or not p4.Parent then return end
					local r = Instance.new("Sound")
					r:SetAttribute("ZZV", true)
					r.SoundId = e.ReloadSound
					r.Volume = 1
					r.Parent = p4
					r:Play()
					game:GetService("Debris"):AddItem(r, 4)
				end)
			end
		end))
	end)
end)

local function applyToTool(tool)
	local e = Equipped[tool.Name]
	if not e then return end
	-- set the icon immediately so the hotbar registers the right image
	if SavedToolTx[tool] == nil then SavedToolTx[tool] = tool.TextureId end
	pcall(function() tool.TextureId = e.Image end)
	patchHotbarIcons(tool, e)
	task.spawn(function()
		local handle = tool:FindFirstChild("Handle") or tool:WaitForChild("Handle", 5)
		if not handle then return end
		if SavedGrips[tool] == nil then SavedGrips[tool] = tool.Grip end
		-- remember the real knife's mesh so we can recognize its thrown clone
		if tool.Name == "Knife" then
			local d = meshDigits(handle)
			if d ~= "" then RealKnifeMesh = d end
		end
		-- Universal hand orientation fix: each weapon model's
		-- CustomAttachment RelCF is IDENTITY for correctly-authored meshes
		-- and a pure rotation for rotated ones (Deathshard 90° yaw,
		-- Frostsaber 99° pitch, Evergun 50° pitch...). Inverting that
		-- rotation stands every weapon up straight in the hand. Legacy
		-- Offset/Angles are hip aesthetics — never used here.
		local fix = CFrame.new()
		if e.MountCF then
			local nm = (tostring(e.Id) .. " " .. e.DisplayName):lower()
			if tool.Name == "Gun" then
				-- GUN meshes are authored barrel-forward (verified live on
				-- the remake's real Gingerscope: handle IS the mesh, grip
				-- rotation identity). Their mount pitch is hip-display
				-- aesthetics — un-pitching it made guns point up, so hold
				-- every gun as-authored. Harvester (scythe gun) is the one
				-- exception: pitch level + slide back to grip the tail.
				if nm:find("harvester") then
					fix = CFrame.new(0, 0, -1.1) * CFrame.Angles(math.rad(-85), 0, 0)
						* (e.MountCF - e.MountCF.Position):Inverse() * CFrame.Angles(0, math.pi, 0)
				end
			else
				-- KNIVES keep the universal fix: invert the mount rotation
				-- to stand the blade up straight in the fist (Deathshard,
				-- Frostsaber etc. verified)
				fix = (e.MountCF - e.MountCF.Position):Inverse()
			end
		end
		applyVisual(handle, e, handle.CFrame * fix)
		-- hide any real-weapon parts that live outside the Handle too
		for _, p in ipairs(tool:GetDescendants()) do
			if p:IsA("BasePart") and p ~= handle and not isOverlayPiece(p) then
				hideOriginal(p)
			end
		end
		-- Mute the default shot sound only when we have a custom one for
		-- this gun — hardcoded (GUN_SOUNDS) or learned — since the
		-- GunFired hook plays ours instead
		if tool.Name == "Gun" then
			local key = entryMeshDigits(e)
			if e.Sound or (key and SoundCache[key]) then
				for _, s in ipairs(handle:GetDescendants()) do
					if s:IsA("Sound") and not s:GetAttribute("ZZV") then
						if SavedVolumes[s] == nil then SavedVolumes[s] = s.Volume end
						pcall(function() s.Volume = 0 end)
					end
				end
			end
		end
		-- Custom shot beams: the game's own gunshot renderer
		-- (GunBeams.CreateBeam) clones handle.CustomBeam if it exists —
		-- plant the weapon's beam from the dump so shots match the gun.
		if tool.Name == "Gun" then
			local orig = handle:FindFirstChild("CustomBeam")
			if orig and not orig:GetAttribute("ZZV") then
				orig.Name = "ZZOrig_CustomBeam" -- don't let the real one shadow ours
			end
			local props = findCustomBeamProps(e.Rich) or e.Beam
			if props and OverlayRoot[handle] then
				local b = Instance.new("Beam")
				for k, v in pairs(props) do
					pcall(function() b[k] = v end)
				end
				b.Name = "CustomBeam"
				b:SetAttribute("ZZV", true)
				b.Parent = handle
				table.insert(OverlayRoot[handle], b)
			end
		end
		tool.Grip = e.Grip
	end)
end

function scanTools()
	for _, container in ipairs({LocalPlayer.Character, LocalPlayer:FindFirstChild("Backpack")}) do
		if container then
			for _, c in ipairs(container:GetChildren()) do
				if c:IsA("Tool") and Equipped[c.Name] then applyToTool(c) end
			end
		end
	end
end

local function hookContainer(container)
	track(container.ChildAdded:Connect(function(child)
		if child:IsA("Tool") and (child.Name == "Knife" or child.Name == "Gun") then
			-- set the icon synchronously, before the hotbar registers the tool
			local e = Equipped[child.Name]
			if e and e.Image ~= "" then
				if SavedToolTx[child] == nil then SavedToolTx[child] = child.TextureId end
				pcall(function() child.TextureId = e.Image end)
			end
			task.wait()
			applyToTool(child)
		end
	end))
end

--------------------------------------------------------------------
-- Reset Visuals (per-type aware)
--------------------------------------------------------------------
local function resetVisuals(specificType)
	local types = specificType and {specificType} or {"Knife", "Gun"}
	for _, itemType in ipairs(types) do
		Equipped[itemType] = nil
		ApplyTokens[itemType] += 1 -- cancel any pending apply loops

		-- display: clear overlay, restore only this display's hidden parts + attachment
		local target = myDisplay(itemType .. "Display")
		if target then
			clearOverlay(target)
			BuildTokens[target] = (BuildTokens[target] or 0) + 1
			Building[target] = nil
			restoreHiddenUnder(target)
			local att = target:FindFirstChild("Attachment")
			if att and SavedAttCF[att] ~= nil then
				pcall(function() att.CFrame = SavedAttCF[att] end)
				SavedAttCF[att] = nil
			end
		end

		-- stop the custom hold animation/pose with the gun reset
		if itemType == "Gun" then
			if HoldTrack then
				pcall(function() HoldTrack:Stop() end)
				HoldTrack, HoldTrackId = nil, nil
			end
			pcall(setRiflePose, LocalPlayer.Character, false)
		end

		-- tools of this type: clear overlay on handle, restore grip/texture
		for tool, grip in pairs(SavedGrips) do
			if tool.Parent and tool.Name == itemType then
				pcall(function() tool.Grip = grip end)
				SavedGrips[tool] = nil
				local h = tool:FindFirstChild("Handle")
				if h then
					clearOverlay(h)
					BuildTokens[h] = (BuildTokens[h] or 0) + 1
					Building[h] = nil
					restoreHiddenUnder(h)
					local ob = h:FindFirstChild("ZZOrig_CustomBeam")
					if ob then ob.Name = "CustomBeam" end
					for s, v in pairs(SavedVolumes) do
						if s:IsDescendantOf(tool) then
							pcall(function() s.Volume = v end)
							SavedVolumes[s] = nil
						end
					end
				end
			end
		end
		for tool, tex in pairs(SavedToolTx) do
			if tool.Parent and tool.Name == itemType then
				pcall(function() tool.TextureId = tex end)
				SavedToolTx[tool] = nil
			end
		end

		-- Fallback: the new real tool may have arrived after SavedGrips was
		-- checked (async race). Sweep character + backpack and restore any
		-- hidden handle not already covered above.
		for _, cont in ipairs({LocalPlayer.Character, LocalPlayer:FindFirstChild("Backpack")}) do
			local t = cont and cont:FindFirstChild(itemType)
			if t and t:IsA("Tool") then
				local h = t:FindFirstChild("Handle")
				if h then
					clearOverlay(h)
					BuildTokens[h] = (BuildTokens[h] or 0) + 1
					Building[h] = nil
					restoreHiddenUnder(h)
				end
			end
		end

		resetEquippedSlot(itemType)
	end

	-- full reset: sweep anything the per-type pass could not reach
	if not specificType then
		for part in pairs(OverlayRoot) do clearOverlay(part) end
		for inst, state in pairs(Hidden) do
			if inst.Parent then
				pcall(function()
					if state.Transparency ~= nil then inst.Transparency = state.Transparency end
					if state.Enabled ~= nil then inst.Enabled = state.Enabled end
				end)
			end
		end
		Hidden = {}
		for att, cf in pairs(SavedAttCF) do
			if att.Parent then pcall(function() att.CFrame = cf end) end
		end
		SavedAttCF = {}
		for tool, grip in pairs(SavedGrips) do
			if tool.Parent then pcall(function() tool.Grip = grip end) end
		end
		SavedGrips = {}
		for tool, tex in pairs(SavedToolTx) do
			if tool.Parent then pcall(function() tool.TextureId = tex end) end
		end
		SavedToolTx = {}
		for s, v in pairs(SavedVolumes) do
			if s.Parent then pcall(function() s.Volume = v end) end
		end
		SavedVolumes = {}
	end

	if updateFooter then updateFooter() end
end

--------------------------------------------------------------------
-- Dynamic Chroma Color-Shifter Loop
--------------------------------------------------------------------
local function isChromaEntry(e)
	-- Chroma variants are flagged in the game DB (Sync.Item[id].Chroma);
	-- name/rarity checks are only kept as fallbacks.
	return e ~= nil and (e.Chroma == true or e.Rarity == "Chroma" or e.DisplayName:lower():find("chroma") ~= nil)
end

-- Returns "Knife"/"Gun" if this overlay anchor belongs to an equipped chroma
local function chromaSlotForAnchor(anchor)
	-- thrown-knife projectiles/stuck knives count as the knife slot
	local thrown = ThrownAnchors[anchor]
	if thrown and isChromaEntry(Equipped[thrown]) then return thrown end
	for _, slot in ipairs({"Knife", "Gun"}) do
		local e = Equipped[slot]
		if isChromaEntry(e) then
			if anchor.Name == slot .. "Display"
				or (anchor.Parent and anchor.Parent:IsA("Tool") and anchor.Parent.Name == slot) then
				return slot
			end
		end
	end
	return nil
end

task.spawn(function()
	local hue = 0
	while true do
		-- idle cheaply when no chroma is equipped
		if not (isChromaEntry(Equipped.Knife) or isChromaEntry(Equipped.Gun)) then
			task.wait(0.25)
		else
			task.wait(0.03)
			hue = (hue + 0.0035) % 1 -- slower, like the real game
			local chromaColor = Color3.fromHSV(hue, 1, 1)

			-- (GUI elements — inventory cards, HUD slot, end screen — keep
			-- their static rarity color like the real game; only the 3D
			-- weapon shifts.)

			-- Shift overlay parts for equipped chroma tools & displays,
			-- matching how the REAL game does it — never repaint the whole
			-- weapon when it has proper chroma data:
			--   a) a Decal named "Chroma" (wrap texture) -> shift its Color3
			--   b) no Chroma decal (Evergun-style): the chroma area is the
			--      UNTEXTURED base part showing through the decals' clear
			--      regions (the strips) -> shift only those parts' Color,
			--      keep every texture/decal, skip LightParts (they flicker)
			--   c) no data at all (plain fallback mesh) -> old strip+tint
			for anchor, parts in pairs(OverlayRoot) do
				if chromaSlotForAnchor(anchor) then
					local chromaDecals, colorParts = {}, {}
					for _, inst in ipairs(parts) do
						if inst:IsA("BasePart") then
							for _, d in ipairs(inst:GetDescendants()) do
								if d:IsA("Decal") and d.Name == "Chroma" then
									table.insert(chromaDecals, d)
								end
							end
							if not inst.Name:find("LightPart") then
								local untextured
								if inst:IsA("MeshPart") then
									untextured = (inst.TextureID == "")
								else
									local sm = inst:FindFirstChildOfClass("SpecialMesh")
									untextured = (not sm) or (sm.TextureId == "")
								end
								if untextured then table.insert(colorParts, inst) end
							end
						end
					end
					if #chromaDecals > 0 then
						for _, d in ipairs(chromaDecals) do
							pcall(function() d.Color3 = chromaColor end)
						end
					elseif #colorParts > 0 then
						for _, inst in ipairs(colorParts) do
							pcall(function() inst.Color = chromaColor end)
						end
					else
						for _, inst in ipairs(parts) do
							if inst:IsA("BasePart") then
								pcall(function()
									if inst:IsA("MeshPart") and inst.TextureID ~= "" then
										inst.TextureID = ""
									end
									inst.Color = chromaColor
								end)
								for _, d in ipairs(inst:GetDescendants()) do
									if d:IsA("SpecialMesh") then
										pcall(function()
											if d.TextureId ~= "" then d.TextureId = "" end
											d.VertexColor = Vector3.new(1, 1, 1)
										end)
									elseif d:IsA("Decal") or d:IsA("Texture") then
										pcall(function() d.Transparency = 1 end)
									end
								end
							end
						end
					end
				end
			end
		end
	end
end)

--------------------------------------------------------------------
-- Christmas-light flicker (Evergun/Evergreen etc.): every overlay
-- part named LightPart flips independently between red/green/blue
-- like real string lights — never all at once.
--------------------------------------------------------------------
local LIGHT_COLORS = {
	Color3.fromRGB(255, 70, 70),
	Color3.fromRGB(85, 255, 95),
	Color3.fromRGB(85, 140, 255),
}

task.spawn(function()
	local rng = Random.new()
	while true do
		task.wait(0.4)
		if Equipped.Knife or Equipped.Gun then
			for _, parts in pairs(OverlayRoot) do
				for _, inst in ipairs(parts) do
					if inst:IsA("BasePart") and inst.Name:find("LightPart") then
						-- each bulb has its own chance to switch this tick
						if rng:NextNumber() < 0.45 then
							local c = LIGHT_COLORS[rng:NextInteger(1, #LIGHT_COLORS)]
							pcall(function()
								inst.Color = c
								local li = inst:FindFirstChildWhichIsA("PointLight")
									or inst:FindFirstChildWhichIsA("SurfaceLight")
									or inst:FindFirstChildWhichIsA("SpotLight")
								if li then li.Color = c end
							end)
						end
					end
				end
			end
		end
	end
end)

--==================================================================--
--  YOGOMI SPAWNER — GUI
--==================================================================--
-- Monochrome black theme (white accents)
local THEME = {
	Bg        = Color3.fromRGB(12, 12, 12),
	Panel     = Color3.fromRGB(20, 20, 20),
	Panel2    = Color3.fromRGB(34, 34, 34),
	Card      = Color3.fromRGB(24, 24, 24),
	CardHover = Color3.fromRGB(42, 42, 42),
	Stroke    = Color3.fromRGB(70, 70, 70),
	Accent    = Color3.fromRGB(245, 245, 245),
	Accent2   = Color3.fromRGB(165, 165, 165),
	OnAccent  = Color3.fromRGB(12, 12, 12),
	Text      = Color3.fromRGB(245, 245, 245),
	TextDim   = Color3.fromRGB(145, 145, 145),
	Danger    = Color3.fromRGB(245, 245, 245),
}

local function mk(class, props, parent)
	local inst = Instance.new(class)
	for k, v in pairs(props) do inst[k] = v end
	if parent then inst.Parent = parent end
	return inst
end

local function corner(parent, r)
	return mk("UICorner", {CornerRadius = UDim.new(0, r or 8)}, parent)
end

local function stroke(parent, color, thickness, transparency)
	return mk("UIStroke", {
		Color = color or THEME.Stroke,
		Thickness = thickness or 1,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, parent)
end

local function tween(inst, props, t)
	TweenService:Create(inst, TweenInfo.new(t or 0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
end

-- Headless mode: when the hub (or any caller) sets this flag, the engine
-- runs fully in the background — no floating window, bubble, or V toggle —
-- and is driven only by _G.YomogiSpawnByName.
local HEADLESS = (getgenv and getgenv().YomogiHeadless) and true or (_G.YomogiHeadless and true) or false

local spawnerGui = mk("ScreenGui", {
	Name = "WolokoScriptsGui",
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	IgnoreGuiInset = true,
	Enabled = not HEADLESS,
})

local mainFrame = mk("Frame", {
	Name = "Main",
	Size = UDim2.new(0, 480, 0, 540),
	Position = UDim2.new(0.5, -240, 0.5, -270),
	BackgroundColor3 = THEME.Bg,
	BorderSizePixel = 0,
	Active = true,
	ClipsDescendants = true,
}, spawnerGui)
corner(mainFrame, 14)
stroke(mainFrame, THEME.Stroke, 1, 0.2)
-- (drop shadow removed — no dark halo around the window)

--------------------------------------------------------------------
-- Header
--------------------------------------------------------------------
local header = mk("Frame", {
	Name = "Header",
	Size = UDim2.new(1, 0, 0, 52),
	BackgroundColor3 = THEME.Panel,
	BorderSizePixel = 0,
}, mainFrame)
corner(header, 14)
-- square off the bottom corners of the header
mk("Frame", {
	Size = UDim2.new(1, 0, 0, 14),
	Position = UDim2.new(0, 0, 1, -14),
	BackgroundColor3 = THEME.Panel,
	BorderSizePixel = 0,
}, header)

-- gradient accent line under header
local accentLine = mk("Frame", {
	Size = UDim2.new(1, 0, 0, 2),
	Position = UDim2.new(0, 0, 1, 0),
	BackgroundColor3 = Color3.new(1, 1, 1),
	BorderSizePixel = 0,
	ZIndex = 3,
}, header)
mk("UIGradient", {
	Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, THEME.Accent),
		ColorSequenceKeypoint.new(0.5, THEME.Accent2),
		ColorSequenceKeypoint.new(1, THEME.Accent),
	}),
}, accentLine)

-- logo mark
local logo = mk("TextLabel", {
	Size = UDim2.new(0, 34, 0, 34),
	Position = UDim2.new(0, 12, 0, 9),
	BackgroundColor3 = THEME.Accent,
	Text = "Y",
	TextColor3 = THEME.OnAccent,
	TextSize = 20,
	Font = Enum.Font.GothamBlack,
	ZIndex = 2,
}, header)
corner(logo, 10)
mk("UIGradient", {
	Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, THEME.Accent),
		ColorSequenceKeypoint.new(1, THEME.Accent2),
	}),
	Rotation = 45,
}, logo)

mk("TextLabel", {
	Size = UDim2.new(0, 220, 0, 20),
	Position = UDim2.new(0, 56, 0, 8),
	BackgroundTransparency = 1,
	Text = "Woloko Spawner",
	TextColor3 = THEME.Text,
	TextSize = 17,
	Font = Enum.Font.GothamBold,
	TextXAlignment = Enum.TextXAlignment.Left,
	ZIndex = 2,
}, header)

mk("TextLabel", {
	Size = UDim2.new(0, 260, 0, 14),
	Position = UDim2.new(0, 56, 0, 28),
	BackgroundTransparency = 1,
	Text = ("MM2 Spawner  •  %d weapons  •  [V] to hide"):format(#SortedList),
	TextColor3 = THEME.TextDim,
	TextSize = 12,
	Font = Enum.Font.Gotham,
	TextXAlignment = Enum.TextXAlignment.Left,
	ZIndex = 2,
}, header)

local closeBtn = mk("TextButton", {
	Size = UDim2.new(0, 30, 0, 30),
	Position = UDim2.new(1, -40, 0, 11),
	BackgroundColor3 = THEME.Panel2,
	Text = "×",
	TextColor3 = THEME.TextDim,
	TextSize = 20,
	Font = Enum.Font.GothamBold,
	AutoButtonColor = false,
	ZIndex = 2,
}, header)
corner(closeBtn, 8)
closeBtn.MouseEnter:Connect(function() tween(closeBtn, {BackgroundColor3 = THEME.Danger, TextColor3 = THEME.OnAccent}) end)
closeBtn.MouseLeave:Connect(function() tween(closeBtn, {BackgroundColor3 = THEME.Panel2, TextColor3 = THEME.TextDim}) end)

-- custom drag on header
do
	local dragging, dragStart, startPos = false, nil, nil
	header.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startPos = mainFrame.Position
		end
	end)
	track(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end))
	track(UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = input.Position - dragStart
			mainFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end
	end))
end

--------------------------------------------------------------------
-- Controls: search + filter pills + reset buttons
--------------------------------------------------------------------
local controls = mk("Frame", {
	Size = UDim2.new(1, -24, 0, 74),
	Position = UDim2.new(0, 12, 0, 62),
	BackgroundTransparency = 1,
}, mainFrame)

local searchHolder = mk("Frame", {
	Size = UDim2.new(1, 0, 0, 34),
	BackgroundColor3 = THEME.Panel,
	BorderSizePixel = 0,
}, controls)
corner(searchHolder, 10)
local searchStroke = stroke(searchHolder, THEME.Stroke, 1, 0.35)

mk("TextLabel", {
	Size = UDim2.new(0, 30, 1, 0),
	BackgroundTransparency = 1,
	Text = "⌕",
	TextColor3 = THEME.TextDim,
	TextSize = 18,
	Font = Enum.Font.GothamBold,
}, searchHolder)

local searchBox = mk("TextBox", {
	Size = UDim2.new(1, -38, 1, 0),
	Position = UDim2.new(0, 32, 0, 0),
	BackgroundTransparency = 1,
	PlaceholderText = "Search weapons...",
	Text = "",
	TextColor3 = THEME.Text,
	PlaceholderColor3 = THEME.TextDim,
	TextSize = 14,
	Font = Enum.Font.Gotham,
	TextXAlignment = Enum.TextXAlignment.Left,
	ClearTextOnFocus = false,
}, searchHolder)
searchBox.Focused:Connect(function() tween(searchStroke, {Color = THEME.Accent, Transparency = 0}) end)
searchBox.FocusLost:Connect(function() tween(searchStroke, {Color = THEME.Stroke, Transparency = 0.35}) end)

-- filter pills (segmented control)
local pillRow = mk("Frame", {
	Size = UDim2.new(1, 0, 0, 30),
	Position = UDim2.new(0, 0, 0, 44),
	BackgroundTransparency = 1,
}, controls)

local currentTab = "All"
local pills = {}
local pillDefs = {
	{key = "All",   label = "All"},
	{key = "Knife", label = "Knives"},
	{key = "Gun",   label = "Guns"},
}
local renderList -- forward

local function setTab(key)
	currentTab = key
	for k, btn in pairs(pills) do
		if k == key then
			tween(btn, {BackgroundColor3 = THEME.Accent, TextColor3 = THEME.OnAccent})
		else
			tween(btn, {BackgroundColor3 = THEME.Panel, TextColor3 = THEME.TextDim})
		end
	end
	renderList()
end

for i, def in ipairs(pillDefs) do
	local btn = mk("TextButton", {
		Size = UDim2.new(0, 74, 1, 0),
		Position = UDim2.new(0, (i - 1) * 80, 0, 0),
		BackgroundColor3 = def.key == "All" and THEME.Accent or THEME.Panel,
		Text = def.label,
		TextColor3 = def.key == "All" and THEME.OnAccent or THEME.TextDim,
		TextSize = 13,
		Font = Enum.Font.GothamBold,
		AutoButtonColor = false,
	}, pillRow)
	corner(btn, 15)
	pills[def.key] = btn
	btn.MouseButton1Click:Connect(function() setTab(def.key) end)
	btn.MouseEnter:Connect(function()
		if currentTab ~= def.key then tween(btn, {BackgroundColor3 = THEME.Panel2}) end
	end)
	btn.MouseLeave:Connect(function()
		if currentTab ~= def.key then tween(btn, {BackgroundColor3 = THEME.Panel}) end
	end)
end

-- reset buttons
local function makeResetBtn(text, xOffset, slot)
	local btn = mk("TextButton", {
		Size = UDim2.new(0, 88, 1, 0),
		Position = UDim2.new(1, xOffset, 0, 0),
		BackgroundColor3 = THEME.Panel,
		Text = text,
		TextColor3 = THEME.Text,
		TextSize = 12,
		Font = Enum.Font.GothamBold,
		AutoButtonColor = false,
	}, pillRow)
	corner(btn, 15)
	stroke(btn, THEME.Accent, 1, 0.4)
	btn.MouseEnter:Connect(function() tween(btn, {BackgroundColor3 = THEME.Accent, TextColor3 = THEME.OnAccent}) end)
	btn.MouseLeave:Connect(function() tween(btn, {BackgroundColor3 = THEME.Panel, TextColor3 = THEME.Text}) end)
	btn.MouseButton1Click:Connect(function() resetVisuals(slot) end)
	return btn
end
makeResetBtn("Reset Knife", -184, "Knife")
makeResetBtn("Reset Gun", -88, "Gun")

--------------------------------------------------------------------
-- Weapon grid
--------------------------------------------------------------------
local scrollFrame = mk("ScrollingFrame", {
	Size = UDim2.new(1, -16, 1, -178),
	Position = UDim2.new(0, 12, 0, 144),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	ScrollBarThickness = 4,
	ScrollBarImageColor3 = THEME.Accent,
	ScrollBarImageTransparency = 0.3,
	CanvasSize = UDim2.new(0, 0, 0, 0),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, mainFrame)

mk("UIGridLayout", {
	CellSize = UDim2.new(0, 105, 0, 122),
	CellPadding = UDim2.new(0, 9, 0, 9),
	SortOrder = Enum.SortOrder.LayoutOrder,
}, scrollFrame)

--------------------------------------------------------------------
-- Footer: equipped status
--------------------------------------------------------------------
local footer = mk("Frame", {
	Size = UDim2.new(1, 0, 0, 26),
	Position = UDim2.new(0, 0, 1, -26),
	BackgroundColor3 = THEME.Panel,
	BorderSizePixel = 0,
}, mainFrame)

local footerLabel = mk("TextLabel", {
	Size = UDim2.new(1, -100, 1, 0),
	Position = UDim2.new(0, 12, 0, 0),
	BackgroundTransparency = 1,
	Text = "",
	TextColor3 = THEME.TextDim,
	TextSize = 12,
	Font = Enum.Font.Gotham,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextTruncate = Enum.TextTruncate.AtEnd,
}, footer)

mk("TextLabel", {
	Size = UDim2.new(0, 160, 1, 0),
	Position = UDim2.new(1, -172, 0, 0),
	BackgroundTransparency = 1,
	Text = "Woloko scripts on tt",
	TextColor3 = THEME.TextDim,
	TextSize = 12,
	Font = Enum.Font.GothamBold,
	TextXAlignment = Enum.TextXAlignment.Right,
}, footer)

function updateFooter()
	local k = Equipped.Knife and Equipped.Knife.DisplayName or "—"
	local g = Equipped.Gun and Equipped.Gun.DisplayName or "—"
	footerLabel.Text = ("Knife:  %s      Gun:  %s"):format(k, g)
end
updateFooter()

--------------------------------------------------------------------
-- Card renderer
--------------------------------------------------------------------
function renderList()
	for _, child in ipairs(scrollFrame:GetChildren()) do
		if child:IsA("GuiObject") then child:Destroy() end
	end

	local query = searchBox.Text:lower()
	local order = 0

	for _, e in ipairs(SortedList) do
		-- "chroma" still matches chroma variants even though the name is
		-- plain now (the badge marks them instead)
		local hay = e.DisplayName:lower() .. (e.Chroma and " chroma" or "")
		if (currentTab == "All" or e.Type == currentTab) and (query == "" or hay:find(query, 1, true)) then
			order += 1
			local card = mk("ImageButton", {
				BackgroundColor3 = THEME.Card,
				BorderSizePixel = 0,
				AutoButtonColor = false,
				LayoutOrder = order,
			})
			corner(card, 10)
			local cardStroke = stroke(card, THEME.Stroke, 1, 0.6)

			-- rarity glow bar
			local rarityBar = mk("Frame", {
				Size = UDim2.new(1, -16, 0, 3),
				Position = UDim2.new(0, 8, 0, 0),
				BackgroundColor3 = e.GuiColor,
				BorderSizePixel = 0,
			}, card)
			corner(rarityBar, 2)

			mk("ImageLabel", {
				Size = UDim2.new(0.72, 0, 0.52, 0),
				Position = UDim2.new(0.14, 0, 0.09, 0),
				BackgroundTransparency = 1,
				Image = e.Image,
				ScaleType = Enum.ScaleType.Fit,
			}, card)

			mk("TextLabel", {
				Size = UDim2.new(1, -10, 0, 16),
				Position = UDim2.new(0, 5, 0.63, 0),
				BackgroundTransparency = 1,
				Text = e.DisplayName,
				TextColor3 = THEME.Text,
				TextSize = 12,
				Font = Enum.Font.GothamBold,
				TextTruncate = Enum.TextTruncate.AtEnd,
			}, card)

			mk("TextLabel", {
				Size = UDim2.new(1, -10, 0, 13),
				Position = UDim2.new(0, 5, 0.78, 0),
				BackgroundTransparency = 1,
				Text = e.Rarity,
				TextColor3 = e.GuiColor,
				TextSize = 11,
				Font = Enum.Font.GothamMedium,
				TextTruncate = Enum.TextTruncate.AtEnd,
			}, card)

			mk("TextLabel", {
				Size = UDim2.new(1, -10, 0, 12),
				Position = UDim2.new(0, 5, 0.89, 0),
				BackgroundTransparency = 1,
				Text = e.Type,
				TextColor3 = THEME.TextDim,
				TextSize = 10,
				Font = Enum.Font.Gotham,
			}, card)

			-- real MM2 tag badges (rainbow Chroma bar, ❄/🎃 year, FX, Evo)
			-- cloned from the game's own card template; they stack bottom-up
			-- ending just above the name row, like the real inventory
			if TagsTemplate and (e.Chroma or e.FX or e.Evo
				or e.Category == "Christmas" or e.Category == "Halloween") then
				local tags = TagsTemplate:Clone()
				tags.Name = "Tags"
				tags.AnchorPoint = Vector2.new(0, 1)
				tags.Position = UDim2.new(0, 3, 0.61, 0)
				tags.Size = UDim2.new(1, -6, 0.75, 0)
				tags.ZIndex = 3
				for _, d in ipairs(tags:GetDescendants()) do
					if d:IsA("GuiObject") then d.ZIndex = 3 end
				end
				applyTags(tags, e)
				-- readability at card scale: bigger event badge, scaled text
				for _, nm2 in ipairs({"Christmas", "Halloween"}) do
					local tf = tags:FindFirstChild(nm2)
					if tf then
						tf.Size = UDim2.new(0.42, 0, 0.42, 0)
						local y = tf:FindFirstChild("Year")
						if y then pcall(function() y.TextScaled = true end) end
					end
				end
				for _, nm2 in ipairs({"Chroma", "FX", "Evo"}) do
					local tf = tags:FindFirstChild(nm2)
					if tf then
						tf.Size = UDim2.new(0.62, 0, 0.16, 0)
						local tn = tf:FindFirstChild("TagName")
						if tn then pcall(function() tn.TextScaled = true end) end
					end
				end
				tags.Parent = card
			end

			card.MouseEnter:Connect(function()
				tween(card, {BackgroundColor3 = THEME.CardHover})
				tween(cardStroke, {Color = e.GuiColor, Transparency = 0.15})
			end)
			card.MouseLeave:Connect(function()
				tween(card, {BackgroundColor3 = THEME.Card})
				tween(cardStroke, {Color = THEME.Stroke, Transparency = 0.6})
			end)

			card.MouseButton1Click:Connect(function()
				Equipped[e.Type] = e
				updateEquippedSlot(e)
				applyToDisplay(e.Type)
				scanTools()
				updateFooter()
				if bumpSpawnCount then bumpSpawnCount(e) end
				tween(cardStroke, {Color = THEME.Accent, Transparency = 0})
				task.delay(0.35, function()
					if card.Parent then tween(cardStroke, {Color = THEME.Stroke, Transparency = 0.6}) end
				end)
				pcall(function()
					game:GetService("StarterGui"):SetCore("SendNotification", {
						Title = "Yogomi Spawner",
						Text = e.DisplayName .. " equipped (" .. e.Category .. " tab)",
						Duration = 1.5,
					})
				end)
			end)

			card.Parent = scrollFrame
		end
	end
end

--------------------------------------------------------------------
-- Reopen bubble + visibility toggles
--------------------------------------------------------------------
local bubble = mk("TextButton", {
	Name = "WolokoBubble",
	Size = UDim2.new(0, 44, 0, 44),
	Position = UDim2.new(0, 16, 0.5, -22),
	BackgroundColor3 = THEME.Accent,
	Text = "Y",
	TextColor3 = THEME.OnAccent,
	TextSize = 22,
	Font = Enum.Font.GothamBlack,
	Visible = false,
	AutoButtonColor = false,
}, spawnerGui)
corner(bubble, 22)
mk("UIGradient", {
	Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, THEME.Accent),
		ColorSequenceKeypoint.new(1, THEME.Accent2),
	}),
	Rotation = 45,
}, bubble)
stroke(bubble, Color3.new(1, 1, 1), 1, 0.75)

local function setVisible(v)
	if HEADLESS then
		spawnerGui.Enabled = false
		mainFrame.Visible = false
		bubble.Visible = false
		return
	end
	mainFrame.Visible = v
	bubble.Visible = not v
end

closeBtn.MouseButton1Click:Connect(function() setVisible(false) end)
bubble.MouseButton1Click:Connect(function() setVisible(true) end)
bubble.MouseEnter:Connect(function() tween(bubble, {Size = UDim2.new(0, 48, 0, 48)}) end)
bubble.MouseLeave:Connect(function() tween(bubble, {Size = UDim2.new(0, 44, 0, 44)}) end)

track(UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if HEADLESS then return end
	if not gameProcessed and input.KeyCode == Enum.KeyCode.V then
		setVisible(not mainFrame.Visible)
	end
end))

-- debounce the search so typing doesn't rebuild ~900 cards per keystroke
local searchToken = 0
searchBox:GetPropertyChangedSignal("Text"):Connect(function()
	searchToken += 1
	local t = searchToken
	task.delay(0.15, function()
		if t == searchToken then renderList() end
	end)
end)

local success, container = pcall(function() return game:GetService("CoreGui") end)
if not success or not container then container = LocalPlayer:WaitForChild("PlayerGui") end
spawnerGui.Parent = container

if HEADLESS then
	spawnerGui.Enabled = false
else
	renderList() -- skip building ~957 cards when the window is never shown
end

--------------------------------------------------------------------
-- Lifecycle listeners
--------------------------------------------------------------------
local function onCharacter(char)
	hookContainer(char)
	local backpack = LocalPlayer:WaitForChild("Backpack", 10)
	if backpack then hookContainer(backpack) end
	scanTools()
	applyToDisplay("Knife")
	applyToDisplay("Gun")

	task.spawn(function()
		task.wait(1.5)
		if Equipped.Knife then updateEquippedSlot(Equipped.Knife) end
		if Equipped.Gun then updateEquippedSlot(Equipped.Gun) end
	end)
end

track(LocalPlayer.CharacterAdded:Connect(function(char)
	task.wait(0.5)
	onCharacter(char)
end))

if LocalPlayer.Character then
	hookContainer(LocalPlayer.Character)
	local backpack = LocalPlayer:FindFirstChild("Backpack")
	if backpack then hookContainer(backpack) end
end

local wdFolder = workspace:FindFirstChild("WeaponDisplays")
if wdFolder then
	track(wdFolder.ChildAdded:Connect(function()
		task.wait(0.5)
		applyToDisplay("Knife")
		applyToDisplay("Gun")
	end))
end

--------------------------------------------------------------------
-- Round VS / end screen ("Murderer has won." etc.): when the local
-- player is the Murderer/Sheriff shown, swap the Default Knife/Gun
-- panel to the weapon equipped in the spawner.
--------------------------------------------------------------------
local VS_ROLES = {
	{role = "Murderer", slot = "Knife", frame = "KnifeFrame"},
	{role = "Sheriff",  slot = "Gun",   frame = "GunFrame"},
}

local function patchVersusFrames()
	local pg = LocalPlayer:FindFirstChild("PlayerGui")
	local sb = pg and pg:FindFirstChild("Scoreboard")
	if not sb then return end
	for _, mode in ipairs(sb:GetChildren()) do -- Classic, ScaryMode, Assassin, BonusModes
		local cont = mode:FindFirstChild("Container")
		local vf = cont and cont:FindFirstChild("VersusFrame")
		local vc = vf and vf:FindFirstChild("Container")
		if vc then
			for _, def in ipairs(VS_ROLES) do
				local e = Equipped[def.slot]
				local rf = vc:FindFirstChild(def.role)
				local pn = rf and rf:FindFirstChild("Container")
				pn = pn and pn:FindFirstChild("PlayerName")
				if e and pn and (pn.Text == LocalPlayer.Name or pn.Text == LocalPlayer.DisplayName) then
					local wf = vc:FindFirstChild(def.frame)
					if wf then
						-- static rarity color for the name band, like the real game
						local col = e.GuiColor
						local itemName = wf:FindFirstChild("ItemName")
						local label = itemName and itemName:FindFirstChild("Label")
						if label and label.Text ~= e.DisplayName then label.Text = e.DisplayName end
						if itemName then
							pcall(function() itemName.BackgroundColor3 = col end)
							local bg = itemName:FindFirstChild("BG")
							if bg then pcall(function() bg.ImageColor3 = col end) end
						end
						local icon = wf:FindFirstChild("Container")
						icon = icon and icon:FindFirstChild("Icon")
						if icon and icon.Image ~= e.Image then icon.Image = e.Image end
					end
				end
			end
		end
	end
end

task.spawn(function()
	while spawnerGui.Parent do
		task.wait(0.35)
		pcall(patchVersusFrames)
	end
end)

--------------------------------------------------------------------
-- Spawn counts (clicking a card again adds another copy, shown xN)
--------------------------------------------------------------------
local SpawnedCount = {}

local function updateCardAmount(e)
	local weapons = getInventory()
	local items = weapons and weapons:FindFirstChild("Items")
	local tabs = items and items:FindFirstChild("Container")
	local grid = tabs and getCategoryGrid(tabs, e.Category or "Classic")
	local card = grid and grid:FindFirstChild(FAKE_PREFIX .. e.Id)
	local amount = card and card:FindFirstChild("Container")
	amount = amount and amount:FindFirstChild("Amount")
	if amount then
		local n = SpawnedCount[e.Id] or 1
		amount.Text = n > 1 and ("x" .. n) or ""
	end
end

function bumpSpawnCount(e)
	SpawnedCount[e.Id] = (SpawnedCount[e.Id] or 0) + 1
	task.delay(0.1, function() pcall(updateCardAmount, e) end)
	-- also add a real inventory copy (modded games) so it shows in trade
	if realSpawnItem then pcall(realSpawnItem, e) end
end

--------------------------------------------------------------------
-- Persistence loop: MM2 re-shows the real weapon on equip/unequip/
-- throw, which used to leave the original poking through the overlay
-- and reset thrown knives to default. Every tick this:
--  * keeps the real display/tool weapon hidden
--  * hides the hip/back overlay while that tool is drawn (real
--    behaviour) and shows it again when holstered
--  * rebuilds the tool overlay if the game wiped it (knife throw)
--  * keeps Tool.TextureId + the hotbar slot icon on the spawned skin
--------------------------------------------------------------------
-- Custom hold animation (Gingerscope): play while OUR gun is drawn,
-- stop when holstered/reset. Re-asserted by the persistence loop.
local function updateHoldAnim()
	local e = Equipped.Gun
	local char = LocalPlayer.Character
	local tool = char and char:FindFirstChild("Gun")
	local want = (e and e.HoldAnim and tool and tool:IsA("Tool")) and e.HoldAnim or nil
	if want then
		-- two-hand pose always applies (the foreign animation below rarely
		-- loads outside its own game, this is the reliable part)
		setRiflePose(char, true)
		if HoldTrack and HoldTrackId == want and HoldTrack.IsPlaying then return end
		if HoldTrack then pcall(function() HoldTrack:Stop(0.1) end) HoldTrack = nil end
		local hum = char:FindFirstChildOfClass("Humanoid")
		local animator = hum and hum:FindFirstChildOfClass("Animator")
		if not animator then return end
		local a = Instance.new("Animation")
		a.AnimationId = want
		local ok, tr = pcall(animator.LoadAnimation, animator, a)
		if ok and tr then
			tr.Priority = Enum.AnimationPriority.Action
			tr.Looped = true
			local played = pcall(function() tr:Play(0.1) end)
			if played then HoldTrack, HoldTrackId = tr, want end
		end
	else
		setRiflePose(char, false)
		if HoldTrack then
			pcall(function() HoldTrack:Stop(0.1) end)
			HoldTrack, HoldTrackId = nil, nil
		end
	end
end

local function setOverlayDrawn(made, drawn)
	for _, inst in ipairs(made) do
		local base = OverlayBaseTx[inst]
		if base ~= nil then
			local want = drawn and 1 or base
			pcall(function()
				if inst.Transparency ~= want then inst.Transparency = want end
			end)
			if inst:IsA("BasePart") then
				for _, d in ipairs(inst:GetDescendants()) do
					local dBase = OverlayBaseTx[d]
					if dBase ~= nil then
						local dWant = drawn and 1 or dBase
						pcall(function()
							if d.Transparency ~= dWant then d.Transparency = dWant end
						end)
					end
				end
			end
		end
		local baseEn = OverlayBaseEn[inst]
		if baseEn ~= nil then
			pcall(function() inst.Enabled = (not drawn) and baseEn end)
		end
	end
end

local function patchHotbarSlot(slot, e)
	local bpg = game:GetService("CoreGui"):FindFirstChild("BackpackGui")
	if not bpg then return end
	for _, d in ipairs(bpg:GetDescendants()) do
		if d:IsA("ImageLabel") and (d.Name == "ToolIcon" or d.Name == "Icon") then
			local tn = d.Parent and d.Parent:FindFirstChild("ToolName")
			if tn and tn.Text == slot and d.Image ~= e.Image then
				d.Image = e.Image
			end
		end
	end
end

-- Hook real (non-fake) inventory card buttons so clicking them resets the
-- spawner skin for that slot, letting the real weapon show normally.
local function hookRealCards()
	local weapons = getInventory()
	local items = weapons and weapons:FindFirstChild("Items")
	local tabs = items and items:FindFirstChild("Container")
	if not tabs then return end
	local function checkGrid(grid)
		if not grid then return end
		for _, card in ipairs(grid:GetChildren()) do
			if card:IsA("GuiObject") and not card:IsA("UIGridLayout") and not card:IsA("UIPadding")
				and card.Name:sub(1, #FAKE_PREFIX) ~= FAKE_PREFIX
				and card.Name ~= "NewItem"
				and not HookedRealCards[card] then
				local cont = card:FindFirstChild("Container")
				local btn = cont and cont:FindFirstChild("ActionButton")
				if btn then
					HookedRealCards[card] = true
					btn.MouseButton1Click:Connect(function()
						if not Equipped.Knife and not Equipped.Gun then return end
						local char = LocalPlayer.Character
						local prevKnife = char and char:FindFirstChild("Knife")
						local prevGun   = char and char:FindFirstChild("Gun")
						task.delay(0.15, function()
							local c = LocalPlayer.Character
							if not c then return end
							if Equipped.Knife then
								local nowKnife = c:FindFirstChild("Knife")
								if nowKnife and nowKnife ~= prevKnife then
									resetVisuals("Knife")
								end
							end
							if Equipped.Gun then
								local nowGun = c:FindFirstChild("Gun")
								if nowGun and nowGun ~= prevGun then
									resetVisuals("Gun")
								end
							end
						end)
					end)
				end
			end
		end
	end
	for _, tabFrame in ipairs(tabs:GetChildren()) do
		if tabFrame:IsA("Frame") or tabFrame:IsA("ScrollingFrame") then
			if tabFrame.Name == "Holiday" then
				local cont = tabFrame:FindFirstChild("Container")
				if cont then
					for _, section in ipairs(cont:GetChildren()) do
						if section:IsA("Frame") then
							local secCont = section:FindFirstChild("Container")
							if secCont then checkGrid(secCont) end
						end
					end
				end
			else
				local cont = tabFrame:FindFirstChild("Container")
				if cont then checkGrid(cont) end
			end
		end
	end
end

task.spawn(function()
	while spawnerGui.Parent do
		task.wait(0.25)
		pcall(function()
			local char = LocalPlayer.Character
			for _, slot in ipairs({"Knife", "Gun"}) do
				local e = Equipped[slot]
				if e then
					local heldTool = char and char:FindFirstChild(slot)
					local drawn = (heldTool ~= nil) and heldTool:IsA("Tool")

					-- displays: original stays hidden, overlay mirrors drawn state
					local target = myDisplay(slot .. "Display")
					local made = target and OverlayRoot[target]
					if target and made then
						hideOriginal(target)
						setOverlayDrawn(made, drawn)
					end

					-- tools: self-heal overlay, re-hide real weapon, keep icon
					for _, cont in ipairs({char, LocalPlayer:FindFirstChild("Backpack")}) do
						local t = cont and cont:FindFirstChild(slot)
						if t and t:IsA("Tool") then
							if e.Image ~= "" and t.TextureId ~= e.Image then
								if SavedToolTx[t] == nil then SavedToolTx[t] = t.TextureId end
								pcall(function() t.TextureId = e.Image end)
							end
							local handle = t:FindFirstChild("Handle")
							if handle and not Building[handle] then
								local ov = OverlayRoot[handle]
								if not (ov and ov[1] and ov[1].Parent) then
									applyToTool(t) -- game wiped it (throw etc.)
								else
									hideOriginal(handle)
									for _, p in ipairs(t:GetDescendants()) do
										if p:IsA("BasePart") and p ~= handle and not isOverlayPiece(p) then
											hideOriginal(p)
										end
									end
								end
							end
						end
					end

					patchHotbarSlot(slot, e)
				end
			end
			updateHoldAnim()
			-- keep inventory cards alive: the game rebuilds the grid on
			-- death/new match which wipes our injected cards — put every
			-- card back (cheap no-op when it already exists) with its xN
			for e2 in pairs(InjectedEntries) do
				injectIntoInventoryGrid(e2)
				updateCardAmount(e2)
			end
			-- hook real inventory cards so clicking them resets the spawner skin
			hookRealCards()
			-- the equipped-slot panel gets reset by the game too
			for _, slot in ipairs({"Knife", "Gun"}) do
				if Equipped[slot] then updateEquippedSlot(Equipped[slot]) end
			end
		end)
	end
end)

--==================================================================--
--  Woloko (ported from Kryzon trade engine)
--  Lets you view your items inside the game's real TradeGUI, populate
--  your offer + the other player's offer, and run the accept flow.
--  Entirely guarded: on any game that lacks the modded trade modules
--  it disables itself and the spawner keeps working.
--==================================================================--
local TradeCleanup
do
	local function set_identity(id)
		pcall(function()
			if setthreadidentity then setthreadidentity(id)
			elseif setidentity then setidentity(id)
			elseif setthreadcontext then setthreadcontext(id)
			end
		end)
	end

	-- Require the modded-game trade modules. If ANY are missing this is
	-- not the modded game, so we bail out and leave the spawner intact.
	local ProfileData, InventoryModule, ItemModule, TSync, ItemPopupService
	local TradeRemotes, TradeGUI
	local ok = pcall(function()
		set_identity(2)
		ProfileData       = require(RS.Modules.ProfileData)
		InventoryModule   = require(RS.Modules.InventoryModule)
		ItemModule        = require(RS.Modules.ItemModule)
		TSync             = require(RS.Database.Sync)
		ItemPopupService  = require(RS.ClientServices.ItemPopupService)
		set_identity(8)
		TradeRemotes = RS:FindFirstChild("Trade")
		TradeGUI     = LocalPlayer.PlayerGui:FindFirstChild("TradeGUI")
	end)
	set_identity(8)

	if not (ok and ProfileData and InventoryModule and ItemModule and TSync and TradeRemotes and TradeGUI
		and TradeGUI:FindFirstChild("Container")) then
		warn("[Woloko Trade] modded trade modules not found in this game — trade disabled.")
	else
	-- real spawns are available here → the engine skips its fake card
	RealSpawnSupported = true
	local TheirOffer = TradeGUI.Container.Trade.TheirOffer
	local YourOffer  = TradeGUI.Container.Trade.YourOffer

	local SearchTextSignal, TradeInventory
	local functions = {}
	local Config = {in_trade = false}

	local function CheckForItem(ItemName, Type)
		local Owned = ProfileData[Type] and ProfileData[Type].Owned
		if not Owned then return false end
		for Index, Value in pairs(Owned) do
			if Index == ItemName then return true, Value end
			if Value == ItemName then return true, 1 end
		end
		return false
	end

	local v18 = {}
	local function clearOfferFrames(v19)
		for _, v21 in pairs(v19:GetChildren()) do
			if v21:IsA("Frame") then
				v21.Visible = false
				if v18[v21] then v18[v21]:Disconnect() v18[v21] = nil end
			end
		end
	end

	local TradeTable = {
		LastOffer = os.time(), Locked = false,
		Player1 = {Player = LocalPlayer, Accepted = false, Offer = {}},
		Player2 = {Player = "", Accepted = false, Offer = {}},
	}

	-- expose a real ProfileData spawn to the spawner cards, so weapons
	-- you spawn become genuine inventory entries visible in the trade.
	-- Tries the weapon id first, then a couple of common key variants.
	realSpawnItem = function(e)
		pcall(function()
			local w = ProfileData.Weapons
			if not w then return end
			w.Owned = w.Owned or {}
			local owned = w.Owned
			local key = e.Id
			-- if the id isn't a known weapon in this game's DB, fall back
			-- to the display name (some modded DBs key by name)
			if not (TSync.Weapons and TSync.Weapons[key]) then
				if TSync.Weapons and TSync.Weapons[e.DisplayName] then
					key = e.DisplayName
				end
			end
			owned[key] = (owned[key] or 0) + 1
			pcall(function() RS.Remotes.Inventory.InventoryDataChanged:Fire() end)
		end)
	end

	local function GiveItem(ItemName, Amount, ItemType)
		pcall(function()
			local Owned = ProfileData[ItemType].Owned
			Owned[ItemName] = (Owned[ItemName] or 0) + Amount
			pcall(function() ItemPopupService.ItemReceived:Fire(ItemName, ItemType) end)
			RS.Remotes.Inventory.InventoryDataChanged:Fire()
		end)
	end

	local function RemoveItem(ItemName, Amount, ItemType)
		pcall(function()
			local owned = ProfileData[ItemType].Owned[ItemName]
			if not owned then return end
			if owned - Amount > 0 then
				ProfileData[ItemType].Owned[ItemName] = owned - Amount
			else
				ProfileData[ItemType].Owned[ItemName] = nil
			end
			RS.Remotes.Inventory.InventoryDataChanged:Fire()
		end)
	end

	local function AcceptTrade()
		if not TradeTable then return end
		-- Your confirm is enough to "give": the partner's real accept never
		-- reaches our local table, so gating on Player2.Accepted meant items
		-- were never removed. When YOU accept, remove the items you offered
		-- (they leave your inventory) — that's the give-and-disappear.
		if TradeTable.Player1.Accepted and not TradeTable.Locked then
			TradeTable.Locked = true
			task.wait(0.2)
			for _, item in pairs(TradeTable.Player1.Offer) do
				pcall(RemoveItem, item[1], item[2], item[3])
			end
			-- credit any items placed on their side locally (client-side sim)
			for _, item in pairs(TradeTable.Player2.Offer) do
				pcall(GiveItem, item[1], item[2], item[3])
			end
			pcall(function() TradeGUI.Enabled = false end)
			local partner = TradeTable.Player2.Player
			TradeTable = {
				LastOffer = os.time(), Locked = false,
				Player1 = {Player = LocalPlayer, Accepted = false, Offer = {}},
				Player2 = {Player = partner, Accepted = false, Offer = {}},
			}
			Config.in_trade = false
		end
	end

	local function OfferItemLocalPlayer(ItemName, ItemType)
		if not TradeTable or TradeTable.Locked then return end
		local AlreadyOffered = 0
		for _, Item in pairs(TradeTable.Player1.Offer) do
			if Item[1] == ItemName and Item[3] == ItemType then AlreadyOffered = Item[2] end
		end
		local HasItem, Amount = CheckForItem(ItemName, ItemType)
		if HasItem and Amount - AlreadyOffered > 0 then
			if AlreadyOffered == 0 then
				if #TradeTable.Player1.Offer < 4 then
					table.insert(TradeTable.Player1.Offer, {ItemName, 1, ItemType})
				end
			else
				for i, Item in pairs(TradeTable.Player1.Offer) do
					if Item[1] == ItemName then TradeTable.Player1.Offer[i][2] += 1 break end
				end
			end
		end
		TradeTable.LastOffer = os.time()
		TradeTable.Player1.Accepted, TradeTable.Player2.Accepted = false, false
		pcall(function() functions.UpdateTrade() end)
	end

	local function RemoveItemLocalPlayer(ItemName, ItemType)
		if not TradeTable or TradeTable.Locked or TradeTable.Player1.Accepted then return end
		TradeTable.LastOffer = os.time()
		TradeTable.Player1.Accepted, TradeTable.Player2.Accepted = false, false
		for i, Item in pairs(TradeTable.Player1.Offer) do
			if Item[1] == ItemName and Item[3] == ItemType then
				TradeTable.Player1.Offer[i][2] -= 1
				if TradeTable.Player1.Offer[i][2] <= 0 then table.remove(TradeTable.Player1.Offer, i) end
				break
			end
		end
		pcall(function() functions.UpdateTrade() end)
	end

	local function OfferItemAnotherPlayer(ItemName, ItemType)
		if not ItemName or ItemName == "" or not TradeTable or TradeTable.Locked then return false end
		if #TradeTable.Player2.Offer >= 4 then
			local found = false
			for _, Item in pairs(TradeTable.Player2.Offer) do
				if Item[1] == ItemName and Item[3] == ItemType then found = true break end
			end
			if not found then return false end
		end
		local AlreadyOffered = 0
		for _, Item in pairs(TradeTable.Player2.Offer) do
			if Item[1] == ItemName and Item[3] == ItemType then AlreadyOffered = Item[2] end
		end
		if AlreadyOffered == 0 then
			table.insert(TradeTable.Player2.Offer, {ItemName, 1, ItemType})
		else
			for i, Item in pairs(TradeTable.Player2.Offer) do
				if Item[1] == ItemName and Item[3] == ItemType then TradeTable.Player2.Offer[i][2] += 1 break end
			end
		end
		TradeTable.LastOffer = os.time()
		TradeTable.Player1.Accepted, TradeTable.Player2.Accepted = false, false
		pcall(function() functions.UpdateTrade() end)
		return true
	end

	local function RemoveItemAnotherPlayer()
		if not TradeTable or not TradeTable.Player2 or not TradeTable.Player2.Offer then return end
		if #TradeTable.Player2.Offer > 0 then
			if TradeTable.Player2.Accepted then return end
			local last = #TradeTable.Player2.Offer
			TradeTable.Player2.Offer[last][2] -= 1
			if TradeTable.Player2.Offer[last][2] <= 0 then table.remove(TradeTable.Player2.Offer, last) end
			TradeTable.LastOffer = os.time()
			TradeTable.Player1.Accepted, TradeTable.Player2.Accepted = false, false
			pcall(function() functions.UpdateTrade() end)
		end
	end

	local function renderOffer(container, offer)
		for slot, entry in ipairs(offer) do
			local ItemID, Amount, ItemType = entry[1], entry[2], entry[3]
			local frame = container.Container:FindFirstChild("NewItem" .. slot)
			if frame then
				pcall(function()
					if TSync[ItemType] and TSync[ItemType][ItemID] then
						local data = {}
						for k, v in pairs(TSync[ItemType][ItemID]) do data[k] = v end
						data.DataType, data.Amount, data.ItemName, data.Name = ItemType, Amount, ItemID, ItemID
						ItemModule.DisplayItem(frame, data)
					end
				end)
				pcall(function()
					if v18[frame] then v18[frame]:Disconnect() end
					if frame.Container and frame.Container:FindFirstChild("ActionButton") then
						v18[frame] = frame.Container.ActionButton.MouseButton1Click:Connect(function()
							RemoveItemLocalPlayer(ItemID, ItemType)
						end)
					end
				end)
				frame.Visible = true
			end
		end
	end

	local cooldown, cooling = 6, false
	local function ResetCooldown(reset)
		local accept = TradeGUI.Container.Trade.Actions.Accept
		if reset then
			accept.Cooldown.Visible = false cooldown, cooling = 0, false return
		end
		accept.Cooldown.Visible = true
		cooldown = 6
		accept.Cooldown.Title.Text = " Please wait (" .. cooldown .. ") before accepting."
		if not cooling then
			cooling = true
			repeat
				task.wait(1)
				cooldown -= 1
				accept.Cooldown.Title.Text = " Please wait (" .. cooldown .. ") before accepting."
			until cooldown <= 0
			cooling = false
			accept.Cooldown.Visible = false
		else
			cooldown = 6
		end
	end

	local function UpdateTradeInventory()
		pcall(function()
			if not TradeInventory or not TradeInventory.Data then return end
			local offer = TradeTable.Player1.Offer
			for typeName, byType in pairs(TradeInventory.Data) do
				for _, group in pairs(byType) do
					for itemId, node in pairs(group) do
						local frame, amount = node.Frame, node.Amount
						for _, o in pairs(offer) do
							if (o[1] == itemId) and (o[3] == typeName) then amount -= o[2] end
						end
						if amount == 1 then
							frame.Container.Amount.Text = "" frame.Visible = true
						elseif amount > 1 then
							frame.Container.Amount.Text = "x" .. amount frame.Visible = true
						else
							frame.Visible = false
						end
					end
				end
			end
		end)
	end

	local acceptState = "Accept"
	functions.UpdateTrade = function()
		pcall(function()
			-- Only manage YOUR side. THEIR offer is rendered by the game's
			-- native trade; clearing/re-rendering it from our (empty) local
			-- list is what made the other player's added items vanish.
			clearOfferFrames(YourOffer.Container)
			renderOffer(YourOffer, TradeTable.Player1.Offer)
			acceptState = "Accept"
			local A = TradeGUI.Container.Trade.Actions.Accept
			A.Confirm.Visible = false
			A.Cancel.Visible = false
			YourOffer.Accepted.Visible = false
			local empty = (#TradeTable.Player1.Offer < 1)
			A.AddItem.Visible = empty
			UpdateTradeInventory()
			ResetCooldown(empty)
		end)
	end

	local Connections2 = {}
	local function UnConnections()
		for _, c in pairs(Connections2) do pcall(function() c:Disconnect() end) end
		Connections2 = {}
	end

	local function DeclineTrade()
		pcall(function() TradeGUI.Enabled = false end)
		local partner = TradeTable and TradeTable.Player2 and TradeTable.Player2.Player or ""
		TradeTable = {
			LastOffer = os.time(), Locked = false,
			Player1 = {Player = LocalPlayer, Accepted = false, Offer = {}},
			Player2 = {Player = partner, Accepted = false, Offer = {}},
		}
		Config.in_trade = false
		UnConnections()
	end

	local confirmTime = time()
	local function SetupConnections(inv)
		pcall(function()
			if inv and inv.Data then
				for typeName, byType in pairs(inv.Data) do
					for _, group in pairs(byType) do
						for itemId, node in pairs(group) do
							if node.Frame then
								Connections2[#Connections2+1] = node.Frame.Container.ActionButton.MouseButton1Click:Connect(function()
									OfferItemLocalPlayer(itemId, typeName)
								end)
							end
						end
					end
				end
			end
		end)
		local A = TradeGUI.Container.Trade.Actions.Accept
		pcall(function()
			Connections2[#Connections2+1] = A.ActionButton.MouseButton1Click:Connect(function()
				if cooldown <= 0 and acceptState == "Accept" then
					acceptState = "Confirm" confirmTime = time() A.Confirm.Visible = true
				end
			end)
		end)
		pcall(function()
			Connections2[#Connections2+1] = A.Confirm.ActionButton.MouseButton1Click:Connect(function()
				if cooldown <= 0 and time() - confirmTime >= 0.4 and acceptState == "Confirm" then
					acceptState = "Waiting"
					YourOffer.Accepted.Visible = true
					A.Cancel.Visible = true
					TradeTable.Player1.Accepted = true
					AcceptTrade()
				end
			end)
		end)
		pcall(function()
			Connections2[#Connections2+1] = A.Cancel.ActionButton.MouseButton1Click:Connect(function()
				TradeTable.LastOffer = os.time()
				TradeTable.Player1.Accepted, TradeTable.Player2.Accepted = false, false
				pcall(function() functions.UpdateTrade() end)
			end)
		end)
		pcall(function()
			Connections2[#Connections2+1] = TradeGUI.Container.Trade.Actions.Decline.ActionButton.MouseButton1Click:Connect(function()
				DeclineTrade()
			end)
		end)
	end

	local function StartTrade()
		if Config.in_trade then return end
		Config.in_trade = true
		pcall(function()
			for _, cat in pairs({"Weapons", "Pets"}) do
				for slot in pairs(InventoryModule.CreateBlankTradeInventoryTable()[cat]) do
					TradeGUI.Container.Items.Main:FindFirstChild(cat).Items.Container:FindFirstChild(slot).Container:ClearAllChildren()
				end
			end
		end)
		pcall(function() TradeInventory = InventoryModule.GenerateInventory(TradeGUI.Container.Items, ProfileData, "Trading") end)
		UnConnections()
		pcall(function() if TradeInventory then SetupConnections(TradeInventory) end end)
		pcall(function() functions.UpdateTrade() end)
		pcall(function() TheirOffer.Username.Text = "(" .. tostring(TradeTable.Player2.Player) .. ")" end)
		TradeGUI.Enabled = true
		pcall(function()
			if SearchTextSignal then SearchTextSignal:Disconnect() end
			local SearchText = TradeGUI.Container.Items.Tabs.Search.Container.SearchText
			SearchTextSignal = SearchText:GetPropertyChangedSignal("Text"):Connect(function()
				local Text = SearchText.Text
				for _, byType in pairs(TradeInventory.Data) do
					for _, node in pairs(byType.Current) do
						node.Frame.Visible = string.find(string.lower(node.Name), string.lower(Text)) ~= nil
					end
				end
			end)
		end)
	end

	-- A trade opened (either player initiated). Take it over client-side so
	-- your spawned items can be clicked into YOUR OFFER — StartTrade rebuilds
	-- the inventory WITH our click hooks (SetupConnections). Without this the
	-- items show but clicking them does nothing, since the hooks never ran.
	pcall(function()
		if TradeRemotes:FindFirstChild("StartTrade") then
			track(TradeRemotes.StartTrade.OnClientEvent:Connect(function(a, b)
				local partner = a
				if typeof(partner) == "Instance" and partner:IsA("Player") then
					partner = partner.Name
				elseif type(partner) ~= "string" then
					partner = (type(b) == "string" and b) or ""
				end
				Config.in_trade = false -- allow StartTrade to (re)run
				if partner ~= "" then TradeTable.Player2.Player = partner end
				task.wait(0.15) -- let the native trade GUI populate first
				pcall(StartTrade)
			end))
		end
	end)

	----------------------------------------------------------------
	-- Trade panel UI (black theme, matches the spawner)
	----------------------------------------------------------------
	local tradeFrame = mk("Frame", {
		Name = "WolokoTrade",
		Size = UDim2.new(0, 260, 0, 322),
		Position = UDim2.new(0.5, 250, 0.5, -161),
		BackgroundColor3 = THEME.Bg,
		BorderSizePixel = 0,
		Visible = false,
		Active = true,
	}, spawnerGui)
	corner(tradeFrame, 14)
	stroke(tradeFrame, THEME.Stroke, 1, 0.2)

	local tHeader = mk("Frame", {
		Size = UDim2.new(1, 0, 0, 40), BackgroundColor3 = THEME.Panel, BorderSizePixel = 0,
	}, tradeFrame)
	corner(tHeader, 14)
	mk("Frame", {Size = UDim2.new(1, 0, 0, 14), Position = UDim2.new(0, 0, 1, -14), BackgroundColor3 = THEME.Panel, BorderSizePixel = 0}, tHeader)
	mk("TextLabel", {
		Size = UDim2.new(1, -50, 1, 0), Position = UDim2.new(0, 14, 0, 0), BackgroundTransparency = 1,
		Text = "Trade", TextColor3 = THEME.Text, TextSize = 16, Font = Enum.Font.GothamBold,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, tHeader)
	local tClose = mk("TextButton", {
		Size = UDim2.new(0, 26, 0, 26), Position = UDim2.new(1, -34, 0, 7), BackgroundColor3 = THEME.Panel2,
		Text = "×", TextColor3 = THEME.TextDim, TextSize = 18, Font = Enum.Font.GothamBold, AutoButtonColor = false,
	}, tHeader)
	corner(tClose, 8)

	do -- drag
		local dragging, dragStart, startPos
		tHeader.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging, dragStart, startPos = true, input.Position, tradeFrame.Position
			end
		end)
		track(UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then dragging = false end
		end))
		track(UserInputService.InputChanged:Connect(function(input)
			if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
				local d = input.Position - dragStart
				tradeFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
			end
		end))
	end

	local body = mk("Frame", {
		Size = UDim2.new(1, -20, 1, -50), Position = UDim2.new(0, 10, 0, 46), BackgroundTransparency = 1,
	}, tradeFrame)
	mk("UIListLayout", {Padding = UDim.new(0, 7), SortOrder = Enum.SortOrder.LayoutOrder}, body)

	local function label(txt, order)
		return mk("TextLabel", {
			Size = UDim2.new(1, 0, 0, 14), BackgroundTransparency = 1, Text = txt,
			TextColor3 = THEME.TextDim, TextSize = 12, Font = Enum.Font.GothamMedium,
			TextXAlignment = Enum.TextXAlignment.Left, LayoutOrder = order,
		}, body)
	end
	local function field(placeholder, order)
		local holder = mk("Frame", {Size = UDim2.new(1, 0, 0, 30), BackgroundColor3 = THEME.Panel, BorderSizePixel = 0, LayoutOrder = order}, body)
		corner(holder, 8)
		stroke(holder, THEME.Stroke, 1, 0.4)
		local box = mk("TextBox", {
			Size = UDim2.new(1, -16, 1, 0), Position = UDim2.new(0, 8, 0, 0), BackgroundTransparency = 1,
			PlaceholderText = placeholder, Text = "", TextColor3 = THEME.Text, PlaceholderColor3 = THEME.TextDim,
			TextSize = 13, Font = Enum.Font.Gotham, TextXAlignment = Enum.TextXAlignment.Left, ClearTextOnFocus = false,
		}, holder)
		return box
	end
	local function button(txt, order, accent)
		local b = mk("TextButton", {
			Size = UDim2.new(1, 0, 0, 32), BackgroundColor3 = accent and THEME.Accent or THEME.Panel2,
			Text = txt, TextColor3 = accent and THEME.OnAccent or THEME.Text, TextSize = 13,
			Font = Enum.Font.GothamBold, AutoButtonColor = false, LayoutOrder = order,
		}, body)
		corner(b, 8)
		if not accent then stroke(b, THEME.Stroke, 1, 0.4) end
		b.MouseEnter:Connect(function() tween(b, {BackgroundColor3 = accent and THEME.Accent2 or THEME.CardHover}) end)
		b.MouseLeave:Connect(function() tween(b, {BackgroundColor3 = accent and THEME.Accent or THEME.Panel2}) end)
		return b
	end

	label("Partner username", 1)
	local partnerBox = field("Who to trade with...", 2)
	partnerBox.FocusLost:Connect(function()
		TradeTable.Player2.Player = partnerBox.Text
		pcall(function() TheirOffer.Username.Text = "(" .. tostring(partnerBox.Text) .. ")" end)
	end)

	button("Open Trade Window", 3, true).MouseButton1Click:Connect(function() StartTrade() end)

	label("Add item to their offer", 4)
	local theirBox = field("Weapon id (e.g. Gingerscope)...", 5)
	button("Add To Their Offer", 6).MouseButton1Click:Connect(function()
		if theirBox.Text ~= "" then OfferItemAnotherPlayer(theirBox.Text, "Weapons") end
	end)
	button("Remove Last (Their Offer)", 7).MouseButton1Click:Connect(function()
		RemoveItemAnotherPlayer()
	end)
	button("Accept Their Offer", 8).MouseButton1Click:Connect(function()
		if not next(TradeTable.Player1.Offer) and not next(TradeTable.Player2.Offer) then return end
		if cooling then return end
		TheirOffer.Accepted.Visible = true
		TradeTable.Player2.Accepted = true
		AcceptTrade()
	end)

	-- toggle button lives on the main header row (top-right stack)
	local tradeToggle = mk("TextButton", {
		Name = "TradeToggle",
		Size = UDim2.new(0, 44, 0, 44), Position = UDim2.new(0, 16, 0.5, 30),
		BackgroundColor3 = THEME.Panel2, Text = "⇄", TextColor3 = THEME.Text,
		TextSize = 22, Font = Enum.Font.GothamBold, AutoButtonColor = false,
	}, spawnerGui)
	corner(tradeToggle, 22)
	stroke(tradeToggle, THEME.Stroke, 1, 0.4)
	tradeToggle.MouseButton1Click:Connect(function() tradeFrame.Visible = not tradeFrame.Visible end)
	tClose.MouseButton1Click:Connect(function() tradeFrame.Visible = false end)

	TradeCleanup = function()
		pcall(UnConnections)
		if SearchTextSignal then pcall(function() SearchTextSignal:Disconnect() end) end
		pcall(function() tradeFrame:Destroy() end)
		pcall(function() tradeToggle:Destroy() end)
	end

	print("[Woloko Trade] ready — click ⇄ to open the trade panel.")
	end
end

_G.MM2SpawnerCleanup = function()
	resetVisuals()
	pcall(function()
		local weapons = LocalPlayer.PlayerGui.MainGUI.Game.Inventory.Main.Weapons
		for _, d in ipairs(weapons.Items.Container:GetDescendants()) do
			if d.Name:sub(1, 9) == "ZZVisual_" then d:Destroy() end
		end
	end)
	if TradeCleanup then pcall(TradeCleanup) end
	pcall(function() spawnerGui:Destroy() end)
	for _, c in ipairs(Connections) do pcall(function() c:Disconnect() end) end
	Connections = {}
end

--------------------------------------------------------------------
-- External spawn API (used by the Kryzon hub "Spawner" tab).
-- getgenv()/_G are shared across scripts in the same executor, so the
-- hub can drive this running engine by name. Returns ok, displayName.
--   _G.YomogiSpawnByName("harvester")   -> partial/exact, any case
--------------------------------------------------------------------
_G.WolokoSpawnByName = function(query)
	if type(query) ~= "string" or query == "" then return false, "empty" end
	local q = query:lower():gsub("^%s+", ""):gsub("%s+$", "")
	local e = Weapons[query] or Weapons[q]
	-- exact id or display-name match
	if not e then
		for _, w in ipairs(SortedList) do
			if tostring(w.Id):lower() == q or w.DisplayName:lower() == q then e = w break end
		end
	end
	-- word-based match against name + RARITY + id, so "chroma evergreen"
	-- finds an Evergreen whose rarity is Chroma (chroma isn't in the name),
	-- and "chroma evergun" likewise. Every typed word must appear somewhere.
	if not e then
		local words = {}
		for wd in q:gmatch("%S+") do words[#words + 1] = wd end
		if #words > 0 then
			for _, w in ipairs(SortedList) do
				local hay = (w.DisplayName .. " " .. tostring(w.Rarity or "") .. " " .. tostring(w.Id)):lower()
				local all = true
				for _, wd in ipairs(words) do
					if not hay:find(wd, 1, true) then all = false break end
				end
				if all then e = w break end
			end
		end
	end
	-- last resort: plain substring on the display name
	if not e then
		for _, w in ipairs(SortedList) do
			if w.DisplayName:lower():find(q, 1, true) then e = w break end
		end
	end
	if not e then return false, "not found" end
	Equipped[e.Type] = e
	pcall(updateEquippedSlot, e)
	pcall(applyToDisplay, e.Type)
	pcall(scanTools)
	if updateFooter then pcall(updateFooter) end
	if bumpSpawnCount then pcall(bumpSpawnCount, e) end
	return true, e.DisplayName
end

-- lets the hub confirm the engine is loaded
_G.WolokoSpawnerLoaded = true

-- (Removed the 20s hot-reload loop: re-decoding the JSON caches every
-- 20s forever caused recurring lag spikes. The caches are read once,
-- lazily, on the first spawn — that's enough.)

--------------------------------------------------------------------
-- Full weapon audit: builds EVERY weapon on a hidden test part and
-- prunes any that fail or fall back to a generic placeholder mesh.
-- Run from the executor: _G.YogomiScanAll()
--------------------------------------------------------------------
_G.WolokoScanAll = function()
	local genericIds = {["6600901997"] = true, ["121944778"] = true, ["6600918074"] = true, ["79401392"] = true}
	local failIds, genericList, bigList = {}, {}, {}
	local okCount = 0
	local test = Instance.new("Part")
	test.Name = "WolokoScanPart"
	test.Anchored = true
	test.CanCollide = false
	test.Transparency = 1
	test.Size = Vector3.new(1, 1, 1)
	test.CFrame = CFrame.new(0, -500, 0)
	test.Parent = workspace
	local total = #SortedList
	for i, e in ipairs(SortedList) do
		local okBuild = pcall(applyVisual, test, e)
		local made = OverlayRoot[test]
		if not okBuild or not made or #made == 0 then
			table.insert(failIds, e.Id)
		else
			local generic, big = false, false
			for _, inst in ipairs(made) do
				if inst:IsA("BasePart") then
					local s = inst.Size
					if math.max(s.X, s.Y, s.Z) > MAX_WEAPON_EXTENT then big = true end
					local mid, tex = "", ""
					if inst:IsA("MeshPart") then
						mid = inst.MeshId
						tex = inst.TextureID
					else
						local sm = inst:FindFirstChildOfClass("SpecialMesh")
						mid = sm and sm.MeshId or ""
						tex = sm and sm.TextureId or ""
					end
					local digits = tostring(mid):match("%d+")
					if digits and genericIds[digits] then
						-- the default knife/gun mesh is legitimate for the
						-- hundreds of retexture weapons — only flag it when
						-- it has NO texture at all (plain white/black)
						local hasDecal = false
						for _, dd in ipairs(inst:GetDescendants()) do
							if dd:IsA("Decal") and dd.Texture ~= "" then
								hasDecal = true
								break
							end
						end
						if tex == "" and not hasDecal then generic = true end
					end
				end
			end
			if generic then
				table.insert(genericList, e.Id)
			elseif big then
				table.insert(bigList, e.Id)
			else
				okCount += 1
			end
		end
		clearOverlay(test)
		Hidden[test] = nil
		if i % 25 == 0 then
			print(("[Woloko Scan] %d/%d..."):format(i, total))
			task.wait(0.05)
		end
	end
	test:Destroy()
	print(("[Woloko Scan] DONE ok=%d fail=%d generic=%d oversized=%d of %d")
		:format(okCount, #failIds, #genericList, #bigList, total))
	if #failIds > 0 then print("[Yogomi Scan] FAILED: " .. table.concat(failIds, ", ")) end
	if #genericList > 0 then print("[Yogomi Scan] GENERIC: " .. table.concat(genericList, ", ")) end
	if #bigList > 0 then print("[Yogomi Scan] OVERSIZED: " .. table.concat(bigList, ", ")) end
	-- prune anything broken from the spawner list
	local bad = {}
	for _, id in ipairs(failIds) do bad[id] = true end
	for _, id in ipairs(genericList) do bad[id] = true end
	if next(bad) then
		for i = #SortedList, 1, -1 do
			if bad[SortedList[i].Id] then table.remove(SortedList, i) end
		end
		renderList()
		print(("[Woloko Scan] pruned %d broken weapons; %d remain"):format(#failIds + #genericList, #SortedList))
	end
	return {ok = okCount, fail = failIds, generic = genericList, big = bigList}
end

local richCount, completeCount, rjCount, learnedCount = 0, 0, 0, 0
for _, v in pairs(RICH) do
	richCount += 1
	if v.Complete then completeCount += 1 end
end
for _ in pairs(RichJson) do rjCount += 1 end
for _ in pairs(Learned) do learnedCount += 1 end
print(("[Woloko Spawner] Loaded: %d weapons | dump models: %d (%d complete) | rich captures: %d | flat learned: %d")
	:format(#SortedList, richCount, completeCount, rjCount, learnedCount))
