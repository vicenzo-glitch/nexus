--[[
    NEXUS — Pet Finder
    Daftar egg/pet bernilai tinggi dari server lain. Tekan JOIN untuk pindah ke server-nya.
    Data berasal dari server Nexus milikmu (diisi oleh Nexus Scanner).

    RightShift = sembunyikan / tampilkan panel.
]]

local CONFIG = {
    ApiUrl  = "https://GANTI-DENGAN-URL-SERVER-KAMU", -- tanpa "/" di akhir
    ReadKey = "ISI-DENGAN-NEXUS_READ_KEY",

    MinValue = 5e9,   -- filter awal ($/s). Bisa diubah dari kotak "Min value" di panel
    Limit    = 15,    -- jumlah maksimal egg di daftar
    Refresh  = 3,     -- detik antar pembaruan

    Demo      = false, -- true = tampilkan data contoh untuk cek tampilan tanpa server
    ScriptUrl = "",    -- opsional: link raw script ini, agar panel muncul lagi setelah pindah server
}

------------------------------------------------------------------------------

local Players = game:GetService("Players")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer

local env = (typeof(getgenv) == "function" and getgenv()) or _G
env.NexusFinderRun = (env.NexusFinderRun or 0) + 1
local runId = env.NexusFinderRun
local function alive()
    return env.NexusFinderRun == runId
end

local function pickRequest()
    if typeof(request) == "function" then return request end
    if typeof(http_request) == "function" then return http_request end
    if typeof(syn) == "table" and typeof(syn.request) == "function" then return syn.request end
    if typeof(http) == "table" and typeof(http.request) == "function" then return http.request end
    return nil
end

-- Setelan juga bisa dikirim dari loader, tanpa mengedit file ini:
--   getgenv().NexusConfig = { ApiUrl = "...", ReadKey = "..." }
if type(env.NexusConfig) == "table" then
    for k, v in pairs(env.NexusConfig) do
        CONFIG[k] = v
    end
end

local apiUrl = string.gsub(CONFIG.ApiUrl, "/+$", "")

-- ScriptUrl diisi = panel otomatis muncul lagi setelah pindah server (setelan ikut dibawa)
if CONFIG.ScriptUrl ~= "" and typeof(queue_on_teleport) == "function" then
    local okC, cfgJson = pcall(HttpService.JSONEncode, HttpService, CONFIG)
    if okC then
        pcall(queue_on_teleport, string.format(
            "getgenv().NexusConfig = game:GetService('HttpService'):JSONDecode(%q) loadstring(game:HttpGet(%q))()",
            cfgJson,
            CONFIG.ScriptUrl
        ))
    end
end

------------------------------------------------------------------------------
-- Util: format angka, parse "5B", umur, gambar
------------------------------------------------------------------------------

