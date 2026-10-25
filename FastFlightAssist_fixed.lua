--[[
╔══════════════════════════════════════════════════════════════╗
║         FAST FLIGHT ASSIST — Steal a Egg (Roblox)           ║
║         Module version: 1.1.0 (state/connection fixes)                                ║
╠══════════════════════════════════════════════════════════════╣
║  ⚠ INTEGRATION NOTICE — ĐỌC TRƯỚC KHI DÙNG                 ║
║                                                              ║
║  Script chính (StealAnEggs.luau) là file obfuscated          ║
║  1.62 MB / 3 dòng — không thể đọc source.                   ║
║                                                              ║
║  Module dùng 4 lớp detection thay thế:                      ║
║  [A] _G namespace poll — nếu hub script expose biến          ║
║      _G.TargetEgg / _G.IsCollecting / _G.AutoStealing        ║
║  [B] Workspace scanner — tìm egg model trực tiếp             ║
║  [C] ProximityPrompt hook — bắt event collect tiêu chuẩn    ║
║  [D] Animation + Humanoid state monitor                      ║
║                                                              ║
║  Nếu _G.TargetEgg / _G.IsCollecting KHÔNG tồn tại           ║
║  sau khi script chính load, module tự dùng [B][C][D].        ║
║  Ghi log rõ ràng để bạn biết lớp nào đang hoạt động.        ║
╚══════════════════════════════════════════════════════════════╝
]]

-- ══════════════════════════════════════════════════════════
--  SERVICES
-- ══════════════════════════════════════════════════════════
local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")
local UserInputService  = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

-- ══════════════════════════════════════════════════════════
--  CONFIG — chỉnh tại đây
-- ══════════════════════════════════════════════════════════
local CFG = {
    -- Không tự tải script chính mặc định để tránh chạy trùng.
    -- Nếu bật true, chỉ bật khi CHƯA chạy script chính riêng.
    LOAD_MAIN_SCRIPT      = false,
    -- Tốc độ bay tối đa (studs/s)
    FLY_SPEED             = 120,
    -- Khoảng cách tính là "đã đến nơi"
    ARRIVE_RADIUS         = 4.5,
    -- Khoảng cách bắt đầu hãm tốc
    BRAKE_RADIUS          = 12,
    -- Khoảng cách tối đa tìm egg (studs)
    SCAN_RADIUS           = 500,
    -- Chu kỳ scan egg (giây)
    SCAN_INTERVAL         = 0.4,
    -- Timeout một lần di chuyển (giây)
    MOVE_TIMEOUT          = 30,
    -- Thời gian chờ sau khi collect xong để nhận target mới
    POST_COLLECT_COOLDOWN = 0.8,
    -- In log debug ra console
    DEBUG                 = true,
    -- Tên biến _G mà main script có thể expose
    G_TARGET_VAR          = "TargetEgg",     -- _G.TargetEgg  : BasePart | Vector3
    G_COLLECTING_VAR      = "IsCollecting",  -- _G.IsCollecting: boolean
    G_ACTIVE_VAR          = "AutoStealing",  -- _G.AutoStealing: boolean (hub on/off)
    -- Pattern tên model egg trong workspace (lowercase match)
    EGG_NAME_PATTERNS     = { "egg", "trung", "golden", "cosmic", "rare" },
    -- Animation id pattern cho collecting
    COLLECT_ANIM_PATTERNS = { "pickup", "collect", "steal", "grab", "carry" },
    -- Tag CollectionService trên egg (nếu game dùng)
    EGG_COLLECTION_TAGS   = { "Egg", "StealableEgg", "EggModel" },

    -- ── BỘ LỌC LOẠI TRỨNG ───────────────────────────────────
    -- Chỉ bay tới egg có tên / tên model cha / Attribute (dạng chuỗi) chứa
    -- một trong các từ dưới đây (không phân biệt hoa thường).
    -- Có cả "secret" lẫn "seret" phòng khi tên trong game viết khác nhau.
    TARGET_EGG_TYPES      = { "cosmic", "divine", "secret", "seret", "eternal" },
    -- false = tắt bộ lọc, bay tới mọi egg như bản gốc
    FILTER_ENABLED        = true,
    -- _G.TargetEgg dạng Vector3 không có tên để kiểm tra loại egg:
    -- false = bỏ qua (dùng workspace scan thay thế), true = vẫn bay tới
    ALLOW_VECTOR_G_TARGET = false,
}

-- ══════════════════════════════════════════════════════════
--  STATE MACHINE
-- ══════════════════════════════════════════════════════════
local STATE = {
    IDLE           = "Idle",
    MOVING         = "Moving",
    ARRIVED        = "Arrived",
    COLLECTING     = "Collecting",
    COMPLETED      = "Completed",
    ERROR          = "Error",
    EMERGENCY_STOP = "EmergencyStop",
}

