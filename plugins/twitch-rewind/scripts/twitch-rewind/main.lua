-- twitch-rewind: seek back through a live Twitch broadcast (via its in-progress
-- VOD) and return to the live playlist, from plain `mpv https://twitch.tv/<channel>`.
-- See README.md. Lua 5.1/LuaJIT compatible (no bit operators, no goto).

local mp      = require 'mp'
local msg     = require 'mp.msg'
local utils   = require 'mp.utils'
local options = require 'mp.options'

local o = {
    ytdl_path       = "yt-dlp",     -- yt-dlp executable (PATH lookup)
    curl_path       = "curl",       -- curl executable (GQL lookups, playlist fetch)
    gql_client_id   = "kimne78kx3ncx6brgo4mv6wki5h1ko",
    quality         = "best",       -- best | worst | <max height, e.g. 720 or 720p>
    prefetch        = true,         -- resolve the VOD in the background while watching live
    auto_seek       = true,         -- ordinary seeks that land outside the cache switch to the VOD
    live_on_end     = true,         -- reaching the end of the in-progress VOD returns to live
    cache_margin    = 1.0,          -- seconds outside the cache before a seek counts as "outside"
    pts_offset      = 63.0,         -- fallback live-PTS -> VOD-time offset (s) if it cannot be measured
    calibrate       = true,         -- measure the exact offset from the VOD's first segment
    manage_cache    = true,         -- apply the per-mode cache/seek settings below
    live_readahead  = 10,           -- demuxer-readahead-secs while live
    live_max_bytes  = "150MiB",     -- demuxer-max-bytes while live
    live_back_bytes = "300MiB",     -- demuxer-max-back-bytes while live (rewind without switching)
    vod_readahead   = 60,
    vod_max_bytes   = "400MiB",
    vod_back_bytes  = "200MiB",
    osd_duration    = 4,
}
options.read_options(o, "twitch-rewind")
if package.config:sub(1, 1) == "\\" and o.curl_path == "curl" then
    local f = io.open("C:/Windows/System32/curl.exe", "rb")
    if f then f:close(); o.curl_path = "C:/Windows/System32/curl.exe" end
end

local GQL_URL = "https://gql.twitch.tv/gql"
local RESERVED = { videos=1, directory=1, downloads=1, jobs=1, turbo=1, settings=1, subscriptions=1,
                   friends=1, wallet=1, inventory=1, drops=1, p=1, popout=1, embed=1, ["moderator"]=1,
                   login=1, signup=1, search=1, store=1, team=1, teams=1, prime=1, bits=1, clips=1 }

-- ---------------------------------------------------------------------------
-- state
-- ---------------------------------------------------------------------------
local st = {
    kind = nil,        -- "live" | "vod" | "snapshot" for the current file, nil if not Twitch
    mode = nil,        -- "live" | "vod" (published)
    channel = nil,
    vod_id = nil,
    date = nil,
    title = nil,
    lookup = nil,      -- {live=, vod={id,title,created,length,status}, title=, stream_created=, at=}
    lookup_waiters = nil,
    ytinfo = {},       -- vod_id -> {url=<media playlist url>, quality=}
    offsets = {},      -- vod_id -> {value=, measured=}
    snapshot_path = nil,
    snapshot_inprog = false,
    tmpfiles = {},
    job = 0,
    pos = nil,         -- last stable time-pos
    seeking = false,
    paused = false,
    switching = false,
    switch_spec = nil,
    ignore_seeks = 0,
    live_edge_pts = nil,
    live_edge_wall = nil,
    seq = 0,
}

local function osd(text, secs)
    msg.info(text)
    mp.osd_message(text, secs or o.osd_duration)
end

local function fmt_time(t)
    t = math.max(0, math.floor((t or 0) + 0.5))
    return string.format("%d:%02d:%02d", math.floor(t / 3600), math.floor(t / 60) % 60, t % 60)
end

local function parse_time(s)
    if not s then return nil end
    s = tostring(s):gsub("^%s+", ""):gsub("%s+$", "")
    local n = tonumber(s)
    if n then return n end
    local h, m, sec = s:match("^(%d+):(%d+):(%d+%.?%d*)$")
    if h then return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(sec) end
    m, sec = s:match("^(%d+):(%d+%.?%d*)$")
    if m then return tonumber(m) * 60 + tonumber(sec) end
    local total, any = 0, false
    for num, unit in s:gmatch("(%d+%.?%d*)%s*([hHmMsS])") do
        any = true
        unit = unit:lower()
        total = total + tonumber(num) * (unit == "h" and 3600 or unit == "m" and 60 or 1)
    end
    return any and total or nil
end

