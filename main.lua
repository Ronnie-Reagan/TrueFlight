local q = require("quat")
local vector3 = require("vector3")
local love = require "love" -- avoids nil report from intellisense, safe to remove if causes issues (it should be OK)
local enet = require "enet"
local engine = require "engine"
local networking = require "networking"
local renderer = require "gpu_renderer"
local logger = require "logger"
local hostAddy = "ecosim.donreagan.ca:1988"
local relay = enet.host_create()
local relayServer = relay and relay:connect(hostAddy) or nil
local flightSimMode = false
local relative = true
local peers = {}
local event = nil
local objects = require "object"
local cubeModel = objects.cubeModel
local screen, camera, groundObject, triangleCount, frameImage, renderMode, gpuErrorLogged --, zBuffer
local useGpuRenderer = true
local perfElapsed, perfFrames, perfLoggedLowFps = 0, 0, false
local zBuffer = {}
local mouseSensitivity = 0.001
local pauseTitleFont, pauseItemFont

local pauseMenu = {
	active = false,
	selected = 1,
	itemBounds = {},
	items = {
		{ id = "resume", label = "Resume", kind = "action" },
		{ id = "flight", label = "Flight Mode", kind = "toggle" },
		{ id = "renderer", label = "Renderer", kind = "toggle" },
		{ id = "speed", label = "Move Speed", kind = "range", min = 2, max = 30, step = 1 },
		{ id = "fov", label = "Field of View", kind = "range", min = 60, max = 120, step = 5 },
		{ id = "sensitivity", label = "Mouse Sensitivity", kind = "range", min = 0.0004, max = 0.004, step = 0.0002 },
		{ id = "reset", label = "Reset Camera", kind = "action" },
		{ id = "reconnect", label = "Reconnect Relay", kind = "action" },
		{ id = "quit", label = "Quit Game", kind = "action" }
	}
}

--[[
Notes:

positions are {x = left/right(width), y = up/down(height), z = in/out(depth)} IN WORLD SPACE!!
]]
-- Procedurally generate a ground grid of cubes
local function generateGround(tileSize, gridCount, baseHeight)
	local tiles = {}
	local half = tileSize / 2

	for x = -gridCount / 2, gridCount / 2 - 1 do
		for z = -gridCount / 2, gridCount / 2 - 1 do
			local posX = x * tileSize + half
			local posZ = z * tileSize + half
			-- small color variation for realism
			local r = 0.2 + math.random() * 0.05
			local g = 0.6 + math.random() * 0.1
			local b = 0.2 + math.random() * 0.05

			table.insert(tiles, {
				model = cubeModel,
				pos = { posX, baseHeight, posZ },
				rot = q.identity(),
				color = { r, g, b },
				isSolid = true,
				halfSize = { x = tileSize / 2, y = 0.005, z = tileSize / 2 } -- thin tile
			})
		end
	end

	return tiles
end

local function clamp(value, minValue, maxValue)
	if value < minValue then
		return minValue
	end
	if value > maxValue then
		return maxValue
	end
	return value
end

local function setMouseCapture(enabled)
	love.mouse.setRelativeMode(enabled)
	pcall(love.mouse.setVisible, not enabled)
	relative = enabled
end

local function setFlightMode(enabled)
	flightSimMode = enabled and true or false
	if not flightSimMode and camera then
		camera.throttle = 0
	end
end

local function setRendererPreference(enableGpu)
	local desiredGpu = enableGpu and true or false
	if desiredGpu and not renderer.isReady() then
		useGpuRenderer = false
		renderMode = "CPU"
		logger.log("GPU renderer unavailable; staying in CPU mode.")
		return false
	end

	local oldMode = renderMode
	useGpuRenderer = desiredGpu
	renderMode = (useGpuRenderer and renderer.isReady()) and "GPU" or "CPU"
	if oldMode ~= renderMode then
		logger.log("Render mode toggled to " .. renderMode)
	end
	return useGpuRenderer
end

local function resetCameraTransform()
	if not camera then
		return
	end

	camera.pos = { 0, 0, -5 }
	camera.rot = q.identity()
	camera.vel = { 0, 0, 0 }
	camera.throttle = 0
	camera.onGround = false
	if camera.box and camera.box.halfSize then
		camera.box.pos = { camera.pos[1], camera.pos[2] - camera.box.halfSize.y, camera.pos[3] }
	end
	logger.log("Camera transform reset.")
end

local function clearPeerObjects()
	for i = #objects, 1, -1 do
		if objects[i].id then
			table.remove(objects, i)
		end
	end
	peers = {}
