--[[
    NEXUS SCANNER
    Jalankan di akun alt / bot (taruh di folder autoexec executor).
    Tugasnya: baca egg di server yang sedang dimasuki, kirim ke server Nexus kamu,
    lalu pindah ke server lain dan ulangi. Egg yang terkumpul inilah yang tampil di Nexus Finder.
]]

local CONFIG = {
    ApiUrl   = "https://GANTI-DENGAN-URL-SERVER-KAMU", -- tanpa "/" di akhir
    ScanKey  = "ISI-DENGAN-NEXUS_SCAN_KEY",

    MinValue  = 1e9,   -- hanya kirim egg dengan value >= ini ($/s). 1e9 = 1B/s
    StayTime  = 8,     -- detik di tiap server sebelum pindah
    ScanEvery = 2,     -- scan ulang tiap sekian detik selama di server
    Hop       = true,  -- false = diam di satu server dan scan terus tiap 5 detik

    ScriptUrl = "",    -- opsional: link raw script ini, untuk executor yang tidak punya autoexec
    Debug     = false,
}

------------------------------------------------------------------------------

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local LocalPlayer = Players.LocalPlayer

local env = (typeof(getgenv) == "function" and getgenv()) or _G
env.NexusScannerRun = (env.NexusScannerRun or 0) + 1
local runId = env.NexusScannerRun
local function alive()
    return env.NexusScannerRun == runId
end

local function log(...)
    if CONFIG.Debug then
        print("[Nexus Scanner]", ...)
    end
end

local function pickRequest()
    if typeof(request) == "function" then return request end
    if typeof(http_request) == "function" then return http_request end
    if typeof(syn) == "table" and typeof(syn.request) == "function" then return syn.request end
    if typeof(http) == "table" and typeof(http.request) == "function" then return http.request end
    return nil
end

-- Setelan juga bisa dikirim dari loader, tanpa mengedit file ini:
--   getgenv().NexusConfig = { ApiUrl = "...", ScanKey = "..." }
if type(env.NexusConfig) == "table" then
    for k, v in pairs(env.NexusConfig) do
        CONFIG[k] = v
    end
end

local apiUrl = string.gsub(CONFIG.ApiUrl, "/+$", "")

------------------------------------------------------------------------------
-- Baca egg dari modul game (sama seperti yang dipakai client game sendiri)
------------------------------------------------------------------------------

local mods = {}

local function waitPath(root, parts, timeout)
    local node = root
    for _, name in ipairs(parts) do
        node = node:WaitForChild(name, timeout)
        if not node then
            return nil
        end
    end
    return node
end

local function requirePath(parts)
    local inst = waitPath(ReplicatedStorage, parts, 15)
    if not inst then
        return nil
    end
    local ok, res = pcall(require, inst)
    if ok then
        return res
    end
    return nil
end

local function loadMods()
    if mods.ready then
        return true
    end
    mods.EggState = requirePath({ "Client", "EggState" })
    mods.Assets = requirePath({ "Data", "Assets" })
    mods.Mutations = requirePath({ "Shared", "Modules", "Mutations" })
    mods.EggRecords = requirePath({ "Shared", "Util", "EggRecords" })
    mods.ready = type(mods.EggState) == "table" and type(mods.Assets) == "table"
    return mods.ready
end

-- value ($/s) = EarningRate * faktor ukuran * pengali mutation
local function sizeFactor(scale)
    if scale > 5 then
        return (scale / 5) ^ 1.2 * 19.637875755794113
    end
    return scale ^ 1.85
end

local function scanEggs()
    local out = {}
    if type(mods.EggState.ReadFieldEggs) ~= "function" then
        return out
    end

    local ok, data = pcall(mods.EggState.ReadFieldEggs)
    if not ok or type(data) ~= "table" or type(data.Records) ~= "table" then
        return out
    end

    local directory = mods.Assets.Directory
    if type(directory) ~= "table" then
        return out
    end

    for _, rec in pairs(data.Records) do
        if type(rec) == "table"
            and rec.State == "Slot"
            and type(rec.Uid) == "string"
            and string.sub(rec.Uid, 1, 12) ~= "FirstAreaEgg"
        then
            local def = directory[tostring(rec.AssetCategory)]
            if type(def) == "table" then
                local scale = tonumber(rec.AssetScale) or 1

                local mutMult = 1
                if type(mods.Mutations) == "table"
                    and type(mods.Mutations.EarningsFor) == "function"
                    and type(rec.Mutations) == "table"
                then
                    local okM, m = pcall(mods.Mutations.EarningsFor, rec.Mutations)
                    if okM and type(m) == "number" and m > 0 then
                        mutMult = m
                    end
                end

                local value = (tonumber(def.EarningRate) or 0) * sizeFactor(scale) * mutMult

                if value >= CONFIG.MinValue then
                    local rarity = type(def.Rarity) == "table" and def.Rarity or {}

                    local weight = 0
                    if type(mods.EggRecords) == "table" and type(mods.EggRecords.WeightKgForScale) == "function" then
                        local okW, w = pcall(mods.EggRecords.WeightKgForScale, rec.AssetCategory, scale)
                        if okW and tonumber(w) then
                            weight = tonumber(w)
                        end
                    end

                    local mutNames = {}
                    if type(rec.Mutations) == "table" then
                        for k, v in pairs(rec.Mutations) do
                            if v == true then
                                table.insert(mutNames, tostring(k))
                            elseif type(v) == "string" then
                                table.insert(mutNames, v)
                            end
                        end
                    end

                    table.insert(out, {
                        uid = rec.Uid,
                        name = tostring(def.DisplayName or rec.AssetCategory),
                        value = value,
                        size = math.floor(scale * 100 + 0.5) / 100,
                        weight = weight,
                        rarity = tonumber(rarity.RarityNumber or rarity.Rank) or 0,
                        rarityName = tostring(rarity.DisplayName or rarity._id or ""),
                        mutation = table.concat(mutNames, ", "),
                        area = tostring(rec.AreaId or ""),
                        image = tostring(def.Icon or def.Thumbnail or ""),
                    })
                end
            end
        end
    end

    table.sort(out, function(a, b)
        return a.value > b.value
    end)
    return out
