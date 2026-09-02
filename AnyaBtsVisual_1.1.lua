-- Crystal Hub Visuals plugin
-- UI: odh_shared_plugins / PluginExample API

local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local Stats = game:GetService("Stats")

local LocalPlayer = Players.LocalPlayer

-- Device category used for UI and graphics quality selection.
local function getDeviceCategory()
    if UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
        return "Console"
    end
    if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
        return "Mobile"
    end
    return "Desktop"
end

local DEVICE_CATEGORY = getDeviceCategory()
local IS_PHONE = DEVICE_CATEGORY == "Mobile"

-- Base quality fallback before enough FPS samples are collected.
local function detectBaseQuality()
    local camera = workspace.CurrentCamera
    local screenSize = camera and camera.ViewportSize or Vector2.new(1920, 1080)
    local pixelCount = screenSize.X * screenSize.Y

    if DEVICE_CATEGORY == "Mobile" then
        if pixelCount < 1300000 then
            return 0.5
        else
            return 0.75
        end
    elseif DEVICE_CATEGORY == "Console" then
        return 0.85
    end
    return 1
end

local function getSavedOverride()
    local ok, value = pcall(function()
        return LocalPlayer:GetAttribute("QualityOverride")
    end)
    if ok and value then
        return value
    end
    return nil
end

local QUALITY = getSavedOverride() or detectBaseQuality()
local frameTimes = {}
local FPS_SAMPLE_SIZE = 60
local MIN_QUALITY = 0.4
local MAX_QUALITY = 1

local function adjustQualityByFps(avgFps)
    if getSavedOverride() then
        return
    end

    if avgFps < 30 then
        QUALITY = math.max(MIN_QUALITY, QUALITY - 0.1)
    elseif avgFps > 55 then
        QUALITY = math.min(MAX_QUALITY, QUALITY + 0.05)
    end
end