end

local function getRelayStatus()
	if not relay then
		return "Host down"
	end
	if not relayServer then
		return "Disconnected"
	end

	local ok, state = pcall(function()
		return relayServer:state()
	end)
	if not ok then
		return "Unknown"
	end
	if state == "connected" then
		return "Connected"
	end
	return tostring(state)
end

local function reconnectRelay()
	if not relay then
		relay = enet.host_create()
		if not relay then
			logger.log("ENet host creation failed; reconnect unavailable.")
			return false
		end
	end

	if relayServer then
		pcall(function()
			relayServer:disconnect_now()
		end)
		relayServer = nil
	end

	clearPeerObjects()

	local ok, peerOrErr = pcall(function()
		return relay:connect(hostAddy)
	end)
	if not ok then
		logger.log("Relay reconnect failed: " .. tostring(peerOrErr))
		return false
	end

	relayServer = peerOrErr
	if relayServer then
		logger.log("Reconnecting to relay server: " .. hostAddy)
		return true
	end

	logger.log("Relay reconnect failed: no peer handle returned.")
	return false
end

local function refreshUiFonts()
	local baseSize = math.max(14, math.floor(screen.h * 0.023))
	pauseTitleFont = love.graphics.newFont(math.max(24, baseSize + 8))
	pauseItemFont = love.graphics.newFont(baseSize)
end

local setPauseState

local function getPauseItemValue(item)
	if item.id == "flight" then
		return flightSimMode and "On" or "Off"
	end
	if item.id == "renderer" then
		if renderer.isReady() then
			return useGpuRenderer and "GPU" or "CPU"
		end
		return "CPU (GPU unavailable)"
	end
	if item.id == "speed" and camera then
		return string.format("%.1f", camera.speed)
	end
	if item.id == "fov" and camera then
		local fovDeg = math.deg(camera.fov)
		return string.format("%d deg", math.floor(fovDeg + 0.5))
	end
	if item.id == "sensitivity" then
		return string.format("%.4f", mouseSensitivity)
	end
	if item.id == "reconnect" then
		return getRelayStatus()
	end
	return ""
end

local function adjustPauseItem(item, direction)
	if direction == 0 then
		return
	end

	if item.id == "speed" and camera then
		camera.speed = clamp(camera.speed + item.step * direction, item.min, item.max)
		return
	end

	if item.id == "fov" and camera then
		local fovDeg = math.deg(camera.fov)
		fovDeg = clamp(fovDeg + item.step * direction, item.min, item.max)
		camera.fov = math.rad(fovDeg)
		return
	end

	if item.id == "sensitivity" then
		local nextValue = clamp(mouseSensitivity + item.step * direction, item.min, item.max)
		mouseSensitivity = math.floor(nextValue * 10000 + 0.5) / 10000
	end
end

local function activatePauseItem(item)
	if item.kind == "range" then
		adjustPauseItem(item, 1)
		return
	end

	if item.id == "resume" then
		setPauseState(false)
	elseif item.id == "flight" then
		setFlightMode(not flightSimMode)
	elseif item.id == "renderer" then
		setRendererPreference(not useGpuRenderer)
	elseif item.id == "reset" then
		resetCameraTransform()
	elseif item.id == "reconnect" then
		reconnectRelay()
	elseif item.id == "quit" then
		love.event.quit()
	end
end

local function movePauseSelection(delta)
	local itemCount = #pauseMenu.items
	pauseMenu.selected = ((pauseMenu.selected - 1 + delta) % itemCount) + 1
end

local function adjustSelectedPauseItem(direction)
	local item = pauseMenu.items[pauseMenu.selected]
	if not item then
		return
	end
	if item.kind == "range" then
		adjustPauseItem(item, direction)
	elseif item.kind == "toggle" and direction ~= 0 then
		activatePauseItem(item)
	end
end

local function activateSelectedPauseItem()
	local item = pauseMenu.items[pauseMenu.selected]
	if item then
		activatePauseItem(item)
	end
end

local function handlePauseMenuMouseClick(x, y)
	for i, bounds in ipairs(pauseMenu.itemBounds) do
		if x >= bounds.x and x <= bounds.x + bounds.w and y >= bounds.y and y <= bounds.y + bounds.h then
			pauseMenu.selected = i
			local item = pauseMenu.items[i]
			if item and item.kind == "range" then
				local direction = (x >= (bounds.x + bounds.w * 0.5)) and 1 or -1
				adjustPauseItem(item, direction)
			elseif item then
				activatePauseItem(item)
			end
			return
		end
	end