-- Thứ tự ưu tiên: cao hơn = được phép ghi đè trạng thái thấp hơn
local STATE_PRIORITY = {
    [STATE.EMERGENCY_STOP] = 100,
    [STATE.COLLECTING]     = 80,
    [STATE.ARRIVED]        = 60,
    [STATE.MOVING]         = 40,
    [STATE.COMPLETED]      = 20,
    [STATE.ERROR]          = 10,
    [STATE.IDLE]           = 0,
}

-- ══════════════════════════════════════════════════════════
--  MODULE STATE
-- ══════════════════════════════════════════════════════════
local M = {
    state          = STATE.IDLE,
    target         = nil,          -- Vector3 | BasePart
    moveThread     = nil,          -- coroutine/task handle
    flyBodyVel     = nil,          -- LinearVelocity instance
    flyAttachment  = nil,          -- Attachment instance
    collecting     = false,        -- true khi đang collect
    lastError      = nil,
    taskMutex      = false,        -- ngăn concurrent move tasks
    integrationMode = nil,         -- "G_VARS" | "WORKSPACE" | "BOTH"
    gVarsDetected  = false,
    scanConn       = nil,          -- RenderStep connection
    proxConns      = {},           -- ProximityPrompt connections
    animConn       = nil,          -- animation monitor
    characterConn  = nil,
    heartbeatConn  = nil,
    active         = true,         -- module running
    arrivedAt      = nil,          -- timestamp used for non-blocking arrival grace period
}

-- ══════════════════════════════════════════════════════════
--  LOGGER
-- ══════════════════════════════════════════════════════════
local function log(msg, level)
    if not CFG.DEBUG and level ~= "WARN" and level ~= "ERROR" then return end
    local prefix = ("[FlightAssist][%s] "):format(level or "INFO")
    print(prefix .. tostring(msg))
end

-- ══════════════════════════════════════════════════════════
--  STATE TRANSITION
-- ══════════════════════════════════════════════════════════
local function setState(newState, reason)
    local current = M.state
    local curPrio = STATE_PRIORITY[current] or 0
    local newPrio = STATE_PRIORITY[newState] or 0

    -- EmergencyStop không thể bị ghi đè bởi bất kỳ trạng thái nào khác
    if current == STATE.EMERGENCY_STOP and newState ~= STATE.IDLE then
        return false
    end

    -- Collecting chỉ bị ghi đè bởi EmergencyStop
    if current == STATE.COLLECTING
        and newState ~= STATE.EMERGENCY_STOP
        and newState ~= STATE.COMPLETED
        and newState ~= STATE.IDLE then
        log("setState blocked: Collecting > " .. newState, "WARN")
        return false
    end

    M.state = newState
    log(("State: [%s] → [%s]%s"):format(
        current, newState, reason and (" (%s)"):format(reason) or ""
    ))
    return true
end

-- ══════════════════════════════════════════════════════════
--  CHARACTER HELPERS
-- ══════════════════════════════════════════════════════════
local function getChar()
    return LocalPlayer.Character
end

local function getHRP()
    local c = getChar()
    return c and c:FindFirstChild("HumanoidRootPart")
end

local function getHumanoid()
    local c = getChar()
    return c and c:FindFirstChildOfClass("Humanoid")
end

-- ══════════════════════════════════════════════════════════
--  FLY SYSTEM — LinearVelocity (modern, không deprecated)
-- ══════════════════════════════════════════════════════════
local function cleanupFly()
    if M.flyBodyVel then
        pcall(function() M.flyBodyVel:Destroy() end)
        M.flyBodyVel = nil
    end
    if M.flyAttachment then
        pcall(function() M.flyAttachment:Destroy() end)
        M.flyAttachment = nil
    end
end

local function setupFly(hrp)
    cleanupFly()
    local att = Instance.new("Attachment")
    att.Name = "FlightAssistAtt"
    att.Parent = hrp
    M.flyAttachment = att

    local lv = Instance.new("LinearVelocity")
    lv.Name = "FlightAssistLV"
    lv.Attachment0 = att
    lv.MaxForce = math.huge
    lv.VectorVelocity = Vector3.zero
    lv.RelativeTo = Enum.ActuatorRelativeTo.World
    lv.Parent = hrp
    M.flyBodyVel = lv

    -- Disable collision khi bay
    for _, part in ipairs(getChar():GetDescendants()) do
        if part:IsA("BasePart") then
            part.CanCollide = false
        end
    end
    local hum = getHumanoid()
    if hum then
        hum:ChangeState(Enum.HumanoidStateType.Physics)
    end
end

local function setFlyVelocity(vel)
    if M.flyBodyVel and M.flyBodyVel.Parent then
        M.flyBodyVel.VectorVelocity = vel
    end
end

local function stopFly()
    setFlyVelocity(Vector3.zero)
    cleanupFly()
    local hum = getHumanoid()
    if hum then
        hum:ChangeState(Enum.HumanoidStateType.GettingUp)
    end
end