RunService.Heartbeat:Connect(function(dt)
    if dt <= 0 then return end
    table.insert(frameTimes, dt)
    if #frameTimes >= FPS_SAMPLE_SIZE then
        local sum = 0
        for _, t in ipairs(frameTimes) do
            sum += t
        end
        adjustQualityByFps(1 / (sum / #frameTimes))
        table.clear(frameTimes)
    end
end)

local function quantity(count, minimum)
    return math.max(minimum or 1, math.floor(count * QUALITY + 0.5))
end

local function setQualityOverride(value)
    QUALITY = value
    pcall(function()
        LocalPlayer:SetAttribute("QualityOverride", value)
    end)
end

--======================================================================--
--======================================================================--
local Visuals = {}

Visuals.Settings = {
	Jump = {
		Enabled  = false,
		Style    = "Swirl",
		Color    = Color3.fromRGB(120, 190, 255),
		Size     = 7,
		Duration = 0.7,
		Flash    = true,
		Sparks   = true,
	},
	Wings = {
		Enabled = false,
		Style   = "Angel",
		Color   = Color3.fromRGB(150, 200, 255),
		Scale   = 1,
		Droop   = 0,
		Flap    = true,
		Glow    = true,
	},
	Halo = {
		Enabled = false,
		Style   = "Ring",
		Color   = Color3.fromRGB(255, 225, 130),
		Speed   = 1,
		Glow    = true,
	},
	ChinaHat = {
		Enabled = false,
		Style   = "Layered",
		Color   = Color3.fromRGB(255, 120, 90),
		Size    = 1,
		Spin    = 0.6,
		Glow    = true,
	},
}

local vis = Visuals.Settings

local effectsFolder
local character, humanoid, torso, headPart
local wingsFolder, haloFolder, hatFolder
local wingParts, haloParts, hatParts = {}, {}, {}
local jumpConnection, animConnection, characterConnection
local animClock      = 0
local flapAccum      = 0
local flapReset      = false
local lastJumpEffect = 0
local rebuildPending = { Wings = false, Halo = false, Hat = false }

local function ensureFolder()
	if effectsFolder and effectsFolder.Parent then
		return effectsFolder
	end
	effectsFolder = Instance.new("Folder")
	effectsFolder.Name   = "CrystalHub_Effects"
	effectsFolder.Parent = workspace
	return effectsFolder
end

ensureFolder()

local function newNeonPart(size, color, className)
	local part = Instance.new(className or "Part")
	part.Size       = size
	part.Color      = color
	part.Material   = Enum.Material.Neon
	part.Anchored   = false
	part.CanCollide = false
	part.CanQuery   = false
	part.CanTouch   = false
	part.CastShadow = false
	part.Massless   = true
	part.Locked     = true
	part.TopSurface    = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

local function weldTo(basePart, part, c0)
	local weld = Instance.new("Weld")
	weld.Part0  = basePart
	weld.Part1  = part
	weld.C0     = c0
	weld.Parent = part
	return weld
end

local function lighten(color, amount)
	return Color3.new(
		math.min(color.R + amount, 1),
		math.min(color.G + amount, 1),
		math.min(color.B + amount, 1))
end

--======================================================================--
--======================================================================--

local function spawnFlash(position, diameter, color, duration)
	local flash = Instance.new("Part")
	flash.Shape        = Enum.PartType.Cylinder
	flash.Size         = Vector3.new(0.08, diameter * 0.45, diameter * 0.45)
	flash.CFrame       = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
	flash.Anchored     = true
	flash.CanCollide   = false
	flash.CanQuery     = false
	flash.CanTouch     = false
	flash.CastShadow   = false
	flash.Material     = Enum.Material.Neon
	flash.Color        = lighten(color, 0.45)
	flash.Transparency = 0.25
	flash.Parent       = ensureFolder()
	TweenService:Create(flash,
		TweenInfo.new(duration * 0.55, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
		{ Size = Vector3.new(0.02, diameter * 1.5, diameter * 1.5), Transparency = 1 }
	):Play()
	task.delay(duration + 0.1, function()
		flash:Destroy()
	end)
end

local function spawnDisc(position, diameter, thickness, color, duration, expand)
	local disc = Instance.new("Part")
	disc.Shape        = Enum.PartType.Cylinder
	disc.Size         = Vector3.new(thickness, diameter, diameter)
	disc.CFrame       = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
	disc.Anchored     = true
	disc.CanCollide   = false
	disc.CanQuery     = false
	disc.CanTouch     = false
	disc.CastShadow   = false
	disc.Material     = Enum.Material.Neon
	disc.Color        = color
	disc.Transparency = 0.15
	disc.Parent       = ensureFolder()
	TweenService:Create(disc,
		TweenInfo.new(duration, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
		{ Size = Vector3.new(thickness * 0.4, diameter * expand, diameter * expand), Transparency = 1 }
	):Play()
	task.delay(duration + 0.15, function()
		disc:Destroy()
	end)
end

local function spawnArcRing(origin, opts)
	local segments   = quantity(opts.Segments or 26, 8)
	local sweep      = opts.Sweep     or (math.pi * 2)
	local startAngle = opts.Start     or 0
	local radius0    = opts.Radius0   or 1.2
	local radius1    = opts.Radius1   or 8
	local thickness  = opts.Thickness or 0.22
	local duration   = opts.Duration  or 0.7
	local spin       = opts.Spin      or 0
	local tilt       = opts.Tilt      or 0
	local fade       = opts.Fade      or 0
	local rise       = opts.Rise      or 0
	local color      = opts.Color     or Color3.fromRGB(255, 255, 255)
	local tipColor   = lighten(color, 0.5)

	local overlap = 1.08
	local chord0  = (sweep * radius0 / segments) * overlap
	local chord1  = (sweep * radius1 / segments) * overlap

	local info   = TweenInfo.new(duration, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)
	local base   = CFrame.new(origin) * CFrame.Angles(tilt, 0, 0)
	local folder = ensureFolder()
	local made   = {}

	for index = 1, segments do
		local ratio = (index - 1) / segments
		local angle = startAngle + ratio * sweep
		local piece = Instance.new("Part")
		piece.Size         = Vector3.new(thickness, thickness, chord0)
		piece.CFrame       = base * CFrame.Angles(0, angle, 0)
			* CFrame.new(0, 0, -radius0) * CFrame.Angles(0, math.rad(90), 0)
		piece.Anchored     = true
		piece.CanCollide   = false
		piece.CanQuery     = false
		piece.CanTouch     = false
		piece.CastShadow   = false
		piece.Material     = Enum.Material.Neon
		piece.Color        = color:Lerp(tipColor, ratio)
		piece.Transparency = math.clamp(fade * ratio, 0, 0.9)
		piece.Parent       = folder

		TweenService:Create(piece, info, {
			CFrame = base * CFrame.Angles(0, angle + spin, 0)
				* CFrame.new(0, rise, -radius1) * CFrame.Angles(0, math.rad(90), 0),
			Size         = Vector3.new(thickness * 0.32, thickness * 0.32, chord1),
			Transparency = 1,
		}):Play()
		table.insert(made, piece)
	end

	task.delay(duration + 0.2, function()
		for _, piece in ipairs(made) do
			piece:Destroy()
		end
	end)
end

local function spawnShard(position, angle, color, duration, height, distance)
	local shard = newNeonPart(Vector3.new(0.18, 1.1, 0.18), color)
	shard.Anchored     = true
	shard.Transparency = 0.1
	shard.CFrame       = CFrame.new(position) * CFrame.Angles(0, angle, 0) * CFrame.new(0, 0.4, -1)
	shard.Parent       = ensureFolder()
	TweenService:Create(shard,
		TweenInfo.new(duration, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
		{
			CFrame       = CFrame.new(position) * CFrame.Angles(0, angle, 0)
				* CFrame.new(0, height or 2.2, -(distance or 4.5)),
			Size         = Vector3.new(0.05, 0.3, 0.05),
			Transparency = 1,
		}
	):Play()
	task.delay(duration + 0.15, function()
		shard:Destroy()
	end)
end

local function spawnSparks(origin, color, duration, count, radius)
	if not vis.Jump.Sparks then
		return
	end
	local folder = ensureFolder()
	local total  = quantity(count or 10, 4)
	for index = 1, total do
		local angle = (index / total) * math.pi * 2 + math.random() * 0.4
		local spark = newNeonPart(Vector3.new(0.16, 0.16, 0.16), lighten(color, 0.3), "Part")
		spark.Shape        = Enum.PartType.Ball
		spark.Anchored     = true
		spark.Transparency = 0.1
		spark.CFrame       = CFrame.new(origin) * CFrame.Angles(0, angle, 0) * CFrame.new(0, 0.2, -0.6)
		spark.Parent       = folder
		local far  = (radius or 4) * (0.6 + math.random() * 0.7)
		local high = 1.4 + math.random() * 2.2
		TweenService:Create(spark,
			TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{
				CFrame       = CFrame.new(origin) * CFrame.Angles(0, angle, 0) * CFrame.new(0, high, -far),
				Size         = Vector3.new(0.03, 0.03, 0.03),
				Transparency = 1,
			}
		):Play()
		task.delay(duration + 0.15, function()
			spark:Destroy()
		end)
	end
end

Visuals.JumpStyles = {
	"Swirl", "Ring", "Vortex", "Triple", "Nova",
	"Ripple", "Comet", "Shockwave", "Petals",
}

local function playJumpEffect()
	if not vis.Jump.Enabled or not torso then
		return
	end
	local now = os.clock()
	if now - lastJumpEffect < 0.15 then
		return
	end
	lastJumpEffect = now

	local folder = ensureFolder()
	if #folder:GetChildren() > (IS_PHONE and 220 or 400) then
		return
	end

	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end

	local origin   = root.Position - Vector3.new(0, 2.55, 0)
	local color    = vis.Jump.Color
	local duration = vis.Jump.Duration
	local size     = vis.Jump.Size
	local style    = vis.Jump.Style

	if vis.Jump.Flash then
		spawnFlash(origin, size * 0.5, color, duration)
	end

	if style == "Ring" then
		spawnArcRing(origin, {
			Color = color, Duration = duration, Segments = 30,
			Radius0 = size * 0.16, Radius1 = size, Thickness = size * 0.035,
			Fade = 0.15, Rise = 0.25,
		})
		spawnSparks(origin, color, duration, 8, size * 0.5)
	elseif style == "Vortex" then
		for layer = 1, 3 do
			task.delay((layer - 1) * 0.07, function()
				spawnArcRing(origin, {
					Color     = color,
					Duration  = duration,
					Segments  = 22,
					Sweep     = math.rad(300),
					Start     = layer * 2.1,
					Radius0   = size * (0.12 + layer * 0.05),
					Radius1   = size * (0.75 + layer * 0.2),
					Thickness = size * (0.045 - layer * 0.008),
					Spin      = (layer % 2 == 0) and -0.9 or 0.9,
					Tilt      = math.rad(layer * 4),
					Rise      = 0.35 * layer,
					Fade      = 0.75,
				})
			end)
		end
	elseif style == "Triple" then
		for index = 1, 3 do
			task.delay((index - 1) * 0.11, function()
				spawnArcRing(origin, {
					Color = color, Duration = duration, Segments = 24,
					Radius0 = size * 0.14, Radius1 = size * (0.6 + index * 0.22),
					Thickness = size * 0.03, Fade = 0.2, Rise = 0.15 * index,
				})
			end)
		end
	elseif style == "Nova" then
		spawnArcRing(origin, {
			Color = color, Duration = duration, Segments = 28,
			Radius0 = size * 0.15, Radius1 = size * 0.95, Thickness = size * 0.04, Fade = 0.1,
		})
		for index = 1, quantity(8, 4) do
			spawnShard(origin, (index / 8) * math.pi * 2, color, duration * 0.9)
		end
		spawnSparks(origin, color, duration, 12, size * 0.6)
	elseif style == "Ripple" then
		for index = 1, 3 do
			task.delay((index - 1) * 0.13, function()
				spawnDisc(origin, size * (0.4 + index * 0.1), 0.14, color, duration, 2.1)
			end)
		end
	elseif style == "Comet" then
		spawnArcRing(origin, {
			Color     = color,
			Duration  = duration * 1.1,
			Segments  = 24,
			Sweep     = math.rad(150),
			Start     = math.random() * math.pi * 2,
			Radius0   = size * 0.12,
			Radius1   = size * 1.15,
			Thickness = size * 0.05,
			Spin      = 1.6,
			Tilt      = math.rad(8),
			Rise      = 0.8,
			Fade      = 0.95,
		})
		spawnSparks(origin, color, duration, 8, size * 0.4)
	elseif style == "Shockwave" then
		spawnDisc(origin, size * 0.5, 0.18, color, duration, 2.6)
		spawnArcRing(origin, {
			Color = color, Duration = duration * 0.9, Segments = 34,
			Radius0 = size * 0.3, Radius1 = size * 1.3, Thickness = size * 0.025, Fade = 0.05,
		})
	elseif style == "Petals" then
		for index = 1, quantity(6, 3) do
			spawnArcRing(origin, {
				Color     = color,
				Duration  = duration,
				Segments  = 10,
				Sweep     = math.rad(52),
				Start     = (index / 6) * math.pi * 2,
				Radius0   = size * 0.2,
				Radius1   = size * 0.9,
				Thickness = size * 0.05,
				Tilt      = math.rad(14),
				Rise      = 0.5,
				Fade      = 0.5,
			})
		end
	else
		spawnArcRing(origin, {
			Color     = color,
			Duration  = duration,
			Segments  = 28,
			Sweep     = math.rad(310),
			Start     = 0,
			Radius0   = size * 0.15,
			Radius1   = size,
			Thickness = size * 0.045,
			Spin      = 0.7,
			Rise      = 0.4,
			Fade      = 0.85,
		})
		spawnArcRing(origin, {
			Color     = color,
			Duration  = duration * 1.15,
			Segments  = 22,
			Sweep     = math.rad(265),
			Start     = math.pi,
			Radius0   = size * 0.1,
			Radius1   = size * 0.78,
			Thickness = size * 0.03,
			Spin      = -0.5,
			Tilt      = math.rad(6),
			Rise      = 0.2,
			Fade      = 0.7,
		})
		spawnSparks(origin, color, duration, 6, size * 0.45)
	end
end

--======================================================================--
--======================================================================--

local function clearWings()
	if wingsFolder then
		wingsFolder:Destroy()
	end
	wingsFolder = nil
	wingParts   = {}
	if torso then
		for _, child in ipairs(torso:GetChildren()) do
			if child.Name == "CrystalHub_WingGlow" then
				child:Destroy()
			end
		end
	end
end

local function addTrail(part, color, lifetime, width)
	local front = Instance.new("Attachment")
	front.Position = Vector3.new(0, part.Size.Y * 0.5, -part.Size.Z * 0.5)
	front.Parent   = part

	local back = Instance.new("Attachment")
	back.Position = Vector3.new(0, part.Size.Y * 0.5, part.Size.Z * 0.5)
	back.Parent   = part

	local trail = Instance.new("Trail")
	trail.Attachment0    = front
	trail.Attachment1    = back
	trail.Color          = ColorSequence.new(color)
	trail.Transparency   = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.Lifetime       = lifetime or 0.35
	trail.WidthScale     = NumberSequence.new({
		NumberSequenceKeypoint.new(0, width or 1),
		NumberSequenceKeypoint.new(1, 0),
	})
	trail.LightEmission  = 1
	trail.LightInfluence = 0
	trail.FaceCamera     = true
	trail.Parent         = part
	return trail
end

local function addFeather(side, opts)
	local feather = newNeonPart(Vector3.new(opts.Thickness, opts.Length, opts.Width), opts.Color)
	feather.Transparency = opts.Transparency or 0.1
	feather.Parent       = wingsFolder

	local spread = opts.Spread + math.rad(vis.Wings.Droop or 0)
	local origin = CFrame.new(side * opts.OriginX, opts.OriginY, opts.OriginZ)
		* CFrame.Angles(opts.Pitch or 0, side * opts.Sweep, -side * spread)
	local offset = CFrame.new(0, opts.Length * 0.5, 0)

	table.insert(wingParts, {
		Weld   = weldTo(torso, feather, origin * offset),
		Origin = origin,
		Offset = offset,
		Phase  = opts.Phase or 0,
		Amp    = opts.Amp or 0.12,
	})

	if opts.Tip then
		local tipLength = opts.Length * 0.32
		local tip = newNeonPart(
			Vector3.new(opts.Thickness, opts.Width * 0.95, tipLength),
			opts.TipColor or opts.Color, "WedgePart")
		tip.Transparency = math.clamp((opts.Transparency or 0.1) + 0.12, 0, 0.95)
		tip.Parent       = wingsFolder
		local tipOffset = CFrame.new(0, opts.Length + tipLength * 0.5, 0)
			* CFrame.Angles(math.rad(-90), 0, 0)
		table.insert(wingParts, {
			Weld   = weldTo(torso, tip, origin * tipOffset),
			Origin = origin,
			Offset = tipOffset,
			Phase  = opts.Phase or 0,
			Amp    = opts.Amp or 0.12,
		})
	end

	return feather
end

Visuals.WingStyles = { "Angel", "Demon", "Phantom", "Simple", "Crystal" }

local function buildWings()
	clearWings()
	if not vis.Wings.Enabled or not torso then
		return
	end

	wingsFolder = Instance.new("Folder")
	wingsFolder.Name   = "CrystalHub_Wings"
	wingsFolder.Parent = character

	local scale = vis.Wings.Scale
	local base  = vis.Wings.Color
	local light = lighten(base, 0.4)
	local style = vis.Wings.Style

	for _, side in ipairs({ -1, 1 }) do
		if style == "Demon" then
			local bones = quantity(5, 4)
			for index = 1, bones do
				local ratio  = (index - 1) / (bones - 1)
				local length = (4.3 - ratio * 1.6) * scale
				local spread = math.rad(58 + ratio * 62)
				addFeather(side, {
					Length = length, Width = 0.16 * scale, Thickness = 0.15 * scale,
					Spread = spread, Sweep = math.rad(30), Pitch = math.rad(-10 - ratio * 8),
					OriginX = 0.5 * scale, OriginY = 0.15 * scale, OriginZ = 0.68 * scale,
					Color = base:Lerp(light, ratio * 0.5), Transparency = 0.05,
					Phase = index * 0.3, Amp = 0.08 + ratio * 0.1, Tip = true,
					TipColor = light,
				})
				if index < bones then
					local nextRatio = index / (bones - 1)
					addFeather(side, {
						Length = length * 0.82, Width = (1.2 - ratio * 0.25) * scale,
						Thickness = 0.05 * scale,
						Spread = spread + math.rad(10 + nextRatio * 5),
						Sweep = math.rad(30), Pitch = math.rad(-10 - ratio * 8),
						OriginX = 0.5 * scale, OriginY = 0.15 * scale, OriginZ = 0.66 * scale,
						Color = base, Transparency = 0.6,
						Phase = index * 0.3 + 0.08, Amp = 0.08 + ratio * 0.1,
					})
				end
			end
		elseif style == "Simple" then
			for index = 1, quantity(4, 3) do
				local ratio  = (index - 1) / 3
				local length = (2.9 - ratio * 0.9) * scale
				addFeather(side, {
					Length = length, Width = (0.62 - ratio * 0.14) * scale, Thickness = 0.09 * scale,
					Spread = math.rad(62 + ratio * 46), Sweep = math.rad(20),
					Pitch = math.rad(-8),
					OriginX = 0.42 * scale, OriginY = 0.25 * scale, OriginZ = 0.6 * scale,
					Color = base:Lerp(light, ratio), Transparency = 0.18,
					Phase = index * 0.35, Amp = 0.1 + ratio * 0.06, Tip = true, TipColor = light,
				})
			end
		elseif style == "Phantom" then
			for index = 1, quantity(6, 4) do
				local ratio  = (index - 1) / 5
				local length = (4.8 - ratio * 2.2) * scale
				local blade = addFeather(side, {
					Length = length, Width = (0.34 - ratio * 0.1) * scale, Thickness = 0.06 * scale,
					Spread = math.rad(54 + ratio * 70), Sweep = math.rad(26),
					Pitch = math.rad(-12 - ratio * 10),
					OriginX = 0.36 * scale, OriginY = 0.3 * scale, OriginZ = 0.6 * scale,
					Color = base:Lerp(light, ratio), Transparency = 0.5 + ratio * 0.18,
					Phase = index * 0.42, Amp = 0.16 + ratio * 0.12, Tip = true, TipColor = light,
				})
				if index <= 3 then
					addTrail(blade, base:Lerp(light, ratio), 0.5, 1.2)
				end
			end
		elseif style == "Crystal" then
			for index = 1, 3 do
				local ratio  = (index - 1) / 2
				local length = (4.2 - ratio * 1.4) * scale
				local shard = addFeather(side, {
					Length = length, Width = (0.95 - ratio * 0.25) * scale, Thickness = 0.07 * scale,
					Spread = math.rad(60 + ratio * 40), Sweep = math.rad(24),
					Pitch = math.rad(-14),
					OriginX = 0.34 * scale, OriginY = 0.3 * scale, OriginZ = 0.62 * scale,
					Color = base:Lerp(light, ratio * 0.7), Transparency = 0.35,
					Phase = index * 0.5, Amp = 0.1, Tip = true, TipColor = light,
				})
				if index == 1 then
					addTrail(shard, light, 0.45, 1.6)
				end
			end
		else
			local rows = {
				{ Count = 7, Long = 4.0, Short = 2.2, From = 56, To = 124,
				  Width = 0.48, Thick = 0.1,  Z = 0.68, Y = 0.3,  X = 0.4,  Alpha = 0.06, Amp = 0.16, Tip = true,  Pitch = -12 },
				{ Count = 5, Long = 2.7, Short = 1.6, From = 62, To = 116,
				  Width = 0.4,  Thick = 0.09, Z = 0.56, Y = 0.24, X = 0.36, Alpha = 0.2,  Amp = 0.12, Tip = true,  Pitch = -8 },
				{ Count = 4, Long = 1.4, Short = 0.85, From = 70, To = 106,
				  Width = 0.32, Thick = 0.08, Z = 0.46, Y = 0.2,  X = 0.32, Alpha = 0.4,  Amp = 0.08, Tip = false, Pitch = -5 },
			}
			for rowIndex, row in ipairs(rows) do
				local count = quantity(row.Count, 3)
				for index = 1, count do
					local ratio  = count > 1 and (index - 1) / (count - 1) or 0
					local length = (row.Long - ratio * (row.Long - row.Short)) * scale
					local feather = addFeather(side, {
						Length    = length,
						Width     = row.Width * scale,
						Thickness = row.Thick * scale,
						Spread    = math.rad(row.From + ratio * (row.To - row.From)),
						Sweep     = math.rad(24 - rowIndex * 3),
						Pitch     = math.rad(row.Pitch),
						OriginX   = row.X * scale,
						OriginY   = row.Y * scale,
						OriginZ   = row.Z * scale,
						Color     = base:Lerp(light, ratio * 0.85),
						Transparency = row.Alpha,
						Phase     = index * 0.26 + rowIndex * 0.5,
						Amp       = row.Amp,
						Tip       = row.Tip,
						TipColor  = light,
					})
					if rowIndex == 1 and index <= 2 and not IS_PHONE then
						addTrail(feather, light, 0.4, 1.1)
					end
				end
			end
		end
	end

	if vis.Wings.Glow then
		local pointLight = Instance.new("PointLight")
		pointLight.Color      = base
		pointLight.Brightness = 2.4
		pointLight.Range      = 14
		pointLight.Name       = "CrystalHub_WingGlow"
		pointLight.Parent     = torso
	end
end

--======================================================================--
--======================================================================--
local function clearHalo()
	if haloFolder then
		haloFolder:Destroy()
	end
	haloFolder = nil
	haloParts  = {}
	if headPart then
		for _, child in ipairs(headPart:GetChildren()) do
			if child.Name == "CrystalHub_HaloGlow" then
				child:Destroy()
			end
		end
	end
end

Visuals.HaloStyles = { "Ring", "Double", "Orbs", "Tilted" }

local function buildHalo()
	clearHalo()
	if not vis.Halo.Enabled or not headPart then
		return
	end

	haloFolder = Instance.new("Folder")
	haloFolder.Name   = "CrystalHub_Halo"
	haloFolder.Parent = character

	local color = vis.Halo.Color
	local style = vis.Halo.Style

	local function ring(radius, height, segments, tilt, direction, thickness)
		segments = quantity(segments, 8)
		local segmentLength = (2 * math.pi * radius / segments) * 1.08
		for index = 1, segments do
			local angle = (index / segments) * math.pi * 2
			local piece = newNeonPart(Vector3.new(thickness, thickness, segmentLength), color)
			piece.Parent = haloFolder
			local weld = weldTo(headPart, piece, CFrame.new(0, height, 0)
				* CFrame.Angles(tilt, angle, 0)
				* CFrame.new(0, 0, -radius)
				* CFrame.Angles(0, math.rad(90), 0))
			table.insert(haloParts, {
				Weld      = weld,
				Angle     = angle,
				Radius    = radius,
				Height    = height,
				Tilt      = tilt,
				Direction = direction,
			})
		end
	end

	if style == "Double" then
		ring(0.85, 1.55, 16, 0, 1, 0.1)
		ring(0.6, 1.75, 12, math.rad(28), -1, 0.08)
	elseif style == "Orbs" then
		for index = 1, 6 do
			local orb = newNeonPart(Vector3.new(0.22, 0.22, 0.22), color, "Part")
			orb.Shape  = Enum.PartType.Ball
			orb.Parent = haloFolder
			local weld = weldTo(headPart, orb, CFrame.new(0, 1.6, 0))
			table.insert(haloParts, {
				Weld      = weld,
				Angle     = (index / 6) * math.pi * 2,
				Radius    = 0.9,
				Height    = 1.6,
				Tilt      = 0,
				Direction = 1,
				Bob       = index * 0.5,
			})
		end
	elseif style == "Tilted" then
		ring(0.9, 1.6, 18, math.rad(22), 1, 0.1)
	else
		ring(0.85, 1.6, 18, 0, 1, 0.1)
	end

	if vis.Halo.Glow then
		local light = Instance.new("PointLight")
		light.Color      = color
		light.Brightness = 1.6
		light.Range      = 9
		light.Name       = "CrystalHub_HaloGlow"
		light.Parent     = headPart
	end
end

--======================================================================--
--======================================================================--

local function clearChinaHat()
	if hatFolder then
		hatFolder:Destroy()
	end
	hatFolder = nil
	hatParts  = {}
	if headPart then
		for _, child in ipairs(headPart:GetChildren()) do
			if child.Name == "CrystalHub_HatGlow" then
				child:Destroy()
			end
		end
	end
end

Visuals.HatStyles = { "Layered", "Cone", "Rings", "Spikes", "Classic" }

local function buildChinaHat()
	clearChinaHat()
	if not vis.ChinaHat.Enabled or not headPart then
		return
	end

	hatFolder = Instance.new("Folder")
	hatFolder.Name   = "CrystalHub_ChinaHat"
	hatFolder.Parent = character

	local color = vis.ChinaHat.Color
	local light = lighten(color, 0.35)
	local size  = math.clamp(vis.ChinaHat.Size or 1, 0.4, 3)
	local style = vis.ChinaHat.Style

    if style == "Classic" then
        local hat = Instance.new("Part")
        hat.Name = "ChineseHat"
        hat.Size = Vector3.new(2, 0.2, 2)
        hat.Transparency = 0.3
        hat.Color = color
        hat.Material = Enum.Material.Neon
        hat.CanCollide = false
        hat.CanQuery = false
        hat.CanTouch = false
        hat.Massless = true
        local mesh = Instance.new("SpecialMesh")
        mesh.MeshId = "rbxassetid://1033714"
        mesh.Scale = Vector3.new(2.4 * size, 1.6 * size, 2.4 * size)
        mesh.Parent = hat
        hat.Parent = hatFolder
        local weld = Instance.new("Weld")
        weld.Part0 = headPart
        weld.Part1 = hat
        weld.C0 = CFrame.new(0, 1.1 * size, 0)
        weld.Parent = hat
        table.insert(hatParts, { Kind = "classic", Weld = weld, Height = 1.1 * size })
        if vis.ChinaHat.Glow then
            local lightObj = Instance.new("PointLight")
            lightObj.Name = "CrystalHub_HatGlow"
            lightObj.Color = color
            lightObj.Brightness = 1.8
            lightObj.Range = 11
            lightObj.Parent = headPart
        end
        return
    end

	local function disc(radius, height, thickness, transparency, discColor)
		local part = newNeonPart(Vector3.new(thickness, radius * 2, radius * 2), discColor or color, "Part")
		part.Shape        = Enum.PartType.Cylinder
		part.Transparency = transparency or 0.2
		part.Parent       = hatFolder
		local weld = weldTo(headPart, part, CFrame.new(0, height, 0) * CFrame.Angles(0, 0, math.rad(90)))
		table.insert(hatParts, { Weld = weld, Kind = "disc", Height = height })
		return part
	end

	local function segRing(radius, height, segments, thickness, tilt, transparency)
		segments = quantity(segments, 6)
		local chord = (2 * math.pi * radius / segments) * 1.08
		for index = 1, segments do
			local angle = (index / segments) * math.pi * 2
			local piece = newNeonPart(Vector3.new(thickness, thickness, chord), color)
			piece.Transparency = transparency or 0.1
			piece.Parent       = hatFolder
			local weld = weldTo(headPart, piece, CFrame.new(0, height, 0)
				* CFrame.Angles(tilt or 0, angle, 0)
				* CFrame.new(0, 0, -radius)
				* CFrame.Angles(0, math.rad(90), 0))
			table.insert(hatParts, {
				Weld   = weld,
				Kind   = "seg",
				Angle  = angle,
				Radius = radius,
				Height = height,
				Tilt   = tilt or 0,
			})
		end
	end

	local function spikes(count, radius, height, length)
		count = quantity(count, 4)
		for index = 1, count do
			local angle = (index / count) * math.pi * 2
			local piece = newNeonPart(Vector3.new(0.09 * size, 0.09 * size, length), light)
			piece.Transparency = 0.05
			piece.Parent       = hatFolder
			local weld = weldTo(headPart, piece, CFrame.new(0, height, 0)
				* CFrame.Angles(0, angle, 0)
				* CFrame.new(0, 0, -(radius + length * 0.45)))
			table.insert(hatParts, {
				Weld   = weld,
				Kind   = "spike",
				Angle  = angle,
				Radius = radius + length * 0.45,
				Height = height,
			})
		end
	end

	if style == "Cone" then
		local steps = quantity(12, 6)
		for index = 1, steps do
			local ratio  = (index - 1) / (steps - 1)
			local radius = (2.5 - ratio * 2.25) * size
			local height = (1.75 + ratio * 1.5) * size
			disc(radius, height, 0.14 * size, 0.18, color:Lerp(light, ratio))
		end
		segRing(2.55 * size, 1.72 * size, 26, 0.08 * size, 0, 0)
	elseif style == "Rings" then
		segRing(2.5 * size, 1.8 * size, 26, 0.1 * size, 0, 0)
		segRing(1.7 * size, 2.25 * size, 20, 0.09 * size, 0, 0.05)
		segRing(0.9 * size, 2.7 * size, 14, 0.08 * size, 0, 0.1)
		disc(0.28 * size, 3.05 * size, 0.5 * size, 0.05, light)
	elseif style == "Spikes" then
		for index = 1, 4 do
			local ratio = (index - 1) / 3
			disc((2.4 - ratio * 1.9) * size, (1.8 + ratio * 1.1) * size, 0.16 * size, 0.2,
				color:Lerp(light, ratio))
		end
		spikes(10, 2.45 * size, 1.82 * size, 0.75 * size)
		segRing(2.5 * size, 1.78 * size, 24, 0.08 * size, 0, 0)
	else
		local steps = 5
		for index = 1, steps do
			local ratio  = (index - 1) / (steps - 1)
			local radius = (2.6 - ratio * 2.0) * size
			local height = (1.78 + ratio * 1.35) * size
			disc(radius, height, 0.18 * size, 0.22, color:Lerp(light, ratio))
			segRing(radius + 0.03 * size, height, 22 - index * 2, 0.06 * size, 0, 0)
		end
		disc(0.22 * size, 3.25 * size, 0.42 * size, 0.05, light)
	end

	if vis.ChinaHat.Glow then
		local pointLight = Instance.new("PointLight")
		pointLight.Color      = color
		pointLight.Brightness = 1.8
		pointLight.Range      = 11
		pointLight.Name       = "CrystalHub_HatGlow"
		pointLight.Parent     = headPart
	end
end

--======================================================================--
--======================================================================--
local function stopLoopIfIdle()
	if #wingParts == 0 and #haloParts == 0 and #hatParts == 0 and animConnection then
		animConnection:Disconnect()
		animConnection = nil
	end
end

local FLAP_STEP = 1 / 30

local function ensureLoop()
	if animConnection then
		return
	end
	animConnection = RunService.Heartbeat:Connect(function(delta)
		animClock = animClock + delta

		flapAccum = flapAccum + delta
		if #wingParts > 0 and flapAccum >= FLAP_STEP then
			flapAccum = 0
			if vis.Wings.Flap then
				flapReset = false
				for _, item in ipairs(wingParts) do
					local flap = math.sin(animClock * 2.6 + item.Phase) * (item.Amp or 0.13)
					item.Weld.C0 = item.Origin * CFrame.Angles(0, 0, flap) * item.Offset
				end
			elseif not flapReset then
				flapReset = true
				for _, item in ipairs(wingParts) do
					item.Weld.C0 = item.Origin * item.Offset
				end
			end
		end

		for _, item in ipairs(haloParts) do
			local angle  = item.Angle + animClock * vis.Halo.Speed * item.Direction
			local height = item.Height
			if item.Bob then
				height = height + math.sin(animClock * 2 + item.Bob) * 0.08
			end
			item.Weld.C0 = CFrame.new(0, height, 0)
				* CFrame.Angles(item.Tilt, angle, 0)
				* CFrame.new(0, 0, -item.Radius)
				* CFrame.Angles(0, math.rad(90), 0)
		end

		if #hatParts > 0 then
			local spin = animClock * (vis.ChinaHat.Spin or 0)
			for _, item in ipairs(hatParts) do
				if item.Kind == "disc" then
					item.Weld.C0 = CFrame.new(0, item.Height, 0)
						* CFrame.Angles(0, spin, 0)
						* CFrame.Angles(0, 0, math.rad(90))
                elseif item.Kind == "classic" then
                    item.Weld.C0 = CFrame.new(0, item.Height, 0)
                        * CFrame.Angles(0, spin, 0)
                elseif item.Kind == "spike" then
					item.Weld.C0 = CFrame.new(0, item.Height, 0)
						* CFrame.Angles(0, item.Angle + spin, 0)
						* CFrame.new(0, 0, -item.Radius)
				else
					item.Weld.C0 = CFrame.new(0, item.Height, 0)
						* CFrame.Angles(item.Tilt, item.Angle + spin, 0)
						* CFrame.new(0, 0, -item.Radius)
						* CFrame.Angles(0, math.rad(90), 0)
				end
			end
		end
	end)
end

local function findTorso(char, human)
	local rig = human and human.RigType
	if rig == Enum.HumanoidRigType.R6 then
		return char:FindFirstChild("Torso") or char:WaitForChild("Torso", 3)
	end
	return char:FindFirstChild("UpperTorso") or char:WaitForChild("UpperTorso", 3)
end

local function bindCharacter(char)
	character = char
	humanoid  = char:FindFirstChildOfClass("Humanoid") or char:WaitForChild("Humanoid", 10)
	torso     = findTorso(char, humanoid)
		or char:FindFirstChild("HumanoidRootPart")
		or char:WaitForChild("HumanoidRootPart", 3)
	headPart  = char:FindFirstChild("Head") or char:WaitForChild("Head", 3) or torso

	wingParts, haloParts, hatParts = {}, {}, {}

	if jumpConnection then
		jumpConnection:Disconnect()
		jumpConnection = nil
	end
	if humanoid then
		jumpConnection = humanoid.Jumping:Connect(function(active)
			if active then
				playJumpEffect()
			end
		end)
	end

	buildWings()
	buildHalo()
	buildChinaHat()
	if #wingParts > 0 or #haloParts > 0 or #hatParts > 0 then
		ensureLoop()
	end
end

if LocalPlayer.Character then
	task.spawn(bindCharacter, LocalPlayer.Character)
end

characterConnection = LocalPlayer.CharacterAdded:Connect(function(char)
	task.wait(0.4)
	bindCharacter(char)
end)

function Visuals.SetJump(enabled)
	vis.Jump.Enabled = enabled and true or false
end

function Visuals.SetWings(enabled)
	vis.Wings.Enabled = enabled and true or false
	if vis.Wings.Enabled then
		buildWings()
		ensureLoop()
	else
		clearWings()
		stopLoopIfIdle()
	end
end

function Visuals.SetHalo(enabled)
	vis.Halo.Enabled = enabled and true or false
	if vis.Halo.Enabled then
		buildHalo()
		ensureLoop()
	else
		clearHalo()
		stopLoopIfIdle()
	end
end

function Visuals.SetChinaHat(enabled)
	vis.ChinaHat.Enabled = enabled and true or false
	if vis.ChinaHat.Enabled then
		buildChinaHat()
		ensureLoop()
	else
		clearChinaHat()
		stopLoopIfIdle()
	end
end

local function scheduleRebuild(key, enabledCheck, builder, listCheck)
	if not enabledCheck() or rebuildPending[key] then
		return
	end
	rebuildPending[key] = true
	task.delay(0.15, function()
		rebuildPending[key] = false
		if enabledCheck() then
			builder()
			if listCheck() > 0 then
				ensureLoop()
			end
		end
		stopLoopIfIdle()
	end)
end

function Visuals.RebuildWings()
	scheduleRebuild("Wings",
		function() return vis.Wings.Enabled end,
		buildWings,
		function() return #wingParts end)
end

function Visuals.RebuildHalo()
	scheduleRebuild("Halo",
		function() return vis.Halo.Enabled end,
		buildHalo,
		function() return #haloParts end)
end

function Visuals.RebuildChinaHat()
	scheduleRebuild("Hat",
		function() return vis.ChinaHat.Enabled end,
		buildChinaHat,
		function() return #hatParts end)
end

--======================================================================--
--======================================================================--
local LIGHTING_KEYS = {
	"ClockTime", "Brightness", "Ambient", "OutdoorAmbient", "ColorShift_Top",
	"ColorShift_Bottom", "FogColor", "FogStart", "FogEnd", "ExposureCompensation",
	"EnvironmentDiffuseScale", "EnvironmentSpecularScale", "GlobalShadows",
}

local SkyPresets = {
	["Black Void"] = {
		Sky      = { Stars = 0, Sun = 0, Moon = 0, Bodies = false },
		Lighting = {
			ClockTime = 0, Brightness = 0.6, GlobalShadows = true,
			Ambient = Color3.fromRGB(10, 10, 14), OutdoorAmbient = Color3.fromRGB(14, 14, 20),
			ColorShift_Top = Color3.fromRGB(0, 0, 0), ColorShift_Bottom = Color3.fromRGB(0, 0, 0),
			FogColor = Color3.fromRGB(0, 0, 0), FogStart = 0, FogEnd = 900,
			ExposureCompensation = -0.1,
		},
		Color = { Contrast = 0.12, Saturation = -0.1, TintColor = Color3.fromRGB(235, 235, 245) },
	},
	["Starfield"] = {
		Sky      = { Stars = 9000, Sun = 0, Moon = 12, Bodies = true },
		Lighting = {
			ClockTime = 0, Brightness = 1, GlobalShadows = true,
			Ambient = Color3.fromRGB(16, 18, 30), OutdoorAmbient = Color3.fromRGB(24, 28, 48),
			ColorShift_Top = Color3.fromRGB(30, 34, 70), ColorShift_Bottom = Color3.fromRGB(8, 8, 18),
			FogColor = Color3.fromRGB(10, 12, 24), FogEnd = 2500, ExposureCompensation = 0.1,
		},
		Atmosphere = { Density = 0.32, Offset = 0.1, Color = Color3.fromRGB(90, 110, 190),
			Decay = Color3.fromRGB(20, 24, 60), Glare = 0.3, Haze = 1.2 },
		Bloom = { Intensity = 0.9, Size = 26, Threshold = 0.85 },
	},
	["Neon Night"] = {
		Lighting = {
			ClockTime = 22.4, Brightness = 1.4, GlobalShadows = true,
			Ambient = Color3.fromRGB(24, 18, 42), OutdoorAmbient = Color3.fromRGB(40, 30, 70),
			ColorShift_Top = Color3.fromRGB(90, 60, 190), ColorShift_Bottom = Color3.fromRGB(20, 14, 40),
			FogColor = Color3.fromRGB(26, 18, 44), FogEnd = 1800, ExposureCompensation = 0.2,
		},
		Atmosphere = { Density = 0.42, Offset = 0.2, Color = Color3.fromRGB(150, 120, 255),
			Decay = Color3.fromRGB(60, 30, 120), Glare = 0.9, Haze = 2.2 },
		Bloom = { Intensity = 1.4, Size = 30, Threshold = 0.8 },
		Color = { Contrast = 0.15, Saturation = 0.2, TintColor = Color3.fromRGB(225, 215, 255) },
	},
	["Crystal Dawn"] = {
		Lighting = {
			ClockTime = 6.4, Brightness = 2.2, GlobalShadows = true,
			Ambient = Color3.fromRGB(40, 30, 60), OutdoorAmbient = Color3.fromRGB(90, 70, 130),
			ColorShift_Top = Color3.fromRGB(190, 130, 255), ColorShift_Bottom = Color3.fromRGB(70, 40, 110),
			FogColor = Color3.fromRGB(120, 80, 170), FogEnd = 2400, ExposureCompensation = 0.25,
		},
		Atmosphere = { Density = 0.38, Offset = 0.35, Color = Color3.fromRGB(230, 190, 255),
			Decay = Color3.fromRGB(120, 60, 200), Glare = 1.4, Haze = 2.6 },
		Bloom = { Intensity = 1.6, Size = 34, Threshold = 0.75 },
		Rays  = { Intensity = 0.14, Spread = 0.9 },
		Color = { Contrast = 0.1, Saturation = 0.22, TintColor = Color3.fromRGB(240, 225, 255) },
	},
	["Sunset"] = {
		Lighting = {
			ClockTime = 17.7, Brightness = 2.6, GlobalShadows = true,
			Ambient = Color3.fromRGB(60, 38, 30), OutdoorAmbient = Color3.fromRGB(120, 80, 60),
			ColorShift_Top = Color3.fromRGB(255, 150, 80), ColorShift_Bottom = Color3.fromRGB(90, 40, 30),
			FogColor = Color3.fromRGB(220, 130, 80), FogEnd = 2200, ExposureCompensation = 0.15,
		},
		Atmosphere = { Density = 0.45, Offset = 0.5, Color = Color3.fromRGB(255, 190, 140),
			Decay = Color3.fromRGB(180, 80, 40), Glare = 1.8, Haze = 3.2 },
		Bloom = { Intensity = 1.2, Size = 28, Threshold = 0.9 },
		Rays  = { Intensity = 0.2, Spread = 1 },
		Color = { Contrast = 0.08, Saturation = 0.15, TintColor = Color3.fromRGB(255, 240, 225) },
	},
	["Aurora"] = {
		Sky      = { Stars = 6000, Sun = 0, Moon = 10, Bodies = true },
		Lighting = {
			ClockTime = 1.2, Brightness = 1.2, GlobalShadows = true,
			Ambient = Color3.fromRGB(14, 30, 30), OutdoorAmbient = Color3.fromRGB(30, 60, 60),
			ColorShift_Top = Color3.fromRGB(60, 200, 170), ColorShift_Bottom = Color3.fromRGB(10, 30, 40),
			FogColor = Color3.fromRGB(20, 50, 55), FogEnd = 2600, ExposureCompensation = 0.2,
		},
		Atmosphere = { Density = 0.4, Offset = 0.25, Color = Color3.fromRGB(120, 255, 210),
			Decay = Color3.fromRGB(20, 90, 110), Glare = 1.6, Haze = 2.4 },
		Bloom = { Intensity = 1.5, Size = 32, Threshold = 0.78 },
		Color = { Contrast = 0.14, Saturation = 0.3, TintColor = Color3.fromRGB(220, 255, 245) },
	},
	["Blood Moon"] = {
		Sky      = { Stars = 2500, Sun = 0, Moon = 26, Bodies = true },
		Lighting = {
			ClockTime = 0.4, Brightness = 1.1, GlobalShadows = true,
			Ambient = Color3.fromRGB(36, 12, 14), OutdoorAmbient = Color3.fromRGB(60, 20, 22),
			ColorShift_Top = Color3.fromRGB(200, 50, 50), ColorShift_Bottom = Color3.fromRGB(40, 8, 10),
			FogColor = Color3.fromRGB(50, 12, 14), FogEnd = 1600, ExposureCompensation = 0.1,
		},
		Atmosphere = { Density = 0.47, Offset = 0.15, Color = Color3.fromRGB(255, 120, 110),
			Decay = Color3.fromRGB(120, 20, 20), Glare = 1.2, Haze = 3 },
		Bloom = { Intensity = 1.3, Size = 30, Threshold = 0.82 },
		Color = { Contrast = 0.2, Saturation = 0.1, TintColor = Color3.fromRGB(255, 220, 220) },
	},
}

local SkyOrder = { "Default", "Black Void", "Starfield", "Neon Night", "Crystal Dawn", "Sunset", "Aurora", "Blood Moon" }

local STASH_CLASSES = {
	"Sky", "Atmosphere", "BloomEffect", "ColorCorrectionEffect",
	"SunRaysEffect", "BlurEffect", "DepthOfFieldEffect",
}

local skyObjects    = {}
local savedLighting = nil
local stashed       = {}

Visuals.CurrentSky = "Default"

local function saveLighting()
	if savedLighting then
		return
	end
	savedLighting = {}
	for _, key in ipairs(LIGHTING_KEYS) do
		local ok, value = pcall(function() return Lighting[key] end)
		if ok then
			savedLighting[key] = value
		end
	end
end

local function clearSkyObjects()
	for _, inst in ipairs(skyObjects) do
		if inst and inst.Parent then
			inst:Destroy()
		end
	end
	skyObjects = {}
end

local function stashOriginals()
	if #stashed > 0 then
		return
	end
	for _, child in ipairs(Lighting:GetChildren()) do
		for _, className in ipairs(STASH_CLASSES) do
			if child:IsA(className) then
				table.insert(stashed, child)
				child.Parent = nil
				break
			end
		end
	end
end

local function restoreOriginals()
	for _, inst in ipairs(stashed) do
		if inst then
			inst.Parent = Lighting
		end
	end
	stashed = {}
end

function Visuals.RestoreSky()
	clearSkyObjects()
	if savedLighting then
		for key, value in pairs(savedLighting) do
			pcall(function() Lighting[key] = value end)
		end
	end
	restoreOriginals()
	Visuals.CurrentSky = "Default"
end

function Visuals.GetSkies()
	return SkyOrder
end

function Visuals.ApplySky(name)
	saveLighting()
	local preset = SkyPresets[name]
	if not preset then
		Visuals.RestoreSky()
		return false
	end

	clearSkyObjects()
	stashOriginals()

	if savedLighting then
		for key, value in pairs(savedLighting) do
			pcall(function() Lighting[key] = value end)
		end
	end

	for key, value in pairs(preset.Lighting or {}) do
		pcall(function() Lighting[key] = value end)
	end

	if preset.Sky then
		local sky = Instance.new("Sky")
		sky.SkyboxBk = ""
		sky.SkyboxDn = ""
		sky.SkyboxFt = ""
		sky.SkyboxLf = ""
		sky.SkyboxRt = ""
		sky.SkyboxUp = ""
		sky.StarCount            = preset.Sky.Stars or 0
		sky.SunAngularSize       = preset.Sky.Sun or 0
		sky.MoonAngularSize      = preset.Sky.Moon or 0
		sky.CelestialBodiesShown = preset.Sky.Bodies and true or false
		sky.Parent = Lighting
		table.insert(skyObjects, sky)
	end

	if preset.Atmosphere then
		local atmosphere = Instance.new("Atmosphere")
		atmosphere.Density = preset.Atmosphere.Density or 0.3
		atmosphere.Offset  = preset.Atmosphere.Offset or 0
		atmosphere.Color   = preset.Atmosphere.Color or Color3.fromRGB(200, 200, 200)
		atmosphere.Decay   = preset.Atmosphere.Decay or Color3.fromRGB(100, 100, 100)
		atmosphere.Glare   = preset.Atmosphere.Glare or 0
		atmosphere.Haze    = preset.Atmosphere.Haze or 0
		atmosphere.Parent  = Lighting
		table.insert(skyObjects, atmosphere)
	end

	if preset.Bloom then
		local bloom = Instance.new("BloomEffect")
		bloom.Intensity = preset.Bloom.Intensity or 1
		bloom.Size      = preset.Bloom.Size or 24
		bloom.Threshold = preset.Bloom.Threshold or 0.9
		bloom.Parent    = Lighting
		table.insert(skyObjects, bloom)
	end

	if preset.Color then
		local correction = Instance.new("ColorCorrectionEffect")
		correction.Brightness = preset.Color.Brightness or 0
		correction.Contrast   = preset.Color.Contrast or 0
		correction.Saturation = preset.Color.Saturation or 0
		correction.TintColor  = preset.Color.TintColor or Color3.fromRGB(255, 255, 255)
		correction.Parent     = Lighting
		table.insert(skyObjects, correction)
	end

	if preset.Rays then
		local rays = Instance.new("SunRaysEffect")
		rays.Intensity = preset.Rays.Intensity or 0.1
		rays.Spread    = preset.Rays.Spread or 1
		rays.Parent    = Lighting
		table.insert(skyObjects, rays)
	end

	Visuals.CurrentSky = name
	return true
end

function Visuals.Unload()
	vis.Wings.Enabled    = false
	vis.Halo.Enabled     = false
	vis.ChinaHat.Enabled = false
	vis.Jump.Enabled     = false
	clearWings()
	clearHalo()
	clearChinaHat()
	if animConnection then
		animConnection:Disconnect()
		animConnection = nil
	end
	if jumpConnection then
		jumpConnection:Disconnect()
		jumpConnection = nil
	end
	if characterConnection then
		characterConnection:Disconnect()
		characterConnection = nil
	end
	Visuals.RestoreSky()
	if effectsFolder then
		effectsFolder:Destroy()
		effectsFolder = nil
	end
end

--======================================================================--
--======================================================================--
local Trails = {}

Trails.Settings = {
	Enabled  = false,
	Style    = "Neon",
	Color    = Color3.fromRGB(120, 190, 255),
	Color2   = Color3.fromRGB(255, 100, 200),
	Width    = 1.5,
	Lifetime = 0.5,
	Rainbow  = false,
}

local trailSettings = Trails.Settings
local trailFolder
local trailConnections = {}
local trailAttachments = {}
local trailRainbowConn
local trailHue = 0

Trails.Styles = {
	"Neon", "Rainbow", "Fire", "Comet", "Pastel", "Dark", "Crystal", "Candy"
}

local function trailColorSeq(style, color, color2)
	if style == "Fire" then
		return ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 220, 60)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 80, 20)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(80, 20, 0)),
		})
	elseif style == "Comet" then
		return ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
			ColorSequenceKeypoint.new(0.4, color),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(20, 20, 40)),
		})
	elseif style == "Pastel" then
		return ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 200, 230)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(200, 230, 255)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(230, 255, 200)),
		})
	elseif style == "Dark" then
		return ColorSequence.new({
			ColorSequenceKeypoint.new(0, color),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(10, 10, 15)),
		})
	elseif style == "Crystal" then
		return ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(200, 240, 255)),
			ColorSequenceKeypoint.new(0.5, color),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(180, 200, 255)),
		})
	elseif style == "Candy" then
		return ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 100, 180)),
			ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 220, 80)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(100, 200, 255)),
		})
	else
		return ColorSequence.new({
			ColorSequenceKeypoint.new(0, color),
			ColorSequenceKeypoint.new(1, color2 or color),
		})
	end