end

setPauseState = function(paused)
	if pauseMenu.active == paused then
		return
	end

	pauseMenu.active = paused and true or false
	if pauseMenu.active then
		pauseMenu.selected = 1
		pauseMenu.itemBounds = {}
		setMouseCapture(false)
		logger.log("Pause menu opened.")
	else
		setMouseCapture(true)
		logger.log("Pause menu closed.")
	end
end

local function drawPauseMenu()
	local rowH = math.max(28, math.min(40, math.floor((screen.h - 190) / #pauseMenu.items)))
	local topPad = 56
	local bottomPad = 28
	local panelW = math.min(560, screen.w * 0.82)
	local panelH = topPad + #pauseMenu.items * rowH + bottomPad
	local panelX = (screen.w - panelW) / 2
	local panelY = (screen.h - panelH) / 2
	local rowX = panelX + 18
	local rowW = panelW - 36

	love.graphics.setColor(0, 0, 0, 0.68)
	love.graphics.rectangle("fill", 0, 0, screen.w, screen.h)

	love.graphics.setColor(0.08, 0.08, 0.1, 0.95)
	love.graphics.rectangle("fill", panelX, panelY, panelW, panelH, 8, 8)
	love.graphics.setColor(1, 1, 1, 0.2)
	love.graphics.rectangle("line", panelX, panelY, panelW, panelH, 8, 8)

	local oldFont = love.graphics.getFont()
	if pauseTitleFont then
		love.graphics.setFont(pauseTitleFont)
	end
	love.graphics.setColor(1, 1, 1, 1)
	love.graphics.printf("PAUSED", panelX, panelY + 14, panelW, "center")

	if pauseItemFont then
		love.graphics.setFont(pauseItemFont)
	end

	pauseMenu.itemBounds = {}
	local rowTextHeight = love.graphics.getFont():getHeight()
	for i, item in ipairs(pauseMenu.items) do
		local rowY = panelY + topPad + (i - 1) * rowH
		local rowHeight = rowH - 4
		local rowTextY = rowY + math.floor((rowHeight - rowTextHeight) / 2)
		local selected = i == pauseMenu.selected
		local value = getPauseItemValue(item)

		if selected then
			love.graphics.setColor(0.22, 0.28, 0.42, 0.95)
		else
			love.graphics.setColor(0.15, 0.16, 0.2, 0.9)
		end
		love.graphics.rectangle("fill", rowX, rowY, rowW, rowHeight, 6, 6)

		love.graphics.setColor(1, 1, 1, 1)
		love.graphics.print(item.label, rowX + 12, rowTextY)
		if item.kind == "range" then
			value = "< " .. value .. " >"
		end
		if value ~= "" then
			love.graphics.printf(value, rowX + 12, rowTextY, rowW - 24, "right")
		end

		pauseMenu.itemBounds[i] = { x = rowX, y = rowY, w = rowW, h = rowHeight }
	end

	love.graphics.setColor(1, 1, 1, 0.85)
	love.graphics.printf(
		"Arrow keys / WASD to navigate, Enter to select, Left/Right to adjust, Esc to resume",
		panelX + 18,
		panelY + panelH - 22,
		panelW - 36,
		"center"
	)

	love.graphics.setFont(oldFont)
end

-- === Initial Configuration ===
function love.load()
	-- 80% screen size
	local width, height = love.window.getDesktopDimensions()
	width, height = math.floor(width * 0.8), math.floor(height * 0.8)

	love.window.setTitle("Don's 3D Engine")
	local modeOk, modeErr = love.window.setMode(width, height, { vsync = false, depth = 24 })
	if not modeOk then
		love.window.setMode(width, height, { vsync = false })
	end
	setMouseCapture(true)

	logger.reset()
	logger.log("Booting Don's 3D Engine")
	logger.log("Log file: " .. logger.getPath())
	if not modeOk then
		logger.log("Depth buffer mode unavailable, fallback mode set. Detail: " .. tostring(modeErr))
	end

	screen = {
		w = width,
		h = height
	}
	refreshUiFonts()

	camera = {
		pos = { 0, 0, -5 },
		rot = q.identity(),
		speed = 10,
		fov = math.rad(90),
		vel = { 0, 0, 0 }, -- current velocity
		onGround = false,  -- contacting
		gravity = -9.81,   -- units/sec^2
		jumpSpeed = 5,     -- initial jump
		throttle = 0,
		maxSpeed = 50,
		box = {
			halfSize = { x = 0.5, y = 1.8, z = 0.5 }, -- width/height/depth half extents
			pos = { 0, 0, -5 },                       -- center at camera
			isSolid = true
		}
	}

	renderMode = "CPU"
	gpuErrorLogged = false
	perfElapsed, perfFrames, perfLoggedLowFps = 0, 0, false
	pauseMenu.active = false
	pauseMenu.selected = 1
	pauseMenu.itemBounds = {}

	-- creating the cube's object
	-- disabled now that other players can join allowing for non-static testing of latency and culling/depth ordering
	objects = {
		[1] = {
			model = cubeModel,
			pos = { 0, 0, 10 },
			rot = q.identity(),
			color = { 0.9, 0.4, 0.1 },
			isSolid = true
		}
	}

	-- generate a 1000x1000 ground made of 10x10 tiles
	local tileSize = 2
	local gridCount = 10 -- 100 tiles per side -> 1000 units total
	local baseHeight = -0.1

	local groundTiles = generateGround(tileSize, gridCount, baseHeight)

	for _, tile in ipairs(groundTiles) do
		table.insert(objects, tile)
	end

	zBuffer = {}
	for i = 1, screen.w * screen.h do
		zBuffer[i] = math.huge
	end

	if not relay then
		logger.log("ENet host creation failed; multiplayer disabled for this session.")
	elseif not relayServer then
		logger.log("Could not connect to relay server at " .. hostAddy)
	else
		logger.log("Connected to relay server: " .. hostAddy)
	end

	local gpuOk, gpuErr = renderer.init(screen, camera, logger.log)
	if gpuOk then
		renderMode = "GPU"
		logger.log("GPU renderer enabled.")
	else
		useGpuRenderer = false
		renderMode = "CPU"
		logger.log("GPU renderer failed, using CPU fallback: " .. tostring(gpuErr))
	end
end

-- === Mouse Look ===
function love.mousemoved(x, y, dx, dy)
	if not relative then
		return
	end
	x, y, dx, dy = -x, -y, -dx, -dy

	-- Rotate around camera's local Y axis (yaw) and local X axis (pitch)
	local right = q.rotateVector(camera.rot, { 1, 0, 0 })
	local up = q.rotateVector(camera.rot, { 0, 1, 0 })

	local pitchQuat = q.fromAxisAngle(right, -dy * mouseSensitivity)
	local yawQuat = q.fromAxisAngle(up, -dx * mouseSensitivity)

	-- Apply pitch then yaw (relative to current orientation)
	camera.rot = q.normalize(q.multiply(yawQuat, q.multiply(pitchQuat, camera.rot)))
end

local function updateNet()
	local canSend = relayServer ~= nil
	if canSend then
		local ok, state = pcall(function()
			return relayServer:state()
		end)
		if ok and state == "disconnected" then
			canSend = false
		end
	end

	if canSend then
		local packet = string.format(
			"STATE|%f|%f|%f|%f|%f|%f|%f",
			camera.pos[1],
			camera.pos[2],
			camera.pos[3],
			camera.rot.w,
			camera.rot.x,
			camera.rot.y,
			camera.rot.z
		)
		pcall(function()
			relayServer:send(packet)
		end)
	end
end

local function serviceNetworkEvents()
	if not relay then
		return
	end

	event = relay:service()
	while event do
		if event.type == "receive" then
			networking.handlePacket(event.data, peers, objects, q)
		elseif event.type == "disconnect" and relayServer and event.peer == relayServer then
			relayServer = nil
			logger.log("Relay disconnected.")
		end

		event = relay:service()
	end
end

-- === Camera Movement ===
function love.update(dt)
	if not pauseMenu.active then
		camera = engine.processMovement(camera, dt, flightSimMode, vector3, q, objects)
		updateNet()

		perfElapsed = perfElapsed + dt
		perfFrames = perfFrames + 1
		if perfElapsed >= 2.0 then
			local avgFps = perfFrames / perfElapsed
			if useGpuRenderer and renderer.isReady() and avgFps < 100 and not perfLoggedLowFps then
				logger.log(string.format("FPS below 100 target in GPU mode (avg %.1f)", avgFps))
				perfLoggedLowFps = true
			elseif useGpuRenderer and renderer.isReady() and avgFps >= 100 then
				perfLoggedLowFps = false
			end
			perfElapsed = 0
			perfFrames = 0
		end
	end

	serviceNetworkEvents()
end

-- === Input Management ===
function love.keypressed(key)
	if key == "escape" then
		setPauseState(not pauseMenu.active)
		return
	end

	if pauseMenu.active then
		if key == "up" or key == "w" then
			movePauseSelection(-1)
		elseif key == "down" or key == "s" then
			movePauseSelection(1)
		elseif key == "left" or key == "a" then
			adjustSelectedPauseItem(-1)
		elseif key == "right" or key == "d" then
			adjustSelectedPauseItem(1)
		elseif key == "return" or key == "kpenter" or key == "space" then
			activateSelectedPauseItem()
		end
		return
	end

	-- debugging position/rotation and relating variables
	if key == "p" then
		local pos = camera.pos
		local rot = camera.rot
		local forward, right, up = engine.getCameraBasis(camera, q, vector3)

		print("\n=== Camera Debug Info ===")
		print(string.format("Position:    x=%.3f  y=%.3f  z=%.3f", pos[1], pos[2], pos[3]))
		print(string.format("Rotation:    w=%.5f  x=%.5f  y=%.5f  z=%.5f", rot.w, rot.x, rot.y, rot.z))
		print(string.format("Forward vec: x=%.3f  y=%.3f  z=%.3f", forward[1], forward[2], forward[3]))
		print(string.format("Right vec:   x=%.3f  y=%.3f  z=%.3f", right[1], right[2], right[3]))
		print(string.format("Up vec:      x=%.3f  y=%.3f  z=%.3f", up[1], up[2], up[3]))
	end

	if key == "f" then
		setFlightMode(not flightSimMode)
	end

	if key == "g" then
		setRendererPreference(not useGpuRenderer)
	end
end

function love.mousepressed(x, y, button)
	if pauseMenu.active then
		if button == 1 then
			handlePauseMenuMouseClick(x, y)
		end
		return
	end

	if not love.mouse.getRelativeMode() then
		setMouseCapture(true)
	end
end

function love.mousefocus(focused)
	if not focused then
		setMouseCapture(false)
	end
end

local function drawHud(w, h, cx, cy)
	-- to do: add bars on the bottom or left of the screen, white background rectangles, thinner coloured rectangle to indicate pos along the different axis with wrap around
end

function love.draw()
	triangleCount = 0
	local centerX, centerY = screen.w / 2, screen.h / 2

	local usedGpu = false
	if useGpuRenderer and renderer.isReady() then
		local ok, renderOk, triOrErr = pcall(renderer.drawWorld, objects, camera, { 0.2, 0.2, 0.75, 1.0 })
		if ok and renderOk then
			usedGpu = true
			renderMode = "GPU"
			triangleCount = triOrErr or 0
			gpuErrorLogged = false
		else
			if not gpuErrorLogged then
				logger.log("GPU draw failed; switching to CPU fallback. Detail: " ..
					tostring(ok and triOrErr or renderOk))
				gpuErrorLogged = true
			end
			renderMode = "CPU"
		end
	end

	if not usedGpu then
		love.graphics.setColor(0.2, 0.2, 0.75, 0.8)
		love.graphics.rectangle("fill", 0, 0, screen.w, screen.h)

		-- reset z-buffer
		for i = 1, screen.w * screen.h do
			zBuffer[i] = math.huge
		end

		local imageData = love.image.newImageData(screen.w, screen.h)
		for _, obj in ipairs(objects) do
			imageData = engine.drawObject(obj, false, camera, vector3, q, screen, zBuffer, imageData)
		end
		if frameImage then
			frameImage:replacePixels(imageData)
		else
			frameImage = love.graphics.newImage(imageData)
		end
		love.graphics.setColor(1, 1, 1, 1)
		love.graphics.draw(frameImage)
	end

	love.graphics.setColor(1, 1, 1)
	love.graphics.print(
		"WASD + Space (ground), F = flight mode, Q/E roll (flight), G = GPU toggle, Esc = pause menu\n" ..
		"Render: " .. tostring(renderMode) .. " | Triangles: " .. tostring(math.floor(triangleCount)) .. " | FPS: " ..
		love.timer.getFPS(),
		10,
		10
	)

	if not pauseMenu.active then
		love.graphics.setColor(1, 0, 0, 0.5)
		love.graphics.circle("fill", centerX, centerY, 1)
	end

	drawHud(screen.w, screen.h, centerX, centerY)

	if pauseMenu.active then
		drawPauseMenu()
	end
end

function love.resize(w, h)
	screen.w = w
	screen.h = h
	renderer.resize(screen)
	refreshUiFonts()

	zBuffer = {}
	for i = 1, screen.w * screen.h do
		zBuffer[i] = math.huge
	end

	frameImage = nil
	logger.log(string.format("Window resized to %dx%d", w, h))
end