-- ══════════════════════════════════════════════════════════
--  TARGET RESOLVER
--  Trả về Vector3 từ target dù là BasePart hay Vector3
-- ══════════════════════════════════════════════════════════
local function resolveTargetPos(target)
    if typeof(target) == "Vector3" then
        return target
    elseif typeof(target) == "Instance" then
        if target:IsA("BasePart") then
            return target.Position
        elseif target:IsA("Model") then
            local prim = target.PrimaryPart
            if prim then return prim.Position end
            local first = target:FindFirstChildOfClass("BasePart")
            if first then return first.Position end
        end
    end
    return nil
end

-- ══════════════════════════════════════════════════════════
--  CANCEL CURRENT MOVE TASK
-- ══════════════════════════════════════════════════════════
local function cancelMoveTask(reason)
    -- Ngắt vòng Heartbeat thật sự trước; task.cancel coroutine không ngắt connection.
    if M.heartbeatConn then
        pcall(function() M.heartbeatConn:Disconnect() end)
        M.heartbeatConn = nil
    end
    if M.moveThread then
        pcall(function() task.cancel(M.moveThread) end)
        M.moveThread = nil
    end
    stopFly()
    M.taskMutex = false
    if reason then log("Move task cancelled: " .. tostring(reason)) end
end

-- ══════════════════════════════════════════════════════════
--  MOVE TO TARGET — core fly coroutine
-- ══════════════════════════════════════════════════════════
local function moveToTarget(target)
    -- Mutex: ngăn 2 task chạy cùng lúc
    if M.taskMutex then
        log("moveToTarget ignored: a movement task is already active", "WARN")
        return
    end
    if M.collecting or M.state == STATE.COLLECTING or M.state == STATE.EMERGENCY_STOP or not M.active then
        return
    end
    M.taskMutex = true

    local targetPos = resolveTargetPos(target)
    if not targetPos then
        log("moveToTarget: cannot resolve position from target", "WARN")
        M.taskMutex = false
        return
    end

    setState(STATE.MOVING, "moveToTarget")

    M.moveThread = task.spawn(function()
        local startTime = tick()
        local arrived = false

        local hrp = getHRP()
        if not hrp then
            log("moveToTarget: no HRP", "ERROR")
            setState(STATE.ERROR, "no HRP")
            M.taskMutex = false
            return
        end

        setupFly(hrp)

        -- Heartbeat loop
        local conn
        conn = RunService.Heartbeat:Connect(function(dt)
            -- Kiểm tra emergency stop hoặc collecting
            if M.state == STATE.EMERGENCY_STOP
                or M.state == STATE.COLLECTING
                or M.collecting then
                conn:Disconnect()
                if M.heartbeatConn == conn then M.heartbeatConn = nil end
                stopFly()
                M.moveThread = nil
                M.taskMutex = false
                return
            end

            -- Timeout
            if tick() - startTime > CFG.MOVE_TIMEOUT then
                log("moveToTarget: timeout", "WARN")
                conn:Disconnect()
                if M.heartbeatConn == conn then M.heartbeatConn = nil end
                stopFly()
                setState(STATE.ERROR, "move timeout")
                M.moveThread = nil
                M.taskMutex = false
                return
            end

            local currentHRP = getHRP()
            if not currentHRP then
                conn:Disconnect(); if M.heartbeatConn == conn then M.heartbeatConn = nil end; stopFly(); M.moveThread = nil; M.taskMutex = false; return
            end

            -- Cập nhật targetPos nếu target là BasePart đang di chuyển
            local currentTargetPos = resolveTargetPos(target)
            if not currentTargetPos then
                conn:Disconnect(); if M.heartbeatConn == conn then M.heartbeatConn = nil end; stopFly(); M.moveThread = nil; M.taskMutex = false; return
            end

            local delta = currentTargetPos - currentHRP.Position
            local dist  = delta.Magnitude

            -- Đến nơi
            if dist <= CFG.ARRIVE_RADIUS then
                conn:Disconnect()
                if M.heartbeatConn == conn then M.heartbeatConn = nil end
                setFlyVelocity(Vector3.zero)
                stopFly()
                M.arrivedAt = tick()
                setState(STATE.ARRIVED, "within arrive radius")
                M.moveThread = nil
                M.taskMutex = false
                arrived = true
                return
            end

            -- Tính tốc độ — hãm tốc khi gần
            local speedScale = math.clamp(dist / CFG.BRAKE_RADIUS, 0.1, 1)
            local speed      = CFG.FLY_SPEED * speedScale
            local dir        = delta.Unit

            -- Bay theo hướng mục tiêu
            if M.flyBodyVel and M.flyBodyVel.Parent then
                M.flyBodyVel.VectorVelocity = dir * speed
            end
        end)
        M.heartbeatConn = conn
    end)
end

-- ══════════════════════════════════════════════════════════
--  COLLECTING STATE TRIGGER
--  Gọi khi phát hiện đang collect egg
-- ══════════════════════════════════════════════════════════
local function onCollectingStart(source)
    if M.collecting then return end -- đã đang collecting
    M.collecting = true
    log("Collecting detected via: " .. (source or "?"))

    -- Hủy move task NGAY LẬP TỨC
    cancelMoveTask("collecting started")
    setState(STATE.COLLECTING, source)