end

------------------------------------------------------------------------------
-- Kirim ke server Nexus
------------------------------------------------------------------------------

local function post(eggs)
    local req = pickRequest()
    if not req then
        warn("[Nexus Scanner] executor kamu tidak punya fungsi request/http_request")
        return false
    end

    local okE, body = pcall(HttpService.JSONEncode, HttpService, {
        placeId = game.PlaceId,
        jobId = game.JobId,
        players = #Players:GetPlayers(),
        maxPlayers = Players.MaxPlayers,
        eggs = eggs,
    })
    if not okE then
        return false
    end

    local ok, res = pcall(req, {
        Url = apiUrl .. "/ingest",
        Method = "POST",
        Headers = {
            ["Content-Type"] = "application/json",
            ["x-nexus-key"] = CONFIG.ScanKey,
        },
        Body = body,
    })

    if ok and type(res) == "table" and res.StatusCode == 200 then
        log("terkirim", #eggs, "egg")
        return true
    end

    local code = ok and type(res) == "table" and res.StatusCode or "gagal"
    warn("[Nexus Scanner] kirim ke server gagal:", code)
    return false
end

------------------------------------------------------------------------------
-- Pindah server
------------------------------------------------------------------------------

local function listServers()
    local req = pickRequest()
    local servers = {}
    if not req then
        return servers
    end

    local order = math.random(1, 2) == 1 and "Asc" or "Desc"
    local cursor = ""

    for _ = 1, 3 do
        local url = string.format(
            "https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=%s&excludeFullGames=true&limit=100",
            game.PlaceId,
            order
        )
        if cursor ~= "" then
            url = url .. "&cursor=" .. HttpService:UrlEncode(cursor)
        end

        local ok, res = pcall(req, { Url = url, Method = "GET" })
        if not ok or type(res) ~= "table" or res.StatusCode ~= 200 then
            break
        end

        local okJ, data = pcall(HttpService.JSONDecode, HttpService, res.Body)
        if not okJ or type(data) ~= "table" then
            break
        end

        for _, s in ipairs(data.data or {}) do
            local playing = tonumber(s.playing) or 999
            local maxP = tonumber(s.maxPlayers) or 0
            if s.id ~= game.JobId and playing < maxP - 1 then
                table.insert(servers, s.id)
            end
        end

        cursor = data.nextPageCursor
        if type(cursor) ~= "string" or cursor == "" then
            break
        end
    end

    return servers
end

local function hop()
    local failed = false
    local conn = TeleportService.TeleportInitFailed:Connect(function(player)
        if player == LocalPlayer then
            failed = true
        end
    end)

    for attempt = 1, 6 do
        if not alive() then
            break
        end

        local servers = listServers()
        if #servers == 0 then
            log("daftar server kosong, coba lagi")
            task.wait(5)
        else
            failed = false
            local id = servers[math.random(1, #servers)]
            log("pindah ke", id, "percobaan", attempt)

            pcall(function()
                TeleportService:TeleportToPlaceInstance(game.PlaceId, id, LocalPlayer)
            end)

            -- kalau teleport berhasil, script ini ikut berhenti. Kalau masih hidup, berarti gagal.
            local t = os.clock()
            while os.clock() - t < 15 and not failed and alive() do
                task.wait(0.25)
            end
            task.wait(2)
        end
    end

    conn:Disconnect()

    if alive() then
        pcall(function()
            TeleportService:Teleport(game.PlaceId, LocalPlayer)
        end)
    end
end

------------------------------------------------------------------------------
-- Main
------------------------------------------------------------------------------

task.spawn(function()
    if string.find(CONFIG.ApiUrl, "GANTI", 1, true) or string.find(CONFIG.ScanKey, "ISI", 1, true) then
        warn("[Nexus Scanner] isi dulu ApiUrl dan ScanKey di bagian CONFIG")
        return
    end

    -- ScriptUrl diisi = scanner otomatis jalan lagi di server berikutnya (setelan ikut dibawa)
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

    if not game:IsLoaded() then
        game.Loaded:Wait()
    end

    if not loadMods() then
        warn("[Nexus Scanner] modul egg game tidak ketemu, cek path ReplicatedStorage di loadMods()")
        return
    end

    workspace:WaitForChild("AreaEggSlotsClient", 20)
    task.wait(2) -- beri waktu egg muncul di field

    local started = os.clock()
    local lastSig, lastPost = nil, 0

    while alive() do
        local ok, eggs = pcall(scanEggs)
        if ok then
            local uids = {}
            for _, e in ipairs(eggs) do
                table.insert(uids, e.uid)
            end
            local sig = table.concat(uids, ",")

            if sig ~= lastSig or os.clock() - lastPost > 20 then
                if post(eggs) then
                    lastSig = sig
                    lastPost = os.clock()
                end
            end
        else
            log("scan error", eggs)
        end

        if CONFIG.Hop and os.clock() - started >= CONFIG.StayTime then
            break
        end
        task.wait(CONFIG.Hop and CONFIG.ScanEvery or 5)
    end

    if CONFIG.Hop and alive() then
        hop()
    end
end)