end

local function trailTransSeq(style)
	if style == "Fire" then
		return NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.6, 0.3),
			NumberSequenceKeypoint.new(1, 1),
		})
	elseif style == "Comet" then
		return NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.3, 0.1),
			NumberSequenceKeypoint.new(1, 1),
		})
	else
		return NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.1),
			NumberSequenceKeypoint.new(1, 1),
		})
	end
end

local function clearTrails()
	for _, conn in ipairs(trailConnections) do
		pcall(function() conn:Disconnect() end)
	end
	trailConnections = {}
	if trailRainbowConn then
		trailRainbowConn:Disconnect()
		trailRainbowConn = nil
	end
	if trailFolder and trailFolder.Parent then
		trailFolder:Destroy()
	end
	trailFolder = nil
	for _, a in ipairs(trailAttachments) do
		pcall(function() if a then a:Destroy() end end)
	end
	trailAttachments = {}
end

local buildToken = 0
local function buildTrails()
	clearTrails()
	if not trailSettings.Enabled then return end
	buildToken = buildToken + 1
	local myToken = buildToken

	local char = LocalPlayer.Character
	if not char then return end

	local root = char:FindFirstChild("HumanoidRootPart")
	if not root then
		task.spawn(function()
			local ok = pcall(function() root = char:WaitForChild("HumanoidRootPart", 5) end)
			if not ok or not root or myToken ~= buildToken then return end
			if not trailSettings.Enabled or LocalPlayer.Character ~= char then return end
			buildTrails()
		end)
		return
	end

	trailFolder = Instance.new("Folder")
	trailFolder.Name   = "CrystalHub_Trails"
	trailFolder.Parent = char

	local style    = trailSettings.Style
	local color    = trailSettings.Color
	local color2   = trailSettings.Color2
	local width    = trailSettings.Width
	local lifetime = trailSettings.Lifetime

	local a0 = Instance.new("Attachment")
	a0.Name     = "CrystalHub_TrailA0"
	a0.Position = Vector3.new(0, 1, 0)
	a0.Parent   = root

	local a1 = Instance.new("Attachment")
	a1.Name     = "CrystalHub_TrailA1"
	a1.Position = Vector3.new(0, -1, 0)
	a1.Parent   = root
	trailAttachments = { a0, a1 }

	local trail = Instance.new("Trail")
	trail.Attachment0    = a0
	trail.Attachment1    = a1
	trail.Lifetime       = lifetime
	trail.WidthScale     = NumberSequence.new({
		NumberSequenceKeypoint.new(0, width),
		NumberSequenceKeypoint.new(1, 0),
	})
	trail.LightEmission  = 1
	trail.LightInfluence = 0
	trail.FaceCamera     = true
	trail.Color          = trailColorSeq(style, color, color2)
	trail.Transparency   = trailTransSeq(style)
	trail.Parent         = trailFolder

	if style == "Rainbow" or trailSettings.Rainbow then
		trailRainbowConn = RunService.Heartbeat:Connect(function(dt)
			trailHue = (trailHue + dt * 0.4) % 1
			local c = Color3.fromHSV(trailHue, 0.9, 1)
			local c2 = Color3.fromHSV((trailHue + 0.5) % 1, 0.9, 1)
			trail.Color = ColorSequence.new({ c, c2 })
		end)
	end