local function iso_to_epoch(s)
    local y, mo, d, h, mi, sec = tostring(s):match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if not y then return nil end
    y, mo, d, h, mi, sec = tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(sec)
    if mo <= 2 then y = y - 1 end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mpr = (mo + 9) % 12
    local doy = math.floor((153 * mpr + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return (era * 146097 + doe - 719468) * 86400 + h * 3600 + mi * 60 + sec
end

local function non_empty(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s ~= "" and s or nil
end

local function apply_title()
    if st.kind and st.title then
        mp.set_property("file-local-options/force-media-title", st.title)
        mp.set_property("force-media-title", st.title)
    end
end

local function publish()
    if not st.kind or not st.channel then
        mp.del_property("user-data/twitch")
        return
    end
    -- While live, the seekbar can span the whole broadcast: VOD time = live pts - dvr_offset.
    local off = st.kind == "live" and st.vod_id and st.offsets[st.vod_id]
    mp.set_property_native("user-data/twitch", {
        channel = st.channel,
        mode = st.mode or "live",
        vod_id = st.vod_id,
        date = st.date,
        title = st.title,
        can_live = (st.kind == "live") or st.snapshot_inprog or (st.lookup and st.lookup.live) or false,
        dvr_offset = off and off.value or nil,
    })
end

-- ---------------------------------------------------------------------------
-- async subprocess with timeout
-- ---------------------------------------------------------------------------
local subprocesses = {}
local function run(args, timeout, cb)
    local done, id, timer = false, nil, nil
    id = mp.command_native_async({
        name = "subprocess", args = args, playback_only = false,
        capture_stdout = true, capture_stderr = true,
    }, function(ok, res, err)
        if done then return end
        done = true
        subprocesses[id] = nil
        if timer then timer:kill() end
        local good, e = pcall(cb, ok, res or {}, err)
        if not good then
            msg.error("internal error: " .. tostring(e))
            mp.osd_message("Twitch: internal error (see log)", 5)
        end
    end)
    subprocesses[id] = true
    timer = mp.add_timeout(timeout, function()
        if not done then mp.abort_async_command(id) end
    end)
end

local function spawn_failed(ok, res)
    return (not ok) or res.error_string == "init"
end

-- ---------------------------------------------------------------------------
-- Twitch GQL lookup (curl)
-- ---------------------------------------------------------------------------
local function gql(query, cb)
    local body = utils.format_json({ query = query })
    run({ o.curl_path, "-sS", "-m", "15",
          "-H", "Client-ID: " .. o.gql_client_id,
          "-H", "Content-Type: application/json",
          "--data-binary", body, GQL_URL }, 20, function(ok, res)
        if spawn_failed(ok, res) then return cb("curl-missing") end
        if res.killed_by_us then return cb("timeout") end
        if res.status ~= 0 then
            return cb("network: " .. ((res.stderr or ""):gsub("%s+$", "")))
        end
        local j = utils.parse_json(res.stdout or "")
        if type(j) ~= "table" then return cb("bad-response") end
        if not j.data then
            local detail = j.errors and j.errors[1] and j.errors[1].message
                or j.message or j.error or "no data in response"
            return cb("gql: " .. tostring(detail))
        end
        cb(nil, j.data)
    end)
end

local function vod_from_node(n)
    if type(n) ~= "table" or not n.id then return nil end
    return { id = tostring(n.id), title = non_empty(n.title), created = n.createdAt, length = n.lengthSeconds, status = n.status }
end

local function lookup_channel(login, cb)
    gql(string.format(
        'query{user(login:"%s"){login broadcastSettings{title} stream{id title createdAt archiveVideo{id title createdAt lengthSeconds status}} ' ..
        'videos(first:1,type:ARCHIVE){edges{node{id title createdAt lengthSeconds status}}}}}', login),
        function(err, data)
            if err then return cb(err) end
            local u = data and data.user
            if type(u) ~= "table" then return cb("no such channel") end
            local info = { at = os.time(), live = type(u.stream) == "table" }
            local e = u.videos and u.videos.edges and u.videos.edges[1]
            local latest_vod = e and vod_from_node(e.node)
            if info.live then
                info.stream_created = u.stream.createdAt
                info.vod = vod_from_node(u.stream.archiveVideo) or (latest_vod and latest_vod.status == "RECORDING" and latest_vod or nil)
                info.title = non_empty(u.stream.title) or non_empty(u.broadcastSettings and u.broadcastSettings.title) or (info.vod and info.vod.title)
            else
                info.vod = latest_vod
                info.title = (latest_vod and latest_vod.title) or non_empty(u.broadcastSettings and u.broadcastSettings.title)
            end
            cb(nil, info)
        end)
end

local function lookup_video(id, cb)
    gql(string.format('query{video(id:"%s"){id title status createdAt lengthSeconds owner{login}}}', id),
        function(err, data)
            if err then return cb(err) end
            local v = data and data.video
            if type(v) ~= "table" then return cb("video not found") end
            cb(nil, v)
        end)
end

-- ---------------------------------------------------------------------------
-- yt-dlp: resolve the VOD's media playlist URL
-- ---------------------------------------------------------------------------
local function choose_format(formats)
    local cap, worst = nil, false
    local q = tostring(o.quality):lower()
    if q == "worst" then worst = true
    elseif q ~= "best" then cap = tonumber(q:match("%d+")) end
    local pick
    for _, f in ipairs(formats or {}) do
        if f.url and f.vcodec ~= "none" then
            local h = f.height or 0
            if (not cap) or h <= cap then
                local score = (f.tbr or 0) + h * 1000
                if worst then score = -score end
                if not pick or score > pick.score then pick = { f = f, score = score } end
            end
        end
    end
    return pick and pick.f
end

local function ytdlp_info(vod_id, cb)
    local cached = st.ytinfo[vod_id]
    if cached then return cb(nil, cached) end
    st.ytinfo_cbs = st.ytinfo_cbs or {}
    local q = st.ytinfo_cbs[vod_id]
    if q then q[#q + 1] = cb; return end
    q = { cb }
    st.ytinfo_cbs[vod_id] = q
    local function finish(err, info)
        if st.ytinfo_cbs[vod_id] == q then st.ytinfo_cbs[vod_id] = nil end
        for _, fn in ipairs(q) do fn(err, info) end
    end
    run({ o.ytdl_path, "-J", "--no-warnings", "--no-playlist", "--socket-timeout", "15",
          "https://www.twitch.tv/videos/" .. vod_id }, 90, function(ok, res)
        if spawn_failed(ok, res) then return finish("ytdl-missing") end
        if res.killed_by_us then return finish("timeout") end
        local stderr = res.stderr or ""
        if res.status ~= 0 then
            if stderr:lower():find("subscri") then return finish("sub-only") end
            local line = stderr:match("ERROR:%s*([^\r\n]+)") or stderr:gsub("%s+$", "")
            return finish("yt-dlp: " .. line)
        end
        local j = utils.parse_json(res.stdout or "")
        if type(j) ~= "table" then return finish("yt-dlp: unparsable output") end
        local f = choose_format(j.formats)
        if not f then return finish("yt-dlp: no video format") end
        local info = { url = f.url, format = f.format_id, height = f.height }
        st.ytinfo[vod_id] = info
        finish(nil, info)
    end)
end

-- ---------------------------------------------------------------------------
-- VOD snapshot: a finished-looking copy of the in-progress playlist
-- ---------------------------------------------------------------------------
local function tmp_dir()
    return os.getenv("TEMP") or os.getenv("TMP") or os.getenv("TMPDIR") or "/tmp"
end

local function add_tmp(path) st.tmpfiles[#st.tmpfiles + 1] = path end

local function cleanup_tmp(keep)
    local rest = {}
    for _, p in ipairs(st.tmpfiles) do
        if p ~= keep then os.remove(p) else rest[#rest + 1] = p end
    end
    st.tmpfiles = rest
end

-- first PES PTS (seconds) over audio/video PIDs in an MPEG-TS buffer; no bit ops
local function ts_first_pts(data)
    local seen, min = {}, nil
    local pos, n = 1, #data
    while pos + 187 <= n do
        if data:byte(pos) ~= 0x47 then
            pos = pos + 1
        else
            local b1, b2, b3 = data:byte(pos + 1, pos + 3)
            local pusi = math.floor(b1 / 64) % 2 == 1
            local pid = (b1 % 32) * 256 + b2
            local afc = math.floor(b3 / 16) % 4
            local off = pos + 4
            if afc >= 2 then off = off + 1 + data:byte(off) end
            if pusi and afc % 2 == 1 and not seen[pid] and data:sub(off, off + 2) == "\0\0\1" then
                local sid = data:byte(off + 3)
                if sid and sid >= 0xC0 and sid <= 0xEF then
                    seen[pid] = true
                    local flags = data:byte(off + 7)
                    if flags and flags >= 128 then
                        local p1, p2, p3, p4, p5 = data:byte(off + 9, off + 13)
                        local pts = (math.floor(p1 / 2) % 8) * 2 ^ 30 + p2 * 2 ^ 22
                                  + math.floor(p3 / 2) * 2 ^ 15 + p4 * 2 ^ 7 + math.floor(p5 / 2)
                        pts = pts / 90000
                        if not min or pts < min then min = pts end
                    end
                end
            end
            pos = pos + 188
        end
    end
    return min
end

local function measure_offset(first_segment_url, cb)
    st.seq = st.seq + 1
    local tmp = string.format("%s/twitch-rewind-%d-%d.ts", tmp_dir(), utils.getpid(), st.seq)
    add_tmp(tmp)
    run({ o.curl_path, "-sS", "-f", "-m", "20", "-r", "0-98303", "-o", tmp, first_segment_url }, 25,
        function(ok, res)
            local pts
            if not spawn_failed(ok, res) and res.status == 0 then
                local f = io.open(tmp, "rb")
                if f then pts = ts_first_pts(f:read("*a") or ""); f:close() end
            end
            os.remove(tmp)
            cb(pts)
        end)
end

-- fetch the media playlist; write a local VOD-type copy with absolute URLs
local function build_snapshot(vod_id, info, cb)
    run({ o.curl_path, "-sS", "-f", "-m", "20", info.url }, 25, function(ok, res)
        if spawn_failed(ok, res) then return cb("curl-missing") end
        if res.status ~= 0 or not res.stdout or not res.stdout:find("#EXTM3U", 1, true) then
            return cb("playlist: " .. ((res.stderr or ""):gsub("%s+$", "")))
        end
        local base = info.url:match("^(.*/)") or ""
        local out, total, finished, first_seg = {}, 0, false, nil
        for line in res.stdout:gmatch("[^\r\n]+") do
            if line:find("^#EXT%-X%-PLAYLIST%-TYPE") then
                line = "#EXT-X-PLAYLIST-TYPE:VOD"
            elseif line:find("^#EXT%-X%-ENDLIST") then
                finished = true
            elseif line:find("^#EXTINF:") then
                total = total + (tonumber(line:match("^#EXTINF:([%d%.]+)")) or 0)
            elseif line:sub(1, 1) ~= "#" then
                if not line:find("^https?://") then line = base .. line end
                first_seg = first_seg or line
            end
            out[#out + 1] = line
        end
        if not first_seg then return cb("playlist: no segments") end
        if not finished then out[#out + 1] = "#EXT-X-ENDLIST" end
        st.seq = st.seq + 1
        local path = string.format("%s/twitch-rewind-%d-%d.m3u8", tmp_dir(), utils.getpid(), st.seq)
        local f = io.open(path, "wb")
        if not f then return cb("cannot write " .. path) end
        f:write(table.concat(out, "\n"), "\n")
        f:close()
        add_tmp(path)
        cb(nil, { path = path, length = total, finished = finished, first_segment = first_seg })
    end)
end

local function ensure_offset(vod_id, first_segment, cb)
    local known = st.offsets[vod_id]
    if known then return cb(known) end
    local function fallback()
        local r = { value = o.pts_offset, measured = false }
        st.offsets[vod_id] = r
        cb(r)
    end
    if not o.calibrate then return fallback() end
    measure_offset(first_segment, function(pts)
        if pts then
            local r = { value = pts, measured = true }
            st.offsets[vod_id] = r
            cb(r)
        else
            msg.warn("could not measure PTS offset; using pts_offset=" .. o.pts_offset)
            fallback()
        end
    end)
end

-- ---------------------------------------------------------------------------
-- lookup bookkeeping
-- ---------------------------------------------------------------------------
local function apply_lookup(info)
    st.lookup = info
    local v = info.vod
    st.vod_id = v and v.id or st.vod_id
    local created = info.stream_created or (v and v.created)
    local epoch = created and iso_to_epoch(created)
    st.date = epoch and os.date("%Y-%m-%d", epoch) or st.date
    st.title = info.title or st.title
    apply_title()
    publish()
end

local function ensure_lookup(cb, force)
    if not force and st.lookup and st.lookup.live and st.lookup.vod then return cb(nil, st.lookup) end
    local channel = st.channel
    if st.lookup_waiters and st.lookup_waiters.channel == channel then
        local callbacks = st.lookup_waiters.callbacks
        callbacks[#callbacks + 1] = cb
        return
    end
    local pending = { channel = channel, callbacks = { cb } }
    st.lookup_waiters = pending
    lookup_channel(channel, function(err, info)
        if st.lookup_waiters == pending then st.lookup_waiters = nil end
        if channel == st.channel and not err then apply_lookup(info) end
        for _, w in ipairs(pending.callbacks) do w(err, info) end
    end)
end

local function describe_error(err)
    if err == "curl-missing" then
        return "curl not found (set curl_path in script-opts/twitch-rewind.conf)"
    elseif err == "ytdl-missing" then
        return "yt-dlp not found (set ytdl_path in script-opts/twitch-rewind.conf)"
    elseif err == "sub-only" then
        return "this VOD is subscriber-only"
    elseif err == "timeout" then
        return "lookup timed out"
    end
    return "lookup failed: " .. tostring(err)
end

-- ---------------------------------------------------------------------------
-- switching
-- ---------------------------------------------------------------------------
local function channel_url() return "https://www.twitch.tv/" .. st.channel end

local function load_snapshot(snap, vod_time, off, vod, play_override)
    local title = st.title or (vod and vod.title) or string.format("%s - VOD %s (%s)", st.channel, vod.id, st.date or "?")
    st.snapshot_path = snap.path
    st.snapshot_inprog = not snap.finished
    st.pending_info = { start = vod_time, offset = off, length = snap.length }
    local opts = {
        start = string.format("%.3f", vod_time),
        ["force-media-title"] = title,
        ["force-seekable"] = "yes",
        ["loop-file"] = "no",
        ["keep-open"] = "yes",
        ["demuxer-lavf-o"] = "protocol_whitelist=[file,tcp,tls,https,http,crypto,data]",
    }
    if play_override ~= nil then
        opts["pause"] = play_override and "no" or "yes"
    end
    if o.manage_cache then
        opts["demuxer-readahead-secs"] = tostring(o.vod_readahead)
        opts["cache"] = "yes"
        opts["demuxer-max-bytes"] = o.vod_max_bytes
        opts["demuxer-max-back-bytes"] = o.vod_back_bytes
    end
    local _, err = mp.command_native({ name = "loadfile", url = snap.path, flags = "replace", options = opts })
    if err then
        osd("Twitch: could not start VOD playback: " .. tostring(err), 6)
    end
end

local function internal_seek(...)
    st.ignore_seeks = (st.ignore_seeks or 0) + 1
    mp.commandv("seek", ...)
end

local function cache_range(pos)
    local s = mp.get_property_native("demuxer-cache-state")
    local rs = s and s["seekable-ranges"]
    if not rs or #rs == 0 then return nil end
    for _, r in ipairs(rs) do
        if pos >= r.start - 1 and pos <= r["end"] + 1 then return r end
    end
    return rs[#rs]
end

-- Resolve <vod> ({id=...}) and play it from a local snapshot of its playlist.
-- spec: {pts=<live time-pos>} or {vod=<VOD seconds>}
local function open_vod(vod, spec, job, fail)
    local function with_snapshot(snap)
        ensure_offset(vod.id, snap.first_segment, function(off)
            if job ~= st.job then return end
            local cur = st.switch_spec or spec
            local t = cur.vod or (cur.pts - off.value)
            if cur.pts and st.kind == "live" and t > snap.length - 5 then
                -- the VOD lags live by a minute or two: that moment is not in it yet
                local r = cache_range(st.pos or cur.pts)
                if r then internal_seek(string.format("%.3f", r.start), "absolute", "exact") end
                st.switching = false
                return osd(string.format("Twitch: that moment is not in the VOD yet (VOD ends at %s, live is at %s)",
                    fmt_time(snap.length), fmt_time((st.pos or cur.pts) - off.value)), 5)
            end
            t = math.max(0, math.min(t, math.max(0, snap.length - 3)))
            msg.info(string.format("map: live pts %s -> VOD %s %.3f s (offset %.3f %s, VOD length %.0f s)",
                cur.pts and string.format("%.3f", cur.pts) or "-", vod.id, t, off.value,
                off.measured and "measured" or "fallback", snap.length))
            st.switching = false
            load_snapshot(snap, t, off, vod, cur.play)
        end)
    end
    local function attempt(retry)
        ytdlp_info(vod.id, function(err, yt)
            if job ~= st.job then return end
            if err then return fail(err) end
            build_snapshot(vod.id, yt, function(err2, snap)
                if job ~= st.job then return end
                if err2 then
                    st.ytinfo[vod.id] = nil      -- signed URL may have expired; re-resolve once
                    if retry then return attempt(false) end
                    return fail(err2)
                end
                with_snapshot(snap)
            end)
        end)
    end
    attempt(true)
end

local function new_job(text)
    st.job = st.job + 1
    local job = st.job
    osd(text, 30)
    return job, function(err)
        if job ~= st.job then return end
        osd("Twitch: " .. describe_error(err), 6)
    end
end

local function switch_to_vod(spec)
    if st.kind ~= "live" or not st.channel then return end
    st.switch_spec = spec
    if st.switching then return end
    st.switching = true
    local job, fail = new_job("Twitch: switching to VOD...")
    local function done_fail(err)
        if job == st.job then st.switching = false end
        fail(err)
    end
    ensure_lookup(function(err, info)
        if job ~= st.job then return end
        if err then return done_fail(err) end
        local vod = info.vod or (st.vod_id and { id = st.vod_id })
        if not vod then
            st.switching = false
            if not info.live then return osd("Twitch: " .. st.channel .. " is offline", 5) end
            return osd("Twitch: no VOD for this broadcast (VODs disabled, subscriber-only or not published yet)", 7)
        end
        open_vod(vod, spec, job, done_fail)
    end, false)
end

local function go_live(reason)
    if not st.channel then return osd("Twitch: not a Twitch stream") end
    if st.kind == "live" then
        internal_seek("100", "absolute-percent", "exact")
        return osd("Twitch: jumped to live edge", 2)
    end
    local job, fail = new_job("Twitch: returning to live...")
    lookup_channel(st.channel, function(err, info)
        if job ~= st.job then return end
        if err then return fail(err) end
        if not info.live then return osd("Twitch: " .. st.channel .. " is offline (broadcast ended)", 5) end
        st.go_live_reason = reason
        mp.commandv("loadfile", channel_url(), "replace")
    end)
end

-- ---------------------------------------------------------------------------
-- commands
-- ---------------------------------------------------------------------------
local function live_seek_to_pts(target, from_pos)
    local r = cache_range(from_pos or target)
    if r and target >= r.start - o.cache_margin then
        internal_seek(string.format("%.3f", target), "absolute", "exact")
    else
        switch_to_vod({ pts = target })
    end
end

local function cmd_back(secs)
    secs = tonumber(secs)
    if not secs then return end
    if st.kind == "live" then
        local pos = st.pos or mp.get_property_number("time-pos")
        if not pos then return end
        live_seek_to_pts(pos - secs, pos)
    elseif st.kind then
        mp.commandv("seek", tostring(-secs), "relative", "exact")
    end
end

local function cmd_forward(secs)
    secs = tonumber(secs)
    if not secs or not st.kind then return end
    mp.commandv("seek", tostring(secs), "relative", "exact")
end

local function cmd_goto(arg)
    local t = parse_time(arg)
    if not t then return osd("Twitch: cannot parse time '" .. tostring(arg) .. "' (use 1:23:45, 83m, 1h2m3s or seconds)", 5) end
    if st.kind == "live" then
        local off = st.vod_id and st.offsets[st.vod_id]
        if off then
            live_seek_to_pts(t + off.value, st.pos)
        else
            switch_to_vod({ vod = t })
        end
    elseif st.kind then
        mp.commandv("seek", string.format("%.3f", t), "absolute", "exact")
    end
end

local function cmd_goto_prompt()
    mp.commandv("script-message-to", "console", "type",
                "script-message-to " .. mp.get_script_name() .. " goto ")
end

local function cmd_seek_percent(pct_str, was_paused_str)
    local pct = tonumber(pct_str)
    if not pct or not st.kind then return end
    local play = was_paused_str ~= nil and (was_paused_str ~= "yes") or nil
    if st.kind == "live" then
        local dur = mp.get_property_number("duration")
        if dur and dur > 0 then
            -- With a measured offset the percentage is on the broadcast timeline the seekbar shows
            -- (VOD time 0 .. live edge), otherwise on mpv's live window.
            local off = st.vod_id and st.offsets[st.vod_id]
            local want = off and (off.value + (dur - off.value) * pct / 100) or (dur * pct / 100)
            local r = cache_range(st.pos or want)
            if r and want >= r.start - o.cache_margin then
                internal_seek(string.format("%.3f", want), "absolute", "exact")
                if play ~= nil then mp.set_property_bool("pause", not play) end
            else
                switch_to_vod({ pts = want, play = play })
            end
            return
        end
    end
    mp.commandv("seek", string.format("%.3f", pct), "absolute-percent+exact")
    if play ~= nil then mp.set_property_bool("pause", not play) end
end

mp.register_script_message("back", cmd_back)
mp.register_script_message("forward", cmd_forward)
mp.register_script_message("goto", cmd_goto)
mp.register_script_message("seek-percent", cmd_seek_percent)
mp.register_script_message("live", function() go_live("requested") end)
mp.register_script_message("toggle", function()
    if st.kind == "live" then cmd_back(300) else go_live("requested") end
end)

-- Other scripts (clipper) ask for a seekable playlist of the broadcast's VOD; the answer is sent as
-- `script-message-to <reply_to> dvr-snapshot <path> <length seconds> <error>`. The file is temporary.
mp.register_script_message("snapshot", function(reply_to)
    local function reply(path, length, err)
        mp.commandv("script-message-to", reply_to, "dvr-snapshot", path or "", tostring(length or 0), err or "")
    end
    if not st.channel then return reply(nil, 0, "not a Twitch stream") end
    ensure_lookup(function(err, info)
        if err then return reply(nil, 0, describe_error(err)) end
        local vod = info.vod or (st.vod_id and { id = st.vod_id })
        if not vod then return reply(nil, 0, "no VOD for this broadcast") end
        ytdlp_info(vod.id, function(e2, yt)
            if e2 then return reply(nil, 0, describe_error(e2)) end
            build_snapshot(vod.id, yt, function(e3, snap)
                if e3 then return reply(nil, 0, describe_error(e3)) end
                reply(snap.path, snap.length)
            end)
        end)
    end, false)
end)

mp.add_key_binding(nil, "live", function() go_live("requested") end)
mp.add_key_binding(nil, "back-30s", function() cmd_back(30) end)
mp.add_key_binding(nil, "back-1m", function() cmd_back(60) end)
mp.add_key_binding(nil, "back-5m", function() cmd_back(300) end)
mp.add_key_binding(nil, "back-15m", function() cmd_back(900) end)
mp.add_key_binding(nil, "back-1h", function() cmd_back(3600) end)
mp.add_key_binding(nil, "goto-prompt", cmd_goto_prompt)

-- ---------------------------------------------------------------------------
-- ordinary seeks: watch mpv's own "Run command: seek" log line
-- ---------------------------------------------------------------------------
local function end_of_vod(by_seek)
    if st.kind ~= "snapshot" or not st.snapshot_inprog or not o.live_on_end or st.leaving then return end
    st.leaving = true
    if by_seek then
        osd("Twitch: reached the end of the in-progress VOD, returning to live", 3)
        return go_live("end of VOD")
    end
    local job = st.job
    local old_dur = mp.get_property_number("duration") or (st.pending_info and st.pending_info.length) or 0
    local vod_id = st.vod_id
    if not vod_id then return go_live("end of VOD") end
    ytdlp_info(vod_id, function(err, yt)
        if job ~= st.job then return end
        if err then return go_live("end of VOD") end
        build_snapshot(vod_id, yt, function(err2, snap)
            if job ~= st.job then return end
            if not err2 and snap and snap.length > old_dur + 15 then
                local off = st.offsets[vod_id] or { value = o.pts_offset, measured = false }
                st.leaving = false
                return load_snapshot(snap, old_dur, off, { id = vod_id, title = st.title }, not st.paused)
            end
            osd("Twitch: reached the end of the in-progress VOD, returning to live", 3)
            go_live("end of VOD")
        end)
    end)
end

-- FFmpeg's HLS demuxer rejects a seek that lands before the first packet it read
-- (the VOD's first audio frame is ~17 ms after the stream's start_time, which is
-- where mpv aims a seek to 0). mpv then keeps reading from wherever it was but
-- marks that spot as the beginning of the file, so every later seek "back" is
-- clamped to it. Drop the poisoned cache and seek just past the start instead.
local START_SEEK = 0.1
local function repair_start_seek()
    -- only when the seek that failed was aimed at the start; other failures (past the end, ...) are not ours
    local want = st.last_seek_want
    st.last_seek_want = nil
    if not want or want > START_SEEK / 2 then return end
    local now = mp.get_time()
    if st.repair_at and now - st.repair_at < 2 then return end
    st.repair_at = now
    msg.info("seek to the start of the VOD was rejected by the demuxer; retrying")
    mp.commandv("drop-buffers")
    internal_seek(string.format("%.3f", START_SEEK), "absolute", "exact")
end

mp.register_event("log-message", function(e)
    if st.kind ~= "live" and st.kind ~= "snapshot" then return end
    if e.prefix == "lavf" then
        if st.kind == "snapshot" and e.text:find("^Seek failed") then repair_start_seek() end
        return
    end
    if e.prefix ~= "cplayer" then return end
    local args = e.text:match("^Run command: seek,.-args=%[(.*)%]")
    if not args then return end
    if (st.ignore_seeks or 0) > 0 then
        st.ignore_seeks = st.ignore_seeks - 1
        return
    end
    local target = tonumber(args:match('target="([^"]*)"'))
    local flags = args:match('flags="([^"]*)"') or "relative"
    local pos = st.pos
    local dur = mp.get_property_number("duration")
    if not target or not pos then return end
    local want
    if flags:find("absolute%-percent") then
        if not dur then return end
        want = dur * target / 100
    elseif flags:find("relative%-percent") then
        if not dur then return end
        want = pos + dur * target / 100
    elseif flags:find("absolute") then
        want = target
    else
        want = ((st.kind == "live" and st.switching and st.switch_spec and st.switch_spec.pts) or pos) + target
    end
    if st.kind == "snapshot" then
        st.last_seek_want = want
        if o.auto_seek and dur and want >= dur - 1 then end_of_vod(true) end
        return
    end
    if not o.auto_seek then return end
    local r = cache_range(pos)
    if r and want < r.start - o.cache_margin then
        msg.info(string.format("seek to %.1f is outside the cache (starts %.1f)", want, r.start))
        switch_to_vod({ pts = want })
    end
end)

local function set_seek_watch(on)
    mp.enable_messages(on and "debug" or "no")
end

local function update_live_edge(pos)
    if st.kind ~= "live" then return end
    local max_pts = pos
    local r = pos and cache_range(pos)
    if r and r["end"] and (not max_pts or r["end"] > max_pts) then max_pts = r["end"] end
    local dur = mp.get_property_number("duration")
    if dur and (not max_pts or dur > max_pts) then max_pts = dur end
    if max_pts and (not st.live_edge_pts or max_pts > st.live_edge_pts) then
        st.live_edge_pts = max_pts
        st.live_edge_wall = mp.get_time()
    end
end

mp.observe_property("seeking", "bool", function(_, v) st.seeking = v and true or false end)
mp.observe_property("time-pos", "number", function(_, v)
    if not v or st.seeking then return end
    st.pos = v
    if st.kind == "live" then
        update_live_edge(v)
    elseif st.kind == "snapshot" then
        local dur = mp.get_property_number("duration")
        if dur and v >= dur - 0.5 then end_of_vod(false) end
    end
end)

mp.observe_property("duration", "number", function(_, dur)
    if st.kind == "live" and dur then update_live_edge(st.pos) end
end)

mp.observe_property("pause", "bool", function(_, paused)
    local was_paused = st.paused
    st.paused = paused == true
    if was_paused and not st.paused and st.kind == "live" and not st.switching then
        local pos = st.pos or mp.get_property_number("time-pos")
        local r = pos and cache_range(pos)
        local cache_end = (r and r["end"]) or pos or 0
        local expected_live = (st.live_edge_pts or cache_end) + (mp.get_time() - (st.live_edge_wall or mp.get_time()))
        if (expected_live - cache_end > 20) or mp.get_property_bool("eof-reached") then
            switch_to_vod({ pts = pos or cache_end, play = true })
        end
    end
end)

mp.observe_property("eof-reached", "bool", function(_, v)
    if not v then return end
    if st.kind == "snapshot" then
        end_of_vod(false)
    elseif st.kind == "live" and st.pos and not st.paused and not st.switching then
        switch_to_vod({ pts = st.pos, play = true })
    end
end)

-- ---------------------------------------------------------------------------
-- file lifecycle
-- ---------------------------------------------------------------------------
local function classify(path)
    if not path then return nil end
    if st.snapshot_path and path == st.snapshot_path then return "snapshot" end
    local host, rest = path:match("^https?://([^/]+)/([^?#]*)")
    if not host or not ({ ["twitch.tv"]=true, ["www.twitch.tv"]=true, ["m.twitch.tv"]=true })[host:lower()] then return nil end
    local id = rest:match("^videos/(%d+)/?$")
    if id then return "vod", nil, id end
    local seg1 = rest:match("^([%w_]+)")
    if not seg1 then return nil end
    if RESERVED[seg1:lower()] then return nil end
    if rest:match("^[%w_]+/?$") then return "live", seg1:lower() end
    return nil
end

local function apply_kind_options(kind)
    mp.set_property("file-local-options/loop-file", "no")
    if kind == "live" then
        mp.set_property("file-local-options/start", "none")
        mp.set_property("file-local-options/save-position-on-quit", "no")
    end
    if not o.manage_cache or kind == "snapshot" then return end
    local function fl(name, v) mp.set_property("file-local-options/" .. name, tostring(v)) end
    fl("cache", "yes")
    if kind == "live" then
        fl("force-seekable", "no")
        fl("cache-pause-initial", "no")
        fl("demuxer-readahead-secs", o.live_readahead)
        fl("demuxer-max-bytes", o.live_max_bytes)
        fl("demuxer-max-back-bytes", o.live_back_bytes)
    else
        fl("demuxer-readahead-secs", o.vod_readahead)
        fl("demuxer-max-bytes", o.vod_max_bytes)
        fl("demuxer-max-back-bytes", o.vod_back_bytes)
        fl("force-seekable", "yes")
    end
end

local function prefetch_vod(vod_id)
    local job = st.job
    ytdlp_info(vod_id, function(e2, yt)
        if e2 then return msg.warn("prefetch: " .. tostring(e2)) end
        if job ~= st.job or st.switching or not o.calibrate or st.offsets[vod_id] then return end
        build_snapshot(vod_id, yt, function(e3, snap)
            if e3 or not snap then return end
            os.remove(snap.path)
            if job ~= st.job or st.switching or st.offsets[vod_id] then return end
            ensure_offset(vod_id, snap.first_segment, function()
                if job == st.job then publish() end
            end)
        end)
    end)
end

mp.add_hook("on_load", 50, function()
    local kind, channel, vod = classify(mp.get_property("path"))
    st.job = st.job + 1                      -- cancel in-flight switches
    st.pos, st.leaving = nil, false
    st.switching, st.switch_spec, st.ignore_seeks, st.last_seek_want = false, nil, 0, nil
    st.live_edge_pts, st.live_edge_wall = nil, nil
    if kind == "live" then
        if channel ~= st.channel then
            st.lookup, st.vod_id, st.date, st.title = nil, nil, nil, nil
        end
        st.channel = channel
        st.snapshot_path = nil
    elseif kind == "vod" then
        st.channel, st.lookup, st.vod_id, st.date, st.title = nil, nil, vod, nil, nil
    elseif kind == nil then
        st.channel, st.lookup, st.vod_id, st.date, st.title = nil, nil, nil, nil, nil
        st.snapshot_path = nil
    end
    st.loading_kind = kind
    if kind then apply_kind_options(kind) end
end)

mp.register_event("file-loaded", function()
    local kind = st.loading_kind
    st.kind = kind
    if not kind then
        set_seek_watch(false)
        publish()
        cleanup_tmp(nil)
        return
    end
    st.mode = (kind == "live") and "live" or "vod"
    apply_kind_options(kind)                 -- re-assert in case a profile re-applied
    cleanup_tmp(st.snapshot_path)
    if kind == "live" then
        set_seek_watch(true)
        local desc = non_empty(mp.get_property("metadata/by-key/ytdl_description"))
        if desc then
            st.title = desc
            apply_title()
        end
        update_live_edge(mp.get_property_number("time-pos"))
        publish()
        if st.go_live_reason then
            osd("Twitch: live", 2)
            st.go_live_reason = nil
        end
        ensure_lookup(function(err, info)
            if err then return msg.warn("lookup: " .. tostring(err)) end
            if o.prefetch and info.vod then
                prefetch_vod(info.vod.id)
            end
        end, true)
    elseif kind == "snapshot" then
        set_seek_watch(true)
        apply_title()
        publish()
        local pi = st.pending_info
        if pi then
            osd(string.format("Twitch: VOD at %s  (go-live key returns to live)",
                fmt_time(pi.start)), 5)
        end
    else -- direct /videos/<id> URL
        set_seek_watch(false)
        publish()
        local job = st.job
        lookup_video(st.vod_id, function(err, v)
            if err or job ~= st.job then return end
            st.channel = v.owner and v.owner.login and v.owner.login:lower() or nil
            st.title = non_empty(v.title) or st.title
            local epoch = v.createdAt and iso_to_epoch(v.createdAt)
            st.date = epoch and os.date("%Y-%m-%d", epoch) or nil
            apply_title()
            publish()
            -- mpv plays an in-progress VOD's EVENT playlist like a live stream
            -- (from its end, no seeking outside the cache); reopen it from a
            -- seekable snapshot, at the start unless the user asked for --start.
            if v.status == "RECORDING" and st.channel then
                local t = 0
                if mp.get_property("start", "none") ~= "none" then
                    t = mp.get_property_number("time-pos", 0)
                end
                local job2, fail = new_job("Twitch: VOD is still recording, making it seekable...")
                open_vod({ id = st.vod_id, title = st.title }, { vod = t }, job2, fail)
            end
        end)
    end
end)

mp.register_event("end-file", function(e)
    st.kind = nil
    st.switching, st.switch_spec = false, nil
    mp.del_property("user-data/twitch")
end)

mp.register_event("shutdown", function()
    for id in pairs(subprocesses) do mp.abort_async_command(id) end
    mp.del_property("user-data/twitch")
    cleanup_tmp(nil)
end)