end

local function onCollectingEnd(source)
    if not M.collecting then return end
    M.collecting = false
    log("Collecting ended via: " .. (source or "?"))
    setState(STATE.COMPLETED, source)
    -- Main loop là nơi duy nhất xử lý cooldown và chuyển về Idle.
    -- Không tạo task.delay riêng để tránh hai luồng đổi state đồng thời.
end

-- ══════════════════════════════════════════════════════════
--  DETECTION LAYER A — _G NAMESPACE POLL
--  Nếu main script expose biến _G, dùng chúng
-- ══════════════════════════════════════════════════════════
local function checkGVars()
    local gTarget     = rawget(_G, CFG.G_TARGET_VAR)
    local gCollecting = rawget(_G, CFG.G_COLLECTING_VAR)
    local gActive     = rawget(_G, CFG.G_ACTIVE_VAR)

    -- Phát hiện lần đầu
    if not M.gVarsDetected and (gTarget ~= nil or gCollecting ~= nil) then
        M.gVarsDetected = true
        M.integrationMode = "G_VARS"
        log("✓ _G variables detected! Using G_VARS integration.", "INFO")
        log(("  _G.%s = %s"):format(CFG.G_TARGET_VAR,    tostring(gTarget)))
        log(("  _G.%s = %s"):format(CFG.G_COLLECTING_VAR, tostring(gCollecting)))
    end

    return {
        target     = gTarget,
        collecting = gCollecting,
        active     = gActive,
    }
end

-- ══════════════════════════════════════════════════════════
--  DETECTION LAYER B — WORKSPACE EGG SCANNER
--  Tìm egg gần nhất trong workspace
-- ══════════════════════════════════════════════════════════
local function isEggName(name)
    local lower = name:lower()
    for _, pat in ipairs(CFG.EGG_NAME_PATTERNS) do
        if lower:find(pat, 1, true) then return true end
    end
    return false
end

-- ── BỘ LỌC LOẠI TRỨNG ──────────────────────────────────────
-- Chỉ egg thuộc CFG.TARGET_EGG_TYPES mới được chọn làm target.
local lastRejectedTarget = nil  -- tránh spam log khi _G target bị loại
local filteredLogged     = {}   -- mỗi tên egg bị lọc chỉ log 1 lần

local function matchesTargetType(value)
    if type(value) ~= "string" then return false end
    local lower = value:lower()
    for _, pat in ipairs(CFG.TARGET_EGG_TYPES) do
        if lower:find(pat, 1, true) then return true end
    end
    return false
end

-- Egg có thuộc loại được phép không? Mỗi cấp kiểm tra tên + mọi Attribute
-- dạng chuỗi (vd Rarity = "Cosmic"): chính nó → model cha → model ông
-- (dừng khi tới workspace).
local function isTargetEgg(obj)
    if not CFG.FILTER_ENABLED then return true end
    if typeof(obj) ~= "Instance" then return false end

    local cur, depth = obj, 0
    while cur and cur ~= workspace and depth <= 2 do
        if matchesTargetType(cur.Name) then return true end

        local okAttr, attrs = pcall(function() return cur:GetAttributes() end)
        if okAttr and type(attrs) == "table" then
            for _, v in pairs(attrs) do
                if matchesTargetType(v) then return true end
            end
        end

        cur = cur.Parent
        depth = depth + 1
    end
    return false
end

-- Dùng cho target lấy từ _G (có thể là BasePart, Model hoặc Vector3)
local function isTargetAllowed(target)
    if not CFG.FILTER_ENABLED then return true end
    if typeof(target) == "Vector3" then return CFG.ALLOW_VECTOR_G_TARGET end
    return isTargetEgg(target)
end

-- Log 1 lần / tên egg bị lọc → xem console để biết egg nào đang bị bỏ qua
-- và chỉnh TARGET_EGG_TYPES nếu tên egg trong game khác dự kiến.
local function logFiltered(obj)
    local key = obj.Name
    if not filteredLogged[key] then
        filteredLogged[key] = true
        log("Egg filtered out: " .. key)
    end
end

local function findNearestEgg()
    local hrp = getHRP()
    if not hrp then return nil end

    local bestPart = nil
    local bestDist = CFG.SCAN_RADIUS

    -- Quét toàn workspace
    local function scanContainer(container)
        for _, obj in ipairs(container:GetChildren()) do
            if isEggName(obj.Name) then
                if not isTargetEgg(obj) then
                    logFiltered(obj)
                else
                    local part = nil
                    if obj:IsA("BasePart") then
                        part = obj
                    elseif obj:IsA("Model") then
                        part = obj.PrimaryPart or obj:FindFirstChildOfClass("BasePart")
                    end
                    if part then
                        local dist = (part.Position - hrp.Position).Magnitude
                        if dist < bestDist then
                            bestDist = dist
                            bestPart = part
                        end
                    end
                end
            end
        end
    end

    scanContainer(workspace)

    -- Thử CollectionService tags
    for _, tag in ipairs(CFG.EGG_COLLECTION_TAGS) do
        for _, obj in ipairs(CollectionService:GetTagged(tag)) do
            local part = nil
            if not isTargetEgg(obj) then
                logFiltered(obj)
            elseif obj:IsA("BasePart") then
                part = obj
            elseif obj:IsA("Model") then
                part = obj.PrimaryPart or obj:FindFirstChildOfClass("BasePart")
            end
            if part then
                local dist = (part.Position - hrp.Position).Magnitude
                if dist < bestDist then
                    bestDist = dist
                    bestPart = part
                end
            end
        end
    end

    return bestPart, bestDist