end

function Trails.SetEnabled(enabled)
	trailSettings.Enabled = enabled and true or false
	if trailSettings.Enabled then
		buildTrails()
	else
		clearTrails()
	end
end

function Trails.Rebuild()
	if trailSettings.Enabled then
		buildTrails()
	end
end

LocalPlayer.CharacterAdded:Connect(function()
	if trailSettings.Enabled then
		buildTrails()
	end
end)

--======================================================================--
--======================================================================--
local KillFX = {}

KillFX.Settings = {
	Enabled = false,
	Style   = "Explosion",
	Color   = Color3.fromRGB(255, 60, 60),
	Size    = 1,
}

local killSettings = KillFX.Settings

KillFX.Styles = { "Explosion", "Shards", "Hearts", "Stars", "Sparkle", "Ghost" }

local function spawnKillEffect(position)
	local style = killSettings.Style
	local color = killSettings.Color
	local size  = killSettings.Size
	local folder = ensureFolder()

	if style == "Explosion" then
		for ring = 1, 3 do
			local part = Instance.new("Part")
			part.Shape        = Enum.PartType.Cylinder
			part.Size         = Vector3.new(0.1, 0.1, 0.1)
			part.CFrame       = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
			part.Anchored     = true
			part.CanCollide   = false
			part.CanQuery     = false
			part.CanTouch     = false
			part.CastShadow   = false
			part.Material     = Enum.Material.Neon
			part.Color        = color
			part.Transparency = 0.2
			part.Parent       = folder
			local targetSize  = (4 + ring * 2) * size
			TweenService:Create(part,
				TweenInfo.new(0.5 + ring * 0.1, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
				{ Size = Vector3.new(0.05, targetSize, targetSize), Transparency = 1 }
			):Play()
			game:GetService("Debris"):AddItem(part, 0.8)
		end

	elseif style == "Shards" then
		for _ = 1, math.floor(12 * size) do
			local shard = Instance.new("Part")
			shard.Size        = Vector3.new(0.15, 0.6, 0.15) * size
			shard.CFrame      = CFrame.new(position)
			shard.Anchored    = false
			shard.CanCollide  = false
			shard.CanQuery    = false
			shard.CanTouch    = false
			shard.Material    = Enum.Material.Neon
			shard.Color       = color
			shard.Transparency = 0.1
			shard.Parent      = folder
			local vel = Vector3.new(
				math.random(-10, 10),
				math.random(8, 18),
				math.random(-10, 10)
			) * size
			local bp = Instance.new("BodyVelocity")
			bp.Velocity    = vel
			bp.MaxForce    = Vector3.new(1e5, 1e5, 1e5)
			bp.Parent      = shard
			TweenService:Create(shard,
				TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ Transparency = 1 }
			):Play()
			game:GetService("Debris"):AddItem(shard, 0.9)
		end

	elseif style == "Hearts" or style == "Stars" then
		local assetId = style == "Hearts"
			and "rbxassetid://11754490336"
			or  "rbxassetid://11716557686"
		for _ = 1, math.floor(8 * size) do
			local billboard = Instance.new("BillboardGui")
			billboard.Size          = UDim2.fromOffset(40 * size, 40 * size)
			billboard.StudsOffset   = Vector3.new(
				math.random(-3, 3), math.random(0, 4), math.random(-3, 3)
			) * size
			billboard.AlwaysOnTop   = true
			billboard.ResetOnSpawn  = false
			local part = Instance.new("Part")
			part.Size        = Vector3.new(0.1, 0.1, 0.1)
			part.CFrame      = CFrame.new(position)
			part.Anchored    = true
			part.CanCollide  = false
			part.CanQuery    = false
			part.CanTouch    = false
			part.Transparency = 1
			part.Parent      = folder
			billboard.Adornee = part
			billboard.Parent  = part
			local img = Instance.new("ImageLabel")
			img.Size                   = UDim2.fromScale(1, 1)
			img.BackgroundTransparency = 1
			img.Image                  = assetId
			img.ImageColor3            = color
			img.Parent                 = billboard
			TweenService:Create(part,
				TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ CFrame = part.CFrame + Vector3.new(0, 4 * size, 0) }
			):Play()
			TweenService:Create(img,
				TweenInfo.new(1.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ ImageTransparency = 1 }
			):Play()
			game:GetService("Debris"):AddItem(part, 1.3)
		end

	elseif style == "Sparkle" then
		for _ = 1, math.floor(20 * size) do
			local spark = Instance.new("Part")
			spark.Shape       = Enum.PartType.Ball
			spark.Size        = Vector3.new(0.2, 0.2, 0.2) * size
			spark.CFrame      = CFrame.new(position + Vector3.new(
				math.random(-2, 2), math.random(0, 2), math.random(-2, 2)
			))
			spark.Anchored    = false
			spark.CanCollide  = false
			spark.CanQuery    = false
			spark.CanTouch    = false
			spark.Material    = Enum.Material.Neon
			spark.Color       = color
			spark.Transparency = 0
			spark.Parent      = folder
			local bv = Instance.new("BodyVelocity")
			bv.Velocity  = Vector3.new(math.random(-6,6), math.random(4,12), math.random(-6,6)) * size
			bv.MaxForce  = Vector3.new(1e5,1e5,1e5)
			bv.Parent    = spark
			TweenService:Create(spark,
				TweenInfo.new(0.7, Enum.EasingStyle.Quad),
				{ Transparency = 1, Size = Vector3.new(0.05,0.05,0.05) }
			):Play()
			game:GetService("Debris"):AddItem(spark, 0.8)
		end

	elseif style == "Ghost" then
		local ghost = Instance.new("Part")
		ghost.Shape       = Enum.PartType.Ball
		ghost.Size        = Vector3.new(2, 2, 2) * size
		ghost.CFrame      = CFrame.new(position)
		ghost.Anchored    = true
		ghost.CanCollide  = false
		ghost.CanQuery    = false
		ghost.CanTouch    = false
		ghost.Material    = Enum.Material.Neon
		ghost.Color       = color
		ghost.Transparency = 0.4
		ghost.Parent      = folder
		TweenService:Create(ghost,
			TweenInfo.new(1.5, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
			{ Size = Vector3.new(6,6,6) * size, Transparency = 1,
			  CFrame = ghost.CFrame + Vector3.new(0, 5 * size, 0) }
		):Play()
		game:GetService("Debris"):AddItem(ghost, 1.6)
	end
end

local killFXConn
local watchedChars = {}

local function watchCharacter(char)
	if watchedChars[char] then return end
	watchedChars[char] = true
	local human = char:FindFirstChildOfClass("Humanoid")
		or char:WaitForChild("Humanoid", 5)
	if not human then return end
	if char == LocalPlayer.Character then return end
	human.Died:Connect(function()
		if not killSettings.Enabled then return end
		local root = char:FindFirstChild("HumanoidRootPart")
		local pos  = root and root.Position or Vector3.new(0, 0, 0)
		spawnKillEffect(pos)
	end)
end

local function startKillFXWatch()
	if killFXConn then return end
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer and player.Character then
			task.spawn(watchCharacter, player.Character)
		end
		player.CharacterAdded:Connect(function(char)
			task.wait(0.3)
			watchCharacter(char)
		end)
	end
	killFXConn = Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function(char)
			task.wait(0.3)
			watchCharacter(char)
		end)
	end)