local UNITS = {
    { 1e18, "Qi" }, { 1e15, "Qa" }, { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" },
}

local function fmtValue(v)
    for _, u in ipairs(UNITS) do
        if v >= u[1] then
            return string.format("$%.2f%s/s", v / u[1], u[2])
        end
    end
    return string.format("$%d/s", math.floor(v))
end

local function fmtShort(v)
    for _, u in ipairs(UNITS) do
        if v >= u[1] then
            return string.format("%g%s", v / u[1], u[2])
        end
    end
    return string.format("%d", math.floor(v))
end

local SUFFIX = { k = 1e3, m = 1e6, b = 1e9, t = 1e12, qa = 1e15, qi = 1e18 }

local function parseValue(text)
    local s = string.lower(tostring(text or ""))
    s = string.gsub(s, "%s", "")
    s = string.gsub(s, "/s$", "")
    s = string.gsub(s, "^%$", "")
    local n, suf = string.match(s, "^([%d%.]+)(%a*)$")
    n = tonumber(n)
    if not n then
        return nil
    end
    if suf == "" then
        return n
    end
    local mult = SUFFIX[suf]
    if not mult then
        return nil
    end
    return n * mult
end

local function fmtAge(sec)
    sec = math.max(0, math.floor(sec))
    if sec < 60 then
        return sec .. "s ago"
    end
    if sec < 3600 then
        return math.floor(sec / 60) .. "m ago"
    end
    return math.floor(sec / 3600) .. "h ago"
end

local function imageId(raw)
    raw = tostring(raw or "")
    if raw == "" then
        return ""
    end
    if string.match(raw, "^%d+$") then
        return "rbxassetid://" .. raw
    end
    return raw
end

local RARITY_COLORS = {
    [0] = Color3.fromRGB(120, 126, 150),
    [1] = Color3.fromRGB(150, 156, 176),
    [2] = Color3.fromRGB(74, 222, 128),
    [3] = Color3.fromRGB(96, 165, 250),
    [4] = Color3.fromRGB(192, 132, 252),
    [5] = Color3.fromRGB(251, 191, 36),
    [6] = Color3.fromRGB(248, 113, 113),
    [7] = Color3.fromRGB(244, 114, 182),
}
local function rarityColor(n)
    n = math.clamp(math.floor(tonumber(n) or 0), 0, 7)
    return RARITY_COLORS[n]
end

------------------------------------------------------------------------------
-- UI
------------------------------------------------------------------------------

local C = {
    bg = Color3.fromRGB(14, 16, 26),
    header = Color3.fromRGB(26, 22, 52),
    card = Color3.fromRGB(23, 26, 40),
    line = Color3.fromRGB(52, 56, 84),
    text = Color3.fromRGB(240, 242, 252),
    dim = Color3.fromRGB(140, 146, 172),
    accent = Color3.fromRGB(124, 92, 255),
    accent2 = Color3.fromRGB(56, 189, 248),
    good = Color3.fromRGB(74, 222, 128),
    warn = Color3.fromRGB(251, 191, 36),
    bad = Color3.fromRGB(248, 113, 113),
}

local function new(class, props, parent)
    local inst = Instance.new(class)
    for k, v in pairs(props or {}) do
        inst[k] = v
    end
    if parent then
        inst.Parent = parent
    end
    return inst
end

local function corner(inst, r)
    return new("UICorner", { CornerRadius = UDim.new(0, r) }, inst)
end

local function stroke(inst, color, thickness, transparency)
    return new("UIStroke", {
        Color = color,
        Thickness = thickness or 1,
        Transparency = transparency or 0,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    }, inst)
end

local function guiParent()
    if typeof(gethui) == "function" then
        local ok, h = pcall(gethui)
        if ok and typeof(h) == "Instance" then
            return h
        end
    end
    local ok, cg = pcall(function()
        return game:GetService("CoreGui")
    end)
    if ok and cg then
        return cg
    end
    return LocalPlayer:WaitForChild("PlayerGui")
end

local parent = guiParent()
local old = parent:FindFirstChild("NexusFinder")
if old then
    old:Destroy()
end

local gui = new("ScreenGui", {
    Name = "NexusFinder",
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    DisplayOrder = 999,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})

local viewport = Vector2.new(800, 600)
if workspace.CurrentCamera then
    viewport = workspace.CurrentCamera.ViewportSize
end
local W = math.min(360, viewport.X - 24)
local H = math.min(480, viewport.Y - 24)
local HEADER_H = 52

local main = new("Frame", {
    Name = "Main",
    BackgroundColor3 = C.bg,
    BorderSizePixel = 0,
    Position = UDim2.new(0, 16, 0.5, -math.floor(H / 2)),
    Size = UDim2.fromOffset(W, H),
    ClipsDescendants = true,
}, gui)
corner(main, 14)
stroke(main, C.line, 1.5, 0.1)

-- Header
local header = new("Frame", {
    Name = "Header",
    BackgroundColor3 = C.header,
    BorderSizePixel = 0,
    Size = UDim2.new(1, 0, 0, HEADER_H),
    Active = true,
}, main)
new("UIGradient", {
    Color = ColorSequence.new(Color3.fromRGB(58, 40, 128), Color3.fromRGB(20, 30, 70)),
    Rotation = 20,
}, header)

local dot = new("Frame", {
    BackgroundColor3 = C.warn,
    BorderSizePixel = 0,
    Position = UDim2.fromOffset(14, 14),
    Size = UDim2.fromOffset(8, 8),
}, header)
corner(dot, 4)

new("TextLabel", {
    BackgroundTransparency = 1,
    Position = UDim2.fromOffset(30, 6),
    Size = UDim2.fromOffset(150, 24),
    Font = Enum.Font.GothamBlack,
    Text = "NEXUS",
    TextColor3 = C.text,
    TextSize = 21,
    TextXAlignment = Enum.TextXAlignment.Left,
}, header)

local subtitle = new("TextLabel", {
    BackgroundTransparency = 1,
    Position = UDim2.fromOffset(30, 30),
    Size = UDim2.new(1, -110, 0, 14),
    Font = Enum.Font.Gotham,
    Text = "Pet Finder",
    TextColor3 = Color3.fromRGB(190, 184, 230),
    TextSize = 12,
    TextXAlignment = Enum.TextXAlignment.Left,
}, header)

local function headerButton(text, offsetX)
    local b = new("TextButton", {
        AnchorPoint = Vector2.new(1, 0.5),
        BackgroundColor3 = Color3.fromRGB(255, 255, 255),
        BackgroundTransparency = 0.88,
        BorderSizePixel = 0,
        Position = UDim2.new(1, offsetX, 0.5, 0),
        Size = UDim2.fromOffset(28, 28),
        Font = Enum.Font.GothamBold,
        Text = text,
        TextColor3 = C.text,
        TextSize = 18,
        AutoButtonColor = true,
    }, header)
    corner(b, 8)
    return b
end
local closeBtn = headerButton("×", -10)
local minBtn = headerButton("–", -44)

-- Body
local body = new("Frame", {
    Name = "Body",
    BackgroundTransparency = 1,
    Position = UDim2.fromOffset(0, HEADER_H),
    Size = UDim2.new(1, 0, 1, -HEADER_H),
}, main)

new("TextLabel", {
    BackgroundTransparency = 1,
    Position = UDim2.fromOffset(12, 10),
    Size = UDim2.fromOffset(70, 30),
    Font = Enum.Font.GothamBold,
    Text = "MIN VALUE",
    TextColor3 = C.dim,
    TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Left,
}, body)

local minBox = new("TextBox", {
    BackgroundColor3 = C.card,
    BorderSizePixel = 0,
    Position = UDim2.fromOffset(84, 10),
    Size = UDim2.fromOffset(90, 30),
    Font = Enum.Font.GothamBold,
    Text = fmtShort(CONFIG.MinValue),
    PlaceholderText = "5B",
    TextColor3 = C.accent2,
    TextSize = 14,
    ClearTextOnFocus = false,
}, body)
corner(minBox, 8)
stroke(minBox, C.line, 1, 0.2)

new("TextLabel", {
    AnchorPoint = Vector2.new(1, 0),
    BackgroundTransparency = 1,
    Position = UDim2.new(1, -12, 0, 10),
    Size = UDim2.fromOffset(110, 30),
    Font = Enum.Font.Gotham,
    Text = "auto " .. CONFIG.Refresh .. "s  ·  $/s",
    TextColor3 = C.dim,
    TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Right,
}, body)

local list = new("ScrollingFrame", {
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    Position = UDim2.fromOffset(10, 50),
    Size = UDim2.new(1, -20, 1, -50 - 34),
    CanvasSize = UDim2.new(0, 0, 0, 0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollBarThickness = 3,
    ScrollBarImageColor3 = C.accent,
    ScrollingDirection = Enum.ScrollingDirection.Y,
}, body)
new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, list)

local emptyLabel = new("TextLabel", {
    BackgroundTransparency = 1,
    Position = UDim2.fromOffset(20, 90),
    Size = UDim2.new(1, -40, 0, 60),
    Font = Enum.Font.Gotham,
    Text = "Belum ada egg yang cocok.\nTurunkan Min value atau tunggu scanner.",
    TextColor3 = C.dim,
    TextSize = 13,
    TextWrapped = true,
    Visible = false,
}, body)

local footer = new("TextLabel", {
    AnchorPoint = Vector2.new(0, 1),
    BackgroundTransparency = 1,
    Position = UDim2.new(0, 12, 1, -6),
    Size = UDim2.new(1, -24, 0, 22),
    Font = Enum.Font.Gotham,
    Text = "Menghubungkan...",
    TextColor3 = C.dim,
    TextSize = 12,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextTruncate = Enum.TextTruncate.AtEnd,
}, body)

local function setStatus(text, color, dotColor)
    footer.Text = text
    footer.TextColor3 = color or C.dim
    if dotColor then
        dot.BackgroundColor3 = dotColor
    end
end

------------------------------------------------------------------------------
-- Kartu egg
------------------------------------------------------------------------------

local cards = {}
local dead = {} -- jobId -> waktu (os.clock) sampai kapan disembunyikan
local joining = false
local lastTriedJob = nil
local CARD_H = 72

local function resetButtons()
    joining = false
    for _, card in pairs(cards) do
        card.join.Text = "JOIN"
    end
end

local function joinServer(item, card)
    if joining then
        return
    end
    if item.jobId == game.JobId then
        setStatus("Kamu sudah berada di server ini.", C.warn)
        return
    end

    joining = true
    lastTriedJob = item.jobId
    card.join.Text = "..."
    setStatus("Masuk ke server " .. item.name .. " ...", C.accent2, C.accent2)

    local ok, err = pcall(function()
        TeleportService:TeleportToPlaceInstance(item.placeId or game.PlaceId, item.jobId, LocalPlayer)
    end)
    if not ok then
        resetButtons()
        setStatus("Gagal join: " .. tostring(err), C.bad, C.bad)
        return
    end

    task.delay(15, function()
        if alive() and joining then
            resetButtons()
            setStatus("Join tidak merespons, coba lagi.", C.warn)
        end
    end)
end

local function makeCard(item)
    local root = new("Frame", {
        BackgroundColor3 = C.card,
        BorderSizePixel = 0,
        Size = UDim2.new(1, -4, 0, CARD_H),
    }, list)
    corner(root, 10)
    local edge = stroke(root, C.line, 1, 0.3)

    local iconBox = new("Frame", {
        BackgroundColor3 = Color3.fromRGB(14, 16, 26),
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(8, 8),
        Size = UDim2.fromOffset(56, 56),
    }, root)
    corner(iconBox, 8)

    local letter = new("TextLabel", {
        BackgroundTransparency = 1,
        Size = UDim2.fromScale(1, 1),
        Font = Enum.Font.GothamBlack,
        Text = "?",
        TextColor3 = C.dim,
        TextSize = 24,
        Visible = false,
    }, iconBox)

    local icon = new("ImageLabel", {
        BackgroundTransparency = 1,
        Size = UDim2.fromScale(1, 1),
        ScaleType = Enum.ScaleType.Fit,
        Image = "",
    }, iconBox)

    local name = new("TextLabel", {
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(74, 8),
        Size = UDim2.new(1, -74 - 80, 0, 18),
        Font = Enum.Font.GothamBold,
        Text = "",
        TextColor3 = C.text,
        TextSize = 15,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, root)

    local price = new("TextLabel", {
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(74, 28),
        Size = UDim2.new(1, -74 - 80, 0, 18),
        Font = Enum.Font.GothamBold,
        RichText = true,
        Text = "",
        TextColor3 = C.good,
        TextSize = 14,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, root)

    local info = new("TextLabel", {
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(74, 48),
        Size = UDim2.new(1, -74 - 80, 0, 16),
        Font = Enum.Font.Gotham,
        Text = "",
        TextColor3 = C.dim,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextTruncate = Enum.TextTruncate.AtEnd,
    }, root)

    local join = new("TextButton", {
        AnchorPoint = Vector2.new(1, 0.5),
        BackgroundColor3 = C.accent,
        BorderSizePixel = 0,
        Position = UDim2.new(1, -8, 0.5, 0),
        Size = UDim2.fromOffset(62, 36),
        Font = Enum.Font.GothamBlack,
        Text = "JOIN",
        TextColor3 = Color3.fromRGB(255, 255, 255),
        TextSize = 14,
        AutoButtonColor = true,
    }, root)
    corner(join, 9)
    new("UIGradient", {
        Color = ColorSequence.new(Color3.fromRGB(150, 110, 255), Color3.fromRGB(86, 70, 230)),
        Rotation = 90,
    }, join)

    local card = {
        root = root,
        edge = edge,
        icon = icon,
        letter = letter,
        name = name,
        price = price,
        info = info,
        join = join,
        item = item,
        receivedAt = os.clock(),
    }

    join.MouseButton1Click:Connect(function()
        joinServer(card.item, card)
    end)
    return card
end

local function updateCard(card)
    local item = card.item
    local img = imageId(item.image)
    if card.icon.Image ~= img then
        card.icon.Image = img
    end
    card.letter.Visible = (img == "")
    card.letter.Text = string.upper(string.sub(tostring(item.name or "?"), 1, 1))

    card.name.Text = tostring(item.name or "Unknown")
    card.edge.Color = rarityColor(item.rarity)

    local size = tonumber(item.size) or 0
    local sizeText = ""
    if size > 0 then
        sizeText = string.format('  <font color="#fbbf24">x%.2f</font>', size)
    end
    card.price.Text = fmtValue(tonumber(item.value) or 0) .. sizeText

    local parts = { fmtAge(os.clock() - card.receivedAt) }
    local maxP = tonumber(item.maxPlayers) or 0
    if maxP > 0 then
        table.insert(parts, (tonumber(item.players) or 0) .. "/" .. maxP)
    end
    local extra = tostring(item.mutation or "")
    if extra == "" then
        extra = tostring(item.rarityName or "")
    end
    if extra ~= "" then
        table.insert(parts, extra)
    end
    card.info.Text = table.concat(parts, "  ·  ")
end

local function render(items)
    local seen = {}
    local shown = 0

    for _, item in ipairs(items) do
        local hidden = dead[item.jobId] and dead[item.jobId] > os.clock()
        if not hidden then
            shown = shown + 1
            seen[item.id] = true

            local card = cards[item.id]
            if not card then
                card = makeCard(item)
                cards[item.id] = card
            end
            card.item = item
            card.receivedAt = os.clock() - (tonumber(item.ageSec) or 0)
            card.root.LayoutOrder = shown
            updateCard(card)
        end
    end

    for id, card in pairs(cards) do
        if not seen[id] then
            card.root:Destroy()
            cards[id] = nil
        end
    end

    emptyLabel.Visible = (shown == 0)
    subtitle.Text = "Pet Finder  ·  " .. shown .. " server"
end

------------------------------------------------------------------------------
-- Ambil data
------------------------------------------------------------------------------

local minValue = CONFIG.MinValue
local refreshNow = false

local function demoItems()
    return {
        { id = "d1", name = "Gorillastein", value = 143.31e9, size = 9.22, rarity = 6, rarityName = "Mythic", mutation = "", image = "", placeId = game.PlaceId, jobId = "demo-1", players = 12, maxPlayers = 20, ageSec = 9 },
        { id = "d2", name = "Gorillastein", value = 64.55e9, size = 4.83, rarity = 5, rarityName = "Legendary", mutation = "Gold", image = "", placeId = game.PlaceId, jobId = "demo-2", players = 7, maxPlayers = 20, ageSec = 53 },
        { id = "d3", name = "Gorillastein", value = 61.16e9, size = 4.69, rarity = 4, rarityName = "Epic", mutation = "", image = "", placeId = game.PlaceId, jobId = "demo-3", players = 15, maxPlayers = 20, ageSec = 98 },
    }
end

local function fetchFeed()
    if CONFIG.Demo then
        local out = {}
        for _, it in ipairs(demoItems()) do
            if it.value >= minValue then
                table.insert(out, it)
            end
        end
        return out
    end

    local req = pickRequest()
    if not req then
        return nil, "Executor tidak punya fungsi request"
    end

    local url = string.format(
        "%s/feed?min=%.0f&limit=%d&placeId=%d",
        apiUrl,
        minValue,
        math.clamp(math.floor(CONFIG.Limit), 1, 50),
        game.PlaceId
    )

    local ok, res = pcall(req, {
        Url = url,
        Method = "GET",
        Headers = { ["x-nexus-key"] = CONFIG.ReadKey },
    })
    if not ok or type(res) ~= "table" then
        return nil, "Tidak bisa menghubungi server Nexus"
    end
    if res.StatusCode == 401 then
        return nil, "ReadKey salah"
    end
    if res.StatusCode ~= 200 then
        return nil, "Server Nexus error (" .. tostring(res.StatusCode) .. ")"
    end

    local okJ, data = pcall(HttpService.JSONDecode, HttpService, res.Body)
    if not okJ or type(data) ~= "table" or type(data.items) ~= "table" then
        return nil, "Respons server tidak valid"
    end
    return data.items
end

local function refresh()
    local items, err = fetchFeed()
    if not alive() then
        return
    end
    if items then
        render(items)
        if not joining then
            setStatus(CONFIG.Demo and "Mode demo" or "Live", C.good, C.good)
        end
    else
        setStatus(err or "Gagal memuat", C.bad, C.bad)
    end
end

------------------------------------------------------------------------------
-- Interaksi: drag, minimize, close, min value, teleport gagal
------------------------------------------------------------------------------

local conns = {}
local function keep(c)
    table.insert(conns, c)
    return c
end

local dragging, dragStart, startPos = false, nil, nil
keep(header.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = main.Position
        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
            end
        end)
    end
end))
keep(UserInputService.InputChanged:Connect(function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local d = input.Position - dragStart
        main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
    end
end))

keep(UserInputService.InputBegan:Connect(function(input, processed)
    if not processed and input.KeyCode == Enum.KeyCode.RightShift then
        gui.Enabled = not gui.Enabled
    end
end))

local minimized = false
minBtn.MouseButton1Click:Connect(function()
    minimized = not minimized
    body.Visible = not minimized
    main.Size = minimized and UDim2.fromOffset(W, HEADER_H) or UDim2.fromOffset(W, H)
end)

local function shutdown()
    env.NexusFinderRun = (env.NexusFinderRun or 0) + 1
    for _, c in ipairs(conns) do
        pcall(function()
            c:Disconnect()
        end)
    end
    gui:Destroy()
end
closeBtn.MouseButton1Click:Connect(shutdown)

minBox.FocusLost:Connect(function()
    local v = parseValue(minBox.Text)
    if v then
        minValue = v
        minBox.Text = fmtShort(v)
        refreshNow = true
    else
        minBox.Text = fmtShort(minValue)
        setStatus("Format salah. Contoh: 500M, 5B, 1.5T", C.warn)
    end
end)

keep(TeleportService.TeleportInitFailed:Connect(function(player, result)
    if player ~= LocalPlayer then
        return
    end
    resetButtons()

    local msg = "Join gagal: " .. tostring(result)
    if result == Enum.TeleportResult.GameFull then
        msg = "Server penuh. Coba egg lain."
    elseif result == Enum.TeleportResult.GameEnded or result == Enum.TeleportResult.GameNotFound then
        msg = "Server itu sudah ditutup. Coba egg lain."
    elseif result == Enum.TeleportResult.Flooded then
        msg = "Terlalu cepat, tunggu beberapa detik lalu coba lagi."
    elseif result == Enum.TeleportResult.IsTeleporting then
        msg = "Masih proses pindah server..."
    end

    -- server yang penuh / sudah tutup disembunyikan 2 menit
    if lastTriedJob
        and (
            result == Enum.TeleportResult.GameFull
            or result == Enum.TeleportResult.GameEnded
            or result == Enum.TeleportResult.GameNotFound
        )
    then
        dead[lastTriedJob] = os.clock() + 120
        refreshNow = true
    end

    setStatus(msg, C.warn, C.warn)
end))

------------------------------------------------------------------------------
-- Jalankan
------------------------------------------------------------------------------

gui.Parent = parent

if not CONFIG.Demo and (string.find(CONFIG.ApiUrl, "GANTI", 1, true) or string.find(CONFIG.ReadKey, "ISI", 1, true)) then
    setStatus("Isi ApiUrl dan ReadKey di CONFIG (atau Demo = true)", C.warn, C.warn)
    emptyLabel.Text = "Nexus belum disetel.\nIsi ApiUrl & ReadKey dulu."
    emptyLabel.Visible = true
    return
end

-- umur ("9s ago") jalan terus tanpa menunggu refresh
task.spawn(function()
    while alive() do
        for _, card in pairs(cards) do
            updateCard(card)
        end
        task.wait(1)
    end
end)

task.spawn(function()
    while alive() do
        refresh()
        local waited = 0
        while alive() and waited < CONFIG.Refresh and not refreshNow do
            task.wait(0.25)
            waited = waited + 0.25
        end
        refreshNow = false
    end
end)