end

-- ══════════════════════════════════════════════════════════
--  DETECTION LAYER C — PROXIMITY PROMPT HOOKING
--  Bắt ProximityPrompt trong egg models
-- ══════════════════════════════════════════════════════════
local function hookProximityPrompt(pp)
    -- Tránh hook 2 lần
    if M.hookedPrompts and M.hookedPrompts[pp] then return end
    M.hookedPrompts = M.hookedPrompts or {}
    M.hookedPrompts[pp] = true

    local triggerConn = pp.TriggerEnded:Connect(function(player)
        if player == LocalPlayer then
            -- TriggerEnded chỉ cho biết tương tác prompt kết thúc, không xác nhận
            -- rằng trứng đã nhặt xong. Chỉ báo bắt đầu; chờ tín hiệu hoàn tất đáng tin cậy.
            onCollectingStart("ProximityPrompt.TriggerEnded")
        end
    end)

    local promptConn = pp.PromptButtonHoldBegan:Connect(function(player)
        if player == LocalPlayer then
            onCollectingStart("ProximityPrompt.HoldBegan")
        end
    end)

    local holdEndConn = pp.PromptButtonHoldEnded:Connect(function(player)
        if player == LocalPlayer then
            -- Không tự end ở đây vì TriggerEnded sẽ fire sau
        end
    end)

    table.insert(M.proxConns, triggerConn)
    table.insert(M.proxConns, promptConn)
    table.insert(M.proxConns, holdEndConn)
end

local function scanProximityPrompts()
    -- Hook tất cả PP hiện có và mới trong workspace
    local function hookInDescendants(obj)
        for _, desc in ipairs(obj:GetDescendants()) do
            if desc:IsA("ProximityPrompt") then
                local parent = desc.Parent
                if parent and typeof(parent) == "Instance" then
                    local name = (parent.Name or ""):lower()
                    local action = (desc.ActionText or ""):lower()
                    local objectText = (desc.ObjectText or ""):lower()
                    local relevant = isEggName(name) or isEggName(action) or isEggName(objectText)
                    local ancestor = parent.Parent
                    for _ = 1, 3 do
                        if not ancestor or ancestor == workspace then break end
                        if isEggName(ancestor.Name) then relevant = true; break end
                        ancestor = ancestor.Parent
                    end
                    if relevant then hookProximityPrompt(desc) end
                end
            end
        end
    end

    hookInDescendants(workspace)

    -- Hook các PP được thêm vào sau
    M.promptAddedConn = workspace.DescendantAdded:Connect(function(desc)
        if desc:IsA("ProximityPrompt") then
            local parent = desc.Parent
            local relevant = false
            if parent then
                relevant = isEggName(parent.Name) or isEggName(desc.ActionText or "") or isEggName(desc.ObjectText or "")
                local ancestor = parent.Parent
                for _ = 1, 3 do
                    if not ancestor or ancestor == workspace then break end
                    if isEggName(ancestor.Name) then relevant = true; break end
                    ancestor = ancestor.Parent
                end
            end
            if relevant then hookProximityPrompt(desc) end
        end
    end)

    log("ProximityPrompt hooks installed.")
end

-- ══════════════════════════════════════════════════════════
--  DETECTION LAYER D — ANIMATION MONITOR
--  Theo dõi animation tracks trên nhân vật
-- ══════════════════════════════════════════════════════════
local function isCollectAnimation(animTrack)
    local name = animTrack.Name:lower()
    for _, pat in ipairs(CFG.COLLECT_ANIM_PATTERNS) do
        if name:find(pat, 1, true) then return true end
    end
    -- Cũng check Animation ID nếu có
    local anim = animTrack.Animation
    if anim then
        local id = anim.AnimationId:lower()
        for _, pat in ipairs(CFG.COLLECT_ANIM_PATTERNS) do
            if id:find(pat, 1, true) then return true end
        end
    end
    return false
end