end

local function stopKillFXWatch()
	if killFXConn then
		killFXConn:Disconnect()
		killFXConn = nil
	end
	watchedChars = {}
end

function KillFX.SetEnabled(enabled)
	killSettings.Enabled = enabled and true or false
	if killSettings.Enabled then
		startKillFXWatch()
	else
		stopKillFXWatch()
	end
end


--======================================================================--
--======================================================================--

local shared = odh_shared_plugins

local function notify(text, duration)
    pcall(function()
        shared.Notify(tostring(text), duration or 2)
    end)
end

local creditSection = shared.AddSection('Anya BTS')
creditSection:AddLabel('Credits: @anya_bts')

local jumpSection = shared.AddSection('Jump Effects')
jumpSection:AddToggle('Enable jump effects', function(value)
    Visuals.SetJump(value)
end)
jumpSection:AddDropdown('Style', Visuals.JumpStyles, function(value)
    vis.Jump.Style = value
end)
jumpSection:AddColorpicker('Color', vis.Jump.Color, function(color)
    vis.Jump.Color = color
end)
jumpSection:AddSlider('Size', 3, 20, vis.Jump.Size, function(value)
    vis.Jump.Size = value
end)
jumpSection:AddSlider('Duration x10', 3, 20, math.floor(vis.Jump.Duration * 10 + 0.5), function(value)
    vis.Jump.Duration = value / 10
end)
jumpSection:AddToggle('Ground flash', function(value)
    vis.Jump.Flash = value
end)
jumpSection:AddToggle('Sparks', function(value)
    vis.Jump.Sparks = value
end)

local wingsSection = shared.AddSection('Wings')
wingsSection:AddToggle('Enable wings', function(value)
    Visuals.SetWings(value)
end)
wingsSection:AddDropdown('Style', Visuals.WingStyles, function(value)
    vis.Wings.Style = value
    Visuals.RebuildWings()
end)
wingsSection:AddColorpicker('Color', vis.Wings.Color, function(color)
    vis.Wings.Color = color
    Visuals.RebuildWings()
end)
wingsSection:AddSlider('Size x10', 5, 20, math.floor(vis.Wings.Scale * 10 + 0.5), function(value)
    vis.Wings.Scale = value / 10
    Visuals.RebuildWings()
end)
wingsSection:AddSlider('Droop', 0, 35, 0, function(value)
    vis.Wings.Droop = value
    Visuals.RebuildWings()
end)
wingsSection:AddToggle('Flapping', function(value)
    vis.Wings.Flap = value
end)
wingsSection:AddToggle('Glow', function(value)
    vis.Wings.Glow = value
    Visuals.RebuildWings()
end)

local haloSection = shared.AddSection('Halo')
haloSection:AddToggle('Enable halo', function(value)
    Visuals.SetHalo(value)
end)
haloSection:AddDropdown('Style', Visuals.HaloStyles, function(value)
    vis.Halo.Style = value
    Visuals.RebuildHalo()
end)
haloSection:AddColorpicker('Color', vis.Halo.Color, function(color)
    vis.Halo.Color = color
    Visuals.RebuildHalo()
end)
haloSection:AddSlider('Speed x10', 0, 40, math.floor(vis.Halo.Speed * 10 + 0.5), function(value)
    vis.Halo.Speed = value / 10
end)
haloSection:AddToggle('Glow', function(value)
    vis.Halo.Glow = value
    Visuals.RebuildHalo()
end)