local function startAnimationMonitor(char)
    if M.animConn then
        pcall(function() M.animConn:Disconnect() end)
        M.animConn = nil
    end

    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then return end

    local animator = hum:FindFirstChildOfClass("Animator")
        or hum:WaitForChild("Animator", 5)
    if not animator then
        log("No Animator found on character", "WARN")
        return
    end

    M.animConn = animator.AnimationPlayed:Connect(function(track)
        if isCollectAnimation(track) then
            onCollectingStart("AnimationPlayed: " .. track.Name)
            track.Stopped:Connect(function()
                onCollectingEnd("AnimationStopped: " .. track.Name)
            end)
        end
    end)

    -- Monitor Humanoid state changes (Seated = possibly interacting)
    if M.humanoidStateConn then pcall(function() M.humanoidStateConn:Disconnect() end) end
    M.humanoidStateConn = hum.StateChanged:Connect(function(old, new)
        -- Không suy luận trạng thái nhặt trứng từ Humanoid state chung.
    end)

    log("Animation monitor started.")
end

-- ══════════════════════════════════════════════════════════
--  DETECTION LAYER D.2 — CHARACTER CHILD MONITOR
--  Phát hiện egg được parent vào character (carried egg)
-- ══════════════════════════════════════════════════════════
local function startCharacterChildMonitor(char)
    if M.charChildAddedConn then pcall(function() M.charChildAddedConn:Disconnect() end) end
    if M.charChildRemovedConn then pcall(function() M.charChildRemovedConn:Disconnect() end) end
    M.charChildAddedConn = char.ChildAdded:Connect(function(child)
        if isEggName(child.Name) then
            onCollectingStart("Egg parented to character: " .. child.Name)
        end
    end)
    M.charChildRemovedConn = char.ChildRemoved:Connect(function(child)
        if isEggName(child.Name) then
            onCollectingEnd("Egg removed from character: " .. child.Name)
        end
    end)
end

-- ══════════════════════════════════════════════════════════
--  CHARACTER RESPAWN HANDLER
-- ══════════════════════════════════════════════════════════
local function onCharacterAdded(char)
    log("Character added — resetting module state.")
    cancelMoveTask("character respawn")
    M.collecting = false
    M.target     = nil
    M.arrivedAt  = nil
    M.taskMutex  = false

    -- Reset về Idle (trừ EmergencyStop)
    if M.state ~= STATE.EMERGENCY_STOP then
        setState(STATE.IDLE, "character respawn")
    end

    char:WaitForChild("HumanoidRootPart", 10)
    task.wait(0.5) -- đợi character fully loaded

    startAnimationMonitor(char)
    startCharacterChildMonitor(char)
    log("Character ready. Module resuming.")
end

-- ══════════════════════════════════════════════════════════
--  EMERGENCY STOP
-- ══════════════════════════════════════════════════════════
local function emergencyStop(reason)
    log("⛔ EMERGENCY STOP: " .. (reason or "?"), "ERROR")
    cancelMoveTask("emergency stop")
    M.collecting = false
    M.state = STATE.EMERGENCY_STOP
    M.active = false
end