local hatSection = shared.AddSection('China Hat')
hatSection:AddToggle('Enable hat', function(value)
    Visuals.SetChinaHat(value)
end)
hatSection:AddDropdown('Style', Visuals.HatStyles, function(value)
    vis.ChinaHat.Style = value
    Visuals.RebuildChinaHat()
end)
hatSection:AddColorpicker('Color', vis.ChinaHat.Color, function(color)
    vis.ChinaHat.Color = color
    Visuals.RebuildChinaHat()
end)
hatSection:AddSlider('Size x10', 5, 25, math.floor(vis.ChinaHat.Size * 10 + 0.5), function(value)
    vis.ChinaHat.Size = value / 10
    Visuals.RebuildChinaHat()
end)
hatSection:AddSlider('Rotation x10', 0, 40, math.floor(vis.ChinaHat.Spin * 10 + 0.5), function(value)
    vis.ChinaHat.Spin = value / 10
end)
hatSection:AddToggle('Glow', function(value)
    vis.ChinaHat.Glow = value
    Visuals.RebuildChinaHat()
end)


--======================================================================--
--                         VISUAL EXTRAS                                --
--======================================================================--

local ForceFieldSettings = {
    Enabled = false,
    Color = Color3.fromRGB(128, 128, 128),
    Original = {},
    Connection = nil,
}

local function forceFieldSaveOriginal(char)
    ForceFieldSettings.Original[char] = {}
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA('BasePart') and part.Name ~= 'ChineseHat' then
            ForceFieldSettings.Original[char][part] = {
                Color = part.Color,
                Material = part.Material,
            }
        end
    end
end

local function forceFieldApply(char)
    forceFieldSaveOriginal(char)
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA('BasePart') and part.Name ~= 'ChineseHat' then
            part.Color = ForceFieldSettings.Color
            part.Material = Enum.Material.ForceField
        end
    end
end

local function forceFieldRemove(char)
    local saved = ForceFieldSettings.Original[char]
    if not saved then return end
    for part, data in pairs(saved) do
        if part and part.Parent then
            part.Color = data.Color
            part.Material = data.Material
        end
    end
    ForceFieldSettings.Original[char] = nil
end

local function forceFieldUpdate()
    if not ForceFieldSettings.Enabled or not LocalPlayer.Character then return end
    for _, part in ipairs(LocalPlayer.Character:GetDescendants()) do
        if part:IsA('BasePart') and part.Name ~= 'ChineseHat' and part.Material == Enum.Material.ForceField then
            part.Color = ForceFieldSettings.Color
        end
    end
end

local function setForceField(enabled)
    ForceFieldSettings.Enabled = enabled == true
    if ForceFieldSettings.Connection then
        ForceFieldSettings.Connection:Disconnect()
        ForceFieldSettings.Connection = nil
    end
    if ForceFieldSettings.Enabled and LocalPlayer.Character then
        forceFieldApply(LocalPlayer.Character)
        ForceFieldSettings.Connection = RunService.Heartbeat:Connect(forceFieldUpdate)
    elseif LocalPlayer.Character then
        forceFieldRemove(LocalPlayer.Character)
    end
end

local AuraTrailerSettings = {
    Enabled = false,
    Color = Color3.fromRGB(255, 0, 0),
    Lifetime = 0.5,
}

local function removeAuraTrailer(char)
    if not char then return end
    for _, obj in ipairs(char:GetDescendants()) do
        if obj:IsA('Trail') and obj.Name == 'AnyaBTS_AuraTrailer' then
            obj:Destroy()
        elseif obj:IsA('Attachment') and (obj.Name == 'AnyaBTS_AuraPointer0' or obj.Name == 'AnyaBTS_AuraPointer1') then
            obj:Destroy()
        end
    end
end

local function applyAuraTrailer(char)
    removeAuraTrailer(char)
    local hrp = char and char:FindFirstChild('HumanoidRootPart')
    if not hrp then return end
    for _, part in ipairs(char:GetChildren()) do
        if part:IsA('BasePart') and part ~= hrp then
            local a0 = Instance.new('Attachment')
            a0.Name = 'AnyaBTS_AuraPointer0'
            a0.Parent = part
            local a1 = Instance.new('Attachment')
            a1.Name = 'AnyaBTS_AuraPointer1'
            a1.Parent = hrp
            local trail = Instance.new('Trail')
            trail.Name = 'AnyaBTS_AuraTrailer'
            trail.Texture = 'rbxassetid://1390780157'
            trail.Attachment0 = a0
            trail.Attachment1 = a1
            trail.Color = ColorSequence.new(AuraTrailerSettings.Color)
            trail.Lifetime = AuraTrailerSettings.Lifetime
            trail.LightEmission = 1
            trail.Parent = part
        end
    end
end

local function updateAuraTrailer()
    if not AuraTrailerSettings.Enabled or not LocalPlayer.Character then return end
    for _, obj in ipairs(LocalPlayer.Character:GetDescendants()) do
        if obj:IsA('Trail') and obj.Name == 'AnyaBTS_AuraTrailer' then
            obj.Color = ColorSequence.new(AuraTrailerSettings.Color)
            obj.Lifetime = AuraTrailerSettings.Lifetime
        end
    end
end

local function setAuraTrailer(enabled)
    AuraTrailerSettings.Enabled = enabled == true
    if AuraTrailerSettings.Enabled then
        applyAuraTrailer(LocalPlayer.Character)
    else
        removeAuraTrailer(LocalPlayer.Character)
    end
end

local ParticleAuraData = {
    { 'Starlight', 'rbxassetid://134645216613107' },
    { 'Heavenly', 'rbxassetid://139300897520961' },
    { 'Ribbon', 'rbxassetid://132069507632161' },
    { 'Sakura', 'rbxassetid://81755778619404' },
    { 'Angel', 'rbxassetid://97658130917593' },
    { 'Wind', 'rbxassetid://80694081850877' },
    { 'Flow', 'rbxassetid://119913533725648' },
    { 'Star', 'rbxassetid://73754563740680' },
    { 'Neon', 'rbxassetid://18498709246' },
}
local ParticleAuraNames = {}
local ParticleAuraIds = {}
for _, row in ipairs(ParticleAuraData) do
    table.insert(ParticleAuraNames, row[1])
    ParticleAuraIds[row[1]] = row[2]
end
local ParticleAuraSettings = {
    Enabled = false,
    Color = Color3.fromRGB(133, 220, 255),
    Selected = {},
    Active = {},
    Cache = {},
}

local function particleAuraDisable(name)
    if ParticleAuraSettings.Active[name] then
        for _, obj in ipairs(ParticleAuraSettings.Active[name]) do
            pcall(function() obj:Destroy() end)
        end
        ParticleAuraSettings.Active[name] = nil
    end
end

local function particleAuraTemplate(name)
    if ParticleAuraSettings.Cache[name] then return ParticleAuraSettings.Cache[name] end
    local id = ParticleAuraIds[name]
    if not id then return nil end
    local ok, obj = pcall(function() return game:GetObjects(id)[1] end)
    if ok and obj then
        ParticleAuraSettings.Cache[name] = obj
        return obj
    end
    return nil
end

local function particleTint(root, color)
    local seq = ColorSequence.new(color)
    local function apply(obj)
        if obj:IsA('ParticleEmitter') or obj:IsA('Beam') or obj:IsA('Trail') then
            obj.Color = seq
        elseif obj:IsA('PointLight') then
            obj.Color = color
        end
    end
    pcall(apply, root)
    for _, obj in ipairs(root:GetDescendants()) do pcall(apply, obj) end
end

local function particleAuraApply(name)
    local char = LocalPlayer.Character
    local template = particleAuraTemplate(name)
    if not char or not template then return {} end
    local partMap = {}
    for _, part in ipairs(char:GetChildren()) do
        if part:IsA('BasePart') then partMap[part.Name] = part end
    end
    local clone = template:Clone()
    local created = {}
    for _, sourcePart in ipairs(clone:GetChildren()) do
        local target = partMap[sourcePart.Name]
        if target then
            for _, child in ipairs(sourcePart:GetChildren()) do
                local ok, inst = pcall(function() return child:Clone() end)
                if ok and inst then
                    inst.Name = 'AnyaBTS_ParticleAura'
                    inst.Parent = target
                    particleTint(inst, ParticleAuraSettings.Color)
                    table.insert(created, inst)
                end
            end
        end
    end
    clone:Destroy()
    return created