-- ══════════════════════════════════════════════════════════
--  MAIN CONTROL LOOP
--  Chạy liên tục, điều phối state machine
-- ══════════════════════════════════════════════════════════
local function mainLoop()
    log("Main control loop started.")

    while M.active do
        local ok, err = pcall(function()
            -- ── Không làm gì khi EmergencyStop ──────────────
            if M.state == STATE.EMERGENCY_STOP then
                task.wait(1)
                return
            end

            -- ── Đang collecting: chờ hoàn tất ───────────────
            if M.state == STATE.COLLECTING then
                task.wait(0.1)
                return
            end

            -- ── Đã arrive: chờ collecting bắt đầu ───────────
            if M.state == STATE.ARRIVED then
                -- Không chặn main loop 5 giây: vẫn poll tín hiệu collecting mỗi chu kỳ.
                task.wait(0.1)
                if M.state == STATE.ARRIVED and M.arrivedAt
                    and tick() - M.arrivedAt >= 5 then
                    setState(STATE.IDLE, "arrived grace period expired — no collect signal")
                    M.target = nil
                    M.arrivedAt = nil
                end
                return
            end

            -- ── Completed: về Idle ───────────────────────────
            if M.state == STATE.COMPLETED then
                task.wait(CFG.POST_COLLECT_COOLDOWN)
                if M.state == STATE.COMPLETED and not M.collecting then
                    setState(STATE.IDLE, "completed → idle")
                    M.target = nil
                    M.arrivedAt = nil
                end
                return
            end

            -- ── Error: log và về Idle sau delay ─────────────
            if M.state == STATE.ERROR then
                log("Error state — retrying in 2s: " .. tostring(M.lastError), "WARN")
                task.wait(2)
                cancelMoveTask("error recovery")
                setState(STATE.IDLE, "error recovery")
                M.target = nil
                return
            end

            -- ── IDLE hoặc MOVING: cần target ─────────────────
            -- Lớp A: _G variables
            local gState = checkGVars()

            -- Nếu main script đang collecting theo _G
            if gState.collecting == true and not M.collecting then
                onCollectingStart("_G." .. CFG.G_COLLECTING_VAR)
                return
            end
            if gState.collecting == false and M.collecting then
                onCollectingEnd("_G." .. CFG.G_COLLECTING_VAR .. " = false")
                return
            end

            -- Lấy target từ _G hoặc workspace scan
            local newTarget = nil
            local gTarget   = gState.target

            -- Bộ lọc: bỏ qua target từ _G nếu không thuộc loại egg cho phép
            if gTarget ~= nil and not isTargetAllowed(gTarget) then
                if lastRejectedTarget ~= gTarget then
                    lastRejectedTarget = gTarget
                    log(("Skipped _G.%s (not in egg filter): %s"):format(
                        CFG.G_TARGET_VAR, tostring(gTarget)))
                end
                gTarget = nil
            end

            if gTarget ~= nil then
                -- Ưu tiên _G target
                newTarget = gTarget
                if M.integrationMode ~= "G_VARS" then
                    M.integrationMode = "G_VARS"
                    log("Using _G." .. CFG.G_TARGET_VAR .. " as target source.")
                end
            else
                -- Fallback: workspace scan
                local eggPart, dist = findNearestEgg()
                if eggPart then
                    newTarget = eggPart
                    if M.integrationMode ~= "WORKSPACE" then
                        M.integrationMode = "WORKSPACE"
                        log("Using workspace scanner as target source (no usable _G.Target).")
                    end
                end
            end

            -- Không có target
            if newTarget == nil then
                if M.state == STATE.MOVING then
                    -- Target biến mất
                    cancelMoveTask("target disappeared")
                    setState(STATE.IDLE, "target lost")
                    M.target = nil
                end
                task.wait(CFG.SCAN_INTERVAL)
                return
            end

            -- Target thay đổi: hủy move cũ, bắt đầu mới
            local newTargetPos = resolveTargetPos(newTarget)
            local oldTargetPos = M.target and resolveTargetPos(M.target)

            local targetChanged = false
            if newTargetPos and oldTargetPos then
                targetChanged = (newTargetPos - oldTargetPos).Magnitude > 1
            elseif newTargetPos ~= oldTargetPos then
                targetChanged = true
            end

            if targetChanged then
                log(("New target: %s"):format(tostring(newTargetPos)))
                M.target = newTarget

                -- Chỉ bay khi không đang collecting
                if not M.collecting and M.state ~= STATE.COLLECTING then
                    cancelMoveTask("target changed")
                    task.wait(0.05)
                    moveToTarget(newTarget)
                end
            elseif M.state == STATE.IDLE and newTarget ~= nil then
                -- Có target nhưng chưa di chuyển
                M.target = newTarget
                if not M.collecting then
                    moveToTarget(newTarget)
                end
            end

            task.wait(CFG.SCAN_INTERVAL)
        end)

        if not ok then
            M.lastError = err
            log("Main loop error: " .. tostring(err), "ERROR")
            setState(STATE.ERROR, "main loop exception")
            task.wait(1)
        end
    end

    log("Main control loop ended.")
end

-- ══════════════════════════════════════════════════════════
--  CLEANUP
-- ══════════════════════════════════════════════════════════
local function cleanup()
    M.active = false
    cancelMoveTask("cleanup")

    for _, conn in ipairs(M.proxConns) do
        pcall(function() conn:Disconnect() end)
    end
    M.proxConns = {}

    if M.animConn then
        pcall(function() M.animConn:Disconnect() end)
        M.animConn = nil
    end
    if M.characterConn then
        pcall(function() M.characterConn:Disconnect() end)
        M.characterConn = nil
    end
    if M.heartbeatConn then
        pcall(function() M.heartbeatConn:Disconnect() end)
        M.heartbeatConn = nil
    end
    for _, key in ipairs({"promptAddedConn", "humanoidStateConn", "charChildAddedConn", "charChildRemovedConn"}) do
        local conn = M[key]
        if conn then pcall(function() conn:Disconnect() end); M[key] = nil end
    end

    cleanupFly()
    log("Module cleaned up.")
end

-- ══════════════════════════════════════════════════════════
--  BOOTSTRAP
--  1. Load main script
--  2. Kiểm tra _G vars
--  3. Setup detection layers
--  4. Start main loop
-- ══════════════════════════════════════════════════════════
local function bootstrap()
    log("════════════════════════════════════════")
    log("  Fast Flight Assist — Steal a Egg")
    log("  Bootstrapping...")
    log("════════════════════════════════════════")

    -- ─── Bước 1: Main script loading (opt-in) ────────────
    -- Mặc định KHÔNG tải script chính ở đây: hãy chạy script chính đúng một lần,
    -- sau đó chạy module này. Không thể phát hiện chắc chắn một script đã được
    -- chạy thủ công nếu script chính không tự đặt marker toàn cục.
    if CFG.LOAD_MAIN_SCRIPT then
        if _G.__FlightAssistMainLoadAttempted then
            log("Main script load skipped: this module already attempted to load it.", "WARN")
        else
            _G.__FlightAssistMainLoadAttempted = true
            log("Loading main script (LOAD_MAIN_SCRIPT=true)...")
            local mainOk, mainErr = pcall(function()
                local source = game:HttpGet("https://raw.githubusercontent.com/WhiteX1208/Scripts/refs/heads/main/StealAnEggs.luau")
                local chunk, compileErr = loadstring(source)
                if not chunk then error(compileErr or "loadstring failed") end
                chunk()
            end)
            if not mainOk then
                log("Main script failed to load: " .. tostring(mainErr), "ERROR")
            else
                log("Main script loaded successfully.")
            end
        end
    else
        log("Skipping main script load. Run the main script once separately before this module.")
    end

    -- ─── Bước 2: Đợi _G vars (2 giây) ──────────────────
    log("Checking _G integration variables...")
    task.wait(2)

    local gTarget     = rawget(_G, CFG.G_TARGET_VAR)
    local gCollecting = rawget(_G, CFG.G_COLLECTING_VAR)

    if gTarget ~= nil or gCollecting ~= nil then
        log("✓ _G integration detected:")
        log(("  _G.%s = %s"):format(CFG.G_TARGET_VAR,     tostring(gTarget)))
        log(("  _G.%s = %s"):format(CFG.G_COLLECTING_VAR, tostring(gCollecting)))
        M.gVarsDetected = true
        M.integrationMode = "G_VARS"
    else
        log("ℹ _G variables NOT found after 2s.", "WARN")
        log("  → Using workspace scanner + ProximityPrompt hooks.")
        log("  → If main script uses different var names, update CFG.G_TARGET_VAR")
        log("    and CFG.G_COLLECTING_VAR at the top of this file.")
        M.integrationMode = "WORKSPACE"
    end

    -- ─── Bước 3: Setup character ─────────────────────────
    local char = LocalPlayer.Character
    if char then
        onCharacterAdded(char)
    end

    M.characterConn = LocalPlayer.CharacterAdded:Connect(onCharacterAdded)

    -- ─── Bước 4: Setup ProximityPrompt hooks ─────────────
    scanProximityPrompts()

    -- ─── Bước 5: Start main loop ─────────────────────────
    log("Starting main control loop (Full Auto Mode)...")
    task.spawn(mainLoop)

    log("════════════════════════════════════════")
    log("  Module active. State: " .. M.state)
    log("  Integration: " .. tostring(M.integrationMode))
    log("  Fly speed: " .. CFG.FLY_SPEED .. " studs/s")
    log("  Egg filter: " .. (CFG.FILTER_ENABLED
        and table.concat(CFG.TARGET_EGG_TYPES, ", ") or "OFF (all eggs)"))
    log("════════════════════════════════════════")
end

-- ══════════════════════════════════════════════════════════
--  PUBLIC API — dùng từ console nếu cần can thiệp thủ công
-- ══════════════════════════════════════════════════════════
local PublicAPI = {
    -- Dừng khẩn cấp
    EmergencyStop = function(reason)
        emergencyStop(reason or "manual")
    end,
    -- Tiếp tục sau EmergencyStop
    Resume = function()
        if M.state == STATE.EMERGENCY_STOP then
            M.active = true
            setState(STATE.IDLE, "manual resume")
            task.spawn(mainLoop)
            log("Resumed from EmergencyStop.")
        end
    end,
    -- Lấy trạng thái hiện tại
    GetState = function()
        return {
            state      = M.state,
            target     = M.target,
            collecting = M.collecting,
            mode       = M.integrationMode,
            active     = M.active,
        }
    end,
    -- Cleanup hoàn toàn
    Destroy = function()
        cleanup()
    end,
}

-- ══════════════════════════════════════════════════════════
--  RUN
-- ══════════════════════════════════════════════════════════
bootstrap()

-- Expose API vào _G để dùng từ console nếu cần
_G.FlightAssist = PublicAPI

--[[
  ── HƯỚNG DẪN DEBUG ────────────────────────────────────────
  Dán vào console để kiểm tra:

  -- Xem trạng thái hiện tại
  print(game:GetService("HttpService"):JSONEncode(_G.FlightAssist.GetState()))

  -- Dừng khẩn cấp
  _G.FlightAssist.EmergencyStop("manual debug")

  -- Tiếp tục
  _G.FlightAssist.Resume()

  ── NẾU _G KHÔNG DETECT ────────────────────────────────────
  Sau khi script chính chạy, gõ vào console:
    for k,v in pairs(_G) do print(k, type(v), tostring(v)) end
  Tìm biến liên quan đến "egg", "target", "collect", "stealing"
  rồi cập nhật CFG.G_TARGET_VAR / CFG.G_COLLECTING_VAR.

  ── CÁC BIẾN _G PHỔ BIẾN CỦA HUB SCRIPTS ─────────────────
  _G.TargetEgg       _G.CurrentEgg     _G.EggTarget
  _G.IsCollecting    _G.Collecting     _G.PickingUp
  _G.AutoStealing    _G.AutoFarm       _G.Running
  ──────────────────────────────────────────────────────────
]]