end

local function refreshParticleAura()
    for _, name in ipairs(ParticleAuraNames) do particleAuraDisable(name) end
    if not ParticleAuraSettings.Enabled then return end
    for name, selected in pairs(ParticleAuraSettings.Selected) do
        if selected then
            task.spawn(function()
                ParticleAuraSettings.Active[name] = particleAuraApply(name)
            end)
        end
    end
end

local FootprintSettings = {
    Enabled = false,
    Color = Color3.fromRGB(0, 255, 255),
    Lifetime = 2,
    StepDistance = 3,
    FootOffset = 0.7,
    Mode = 'Fade',
}
local FootprintModes = { 'Fade', 'Dissolve', 'Float Up', 'Shrink' }
local footprintConnection
local footprintLastPosition
local footprintLeft = true

local function animateFootprint(footprint, light, mode)
    local lifetime = FootprintSettings.Lifetime
    if mode == 'Dissolve' then
        local originalSize = footprint.Size
        local originalPos = footprint.Position
        task.spawn(function()
            for i = 1, 20 do
                task.wait(lifetime / 20)
                local progress = i / 20
                if not footprint.Parent then return end
                footprint.Size = originalSize * (1 - progress)
                footprint.Position = originalPos + Vector3.new((math.random() - 0.5) * progress * 0.5, 0, (math.random() - 0.5) * progress * 0.5)
                footprint.Transparency = 0.2 + progress * 0.8
                light.Brightness = math.max(0, 1.5 * (1 - progress))
            end
            footprint:Destroy()
        end)
    elseif mode == 'Float Up' then
        local tween = TweenService:Create(footprint, TweenInfo.new(lifetime, Enum.EasingStyle.Quad), { CFrame = footprint.CFrame + Vector3.new(0, 4, 0), Transparency = 1 })
        local lightTween = TweenService:Create(light, TweenInfo.new(lifetime), { Brightness = 0 })
        tween:Play(); lightTween:Play()
        tween.Completed:Connect(function() if footprint.Parent then footprint:Destroy() end end)
    elseif mode == 'Shrink' then
        local tween = TweenService:Create(footprint, TweenInfo.new(lifetime, Enum.EasingStyle.Back, Enum.EasingDirection.In), { Size = Vector3.new(0.01, 0.01, 0.01), Transparency = 1 })
        local lightTween = TweenService:Create(light, TweenInfo.new(lifetime), { Brightness = 0 })
        tween:Play(); lightTween:Play()
        tween.Completed:Connect(function() if footprint.Parent then footprint:Destroy() end end)
    else
        local tween = TweenService:Create(footprint, TweenInfo.new(lifetime), { Transparency = 1 })
        local lightTween = TweenService:Create(light, TweenInfo.new(lifetime), { Brightness = 0 })
        tween:Play(); lightTween:Play()
        tween.Completed:Connect(function() if footprint.Parent then footprint:Destroy() end end)
    end
end

local function createFootprint(position, lookVector)
    local footprint = Instance.new('Part')
    footprint.Name = 'AnyaBTS_Footprint'
    footprint.Size = Vector3.new(0.6, 0.1, 1)
    footprint.Anchored = true
    footprint.CanCollide = false
    footprint.CanQuery = false
    footprint.CanTouch = false
    footprint.Material = Enum.Material.Neon
    footprint.Color = FootprintSettings.Color
    footprint.Transparency = 0.2
    footprint.CFrame = CFrame.new(position, position + lookVector) + Vector3.new(0, 0.05, 0)
    footprint.Parent = ensureFolder()
    local light = Instance.new('PointLight')
    light.Color = FootprintSettings.Color
    light.Range = 4
    light.Brightness = 1.5
    light.Parent = footprint
    animateFootprint(footprint, light, FootprintSettings.Mode)
end

local function updateFootprints()
    local char = LocalPlayer.Character
    local humanoid = char and char:FindFirstChildOfClass('Humanoid')
    local root = char and char:FindFirstChild('HumanoidRootPart')
    if not humanoid or not root then return end
    footprintLastPosition = footprintLastPosition or root.Position
    if humanoid.MoveDirection.Magnitude <= 0 or humanoid:GetState() == Enum.HumanoidStateType.Freefall then
        footprintLastPosition = root.Position
        return
    end
    local currentPos = root.Position
    if (currentPos - footprintLastPosition).Magnitude >= FootprintSettings.StepDistance then
        local sideOffset = root.CFrame.RightVector * (footprintLeft and -FootprintSettings.FootOffset or FootprintSettings.FootOffset)
        local footPos = Vector3.new(currentPos.X, currentPos.Y - 3, currentPos.Z) + sideOffset
        createFootprint(footPos, root.CFrame.LookVector)
        footprintLeft = not footprintLeft
        footprintLastPosition = currentPos
    end
end

local function setFootprints(enabled)
    FootprintSettings.Enabled = enabled == true
    if footprintConnection then
        footprintConnection:Disconnect()
        footprintConnection = nil
    end
    if FootprintSettings.Enabled then
        footprintLastPosition = nil
        footprintConnection = RunService.Heartbeat:Connect(updateFootprints)
    end
end

local graphicsSection = shared.AddSection('Graphics')
graphicsSection:AddLabel('Device: ' .. DEVICE_CATEGORY)
graphicsSection:AddLabel('Current quality: ' .. string.format('%.2f', QUALITY))
graphicsSection:AddDropdown('Quality Override', {'Auto', '0.4', '0.5', '0.6', '0.75', '0.85', '1.0'}, function(value)
    if value == 'Auto' then
        pcall(function() LocalPlayer:SetAttribute('QualityOverride', nil) end)
        QUALITY = detectBaseQuality()
    else
        setQualityOverride(tonumber(value))
    end
end)

local extrasSection = shared.AddSection('Visual Extras')
extrasSection:AddToggle('Forcefield', function(value) setForceField(value) end)
extrasSection:AddColorpicker('Forcefield Color', ForceFieldSettings.Color, function(color)
    ForceFieldSettings.Color = color
    forceFieldUpdate()
end)
extrasSection:AddToggle('Aura trailer', function(value) setAuraTrailer(value) end)
extrasSection:AddColorpicker('Aura trailer Color', AuraTrailerSettings.Color, function(color)
    AuraTrailerSettings.Color = color
    updateAuraTrailer()
end)
extrasSection:AddSlider('Aura trailer Lifetime x10', 1, 30, 5, function(value)
    AuraTrailerSettings.Lifetime = value / 10
    updateAuraTrailer()
end)
extrasSection:AddToggle('Particle aura', function(value)
    ParticleAuraSettings.Enabled = value
    refreshParticleAura()
end)
extrasSection:AddDropdown('Particle aura Style', ParticleAuraNames, function(value)
    ParticleAuraSettings.Selected = {}
    ParticleAuraSettings.Selected[value] = true
    refreshParticleAura()
end)
extrasSection:AddColorpicker('Particle aura Color', ParticleAuraSettings.Color, function(color)
    ParticleAuraSettings.Color = color
    refreshParticleAura()
end)
extrasSection:AddToggle('Footprints', function(value) setFootprints(value) end)
extrasSection:AddDropdown('Footprint Mode', FootprintModes, function(value)
    FootprintSettings.Mode = value
end)
extrasSection:AddColorpicker('Footprint Color', FootprintSettings.Color, function(color)
    FootprintSettings.Color = color
end)
extrasSection:AddSlider('Footprint Lifetime x10', 5, 50, 20, function(value)
    FootprintSettings.Lifetime = value / 10
end)
extrasSection:AddSlider('Step Distance x10', 10, 60, 30, function(value)
    FootprintSettings.StepDistance = value / 10
end)
extrasSection:AddSlider('Foot Offset x10', 0, 15, 7, function(value)
    FootprintSettings.FootOffset = value / 10
end)

local skySection = shared.AddSection('Sky')
skySection:AddDropdown('Preset', Visuals.GetSkies(), function(value)
    Visuals.ApplySky(value)
    notify('Sky: ' .. value, 2)
end)
skySection:AddSlider('Brightness x10', 0, 50, 20, function(value)
    saveLighting()
    pcall(function()
        Lighting.Brightness = value / 10
    end)
end)
skySection:AddSlider('Exposure x10', -10, 10, 0, function(value)
    saveLighting()
    pcall(function()
        Lighting.ExposureCompensation = value / 10
    end)
end)
skySection:AddButton('Restore original lighting', function()
    Visuals.RestoreSky()
    notify('Original lighting restored', 2)
end)
skySection:AddLabel('Lighting changes are client side only')

local trailSection = shared.AddSection('Trails')
trailSection:AddToggle('Enable trails', function(value)
    Trails.SetEnabled(value)
end)
trailSection:AddDropdown('Style', Trails.Styles, function(value)
    trailSettings.Style = value
    Trails.Rebuild()
end)
trailSection:AddColorpicker('Color 1', trailSettings.Color, function(color)
    trailSettings.Color = color
    Trails.Rebuild()
end)
trailSection:AddColorpicker('Color 2', trailSettings.Color2, function(color)
    trailSettings.Color2 = color
    Trails.Rebuild()
end)
trailSection:AddSlider('Width x10', 5, 50, math.floor(trailSettings.Width * 10 + 0.5), function(value)
    trailSettings.Width = value / 10
    Trails.Rebuild()
end)
trailSection:AddSlider('Lifetime x10', 1, 20, math.floor(trailSettings.Lifetime * 10 + 0.5), function(value)
    trailSettings.Lifetime = value / 10
    Trails.Rebuild()
end)
trailSection:AddToggle('Rainbow', function(value)
    trailSettings.Rainbow = value
    Trails.Rebuild()
end)

local killSection = shared.AddSection('MM2 Kill Effects')
killSection:AddToggle('Enable kill effects', function(value)
    KillFX.SetEnabled(value)
end)
killSection:AddDropdown('Style', KillFX.Styles, function(value)
    killSettings.Style = value
end)
killSection:AddColorpicker('Color', killSettings.Color, function(color)
    killSettings.Color = color
end)
killSection:AddSlider('Size x10', 5, 30, math.floor(killSettings.Size * 10 + 0.5), function(value)
    killSettings.Size = value / 10
end)

LocalPlayer.CharacterAdded:Connect(function(char)
    task.wait(0.25)
    if ForceFieldSettings.Enabled then
        forceFieldApply(char)
        if ForceFieldSettings.Connection then ForceFieldSettings.Connection:Disconnect() end
        ForceFieldSettings.Connection = RunService.Heartbeat:Connect(forceFieldUpdate)
    end
    if AuraTrailerSettings.Enabled then applyAuraTrailer(char) end
    if ParticleAuraSettings.Enabled then refreshParticleAura() end
    if FootprintSettings.Enabled then footprintLastPosition = nil end
end)

notify('Visuals loaded', 2)

