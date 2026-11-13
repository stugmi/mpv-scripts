local mp = require 'mp'
local utils = require 'mp.utils'
local windows = package.config:sub(1, 1) == '\\'
local opt = { python = windows and 'python' or 'python3', mpv = '', ffmpeg = 'ffmpeg',
              output = '~/Videos/Clips', seconds = 30, backread = 60, history = 300, osc_button = true,
              pause_on_clip = true, match_titlebar = true, stream_tips = true, stream_back_bytes = '' }
require('mp.options').read_options(opt, 'clipper')
local worker = utils.join_path(mp.get_script_directory(), 'worker.py')
local preparing = false
local generation = 0
mp.register_event('start-file', function() generation = generation + 1 end)

local function notify(message)
    mp.osd_message(message, 4)
    mp.msg.info(message)
end

local function python_args(...)
    local args={opt.python}
    local exe=opt.python:lower():match('[^/\\]+$')
    if windows and (exe=='py' or exe=='py.exe') then args[#args+1]='-3' end
    for _, arg in ipairs({...}) do args[#args+1]=arg end
    return args
end

-- modernz's hover colour as ASS BBGGRR, or nil without modernz.
local function modernz_hover()
    local file = io.open(mp.command_native({'expand-path', '~~/scripts/modernz.lua'}), 'rb')
    if not file then return end
    file:close()
    local color = 'FF8232' -- modernz's built-in default
    local conf = io.open(mp.command_native({'expand-path', '~~/script-opts/modernz.conf'}), 'rb')
    if conf then
        for line in conf:lines() do
            color = line:match('^%s*hover_effect_color%s*=%s*#?(%x%x%x%x%x%x)%s*$') or color
        end
        conf:close()
    end
    return color:sub(5, 6) .. color:sub(3, 4) .. color:sub(1, 2)
end

-- A stream's duration keeps growing while it is watched. That holds without yt-dlp metadata,
-- which older ytdl hooks do not publish.
local growth, last_duration = 0, nil
mp.register_event('start-file', function() growth, last_duration = 0, nil end)
mp.observe_property('duration', 'number', function(_, value)
    if value and last_duration and value > last_duration + 0.2 then growth = growth + 1 end
    last_duration = value
end)

-- twitch-rewind plays a broadcast's VOD from a local playlist file whose segments are remote. That file is an
-- index, not a clip source the editor can open, but it is seekable, so clips are cut from it.
local function dvr_playlist()
    local twitch = mp.get_property_native('user-data/twitch')
    return type(twitch) == 'table' and not (mp.get_property('path') or ''):find('^%a[%w+.-]*://')
end

-- A live or unseekable source, where clips come from the cache instead of the file.
local function stream_info()
    if dvr_playlist() then return true end
    local duration = mp.get_property_number('duration', 0) or 0
    if duration <= 0 or not mp.get_property_native('seekable') or growth >= 2 then return true end
    local meta = mp.get_property_native('user-data/mpv/ytdl/json-subprocess-result')
    local info = type(meta) == 'table' and type(meta.stdout) == 'string' and utils.parse_json(meta.stdout) or nil
    if type(info) == 'table' and (info.is_live == true or info.live_status == 'is_live') then return true end
    -- In the first seconds of a live playlist, the cache already ends where the duration does.
    local cache = mp.get_property_native('demuxer-cache-state') or {}
    return (mp.get_property('file-format') or ''):find('hls') ~= nil and not cache['eof-cached']
        and cache['cache-end'] ~= nil and duration - cache['cache-end'] < 1
end

-- Where a clip came from, for sources a path does not describe. Local files use their full path.
local vod_dates = {}
local function twitch_vod() return (mp.get_property('path') or ''):match('twitch%.tv/videos/(%d+)') end
mp.register_event('file-loaded', function()
    local vod = twitch_vod()
    if not vod or vod_dates[vod] then return end
    mp.command_native_async({name='subprocess', playback_only=false, capture_stdout=true, capture_stderr=true,
        args={'yt-dlp', '--no-download', '--no-warnings', '-O', '%(upload_date>%Y-%m-%d)s', mp.get_property('path')}},
        function(ok, result)
            local date = ok and result and result.status == 0 and (result.stdout or ''):match('%d%d%d%d%-%d%d%-%d%d')
            if date then vod_dates[vod] = date end
        end)
end)
local function origin(live)
    local path = mp.get_property('path') or ''
    local known = mp.get_property_native('user-data/twitch')
    if type(known) ~= 'table' then known = {} end
    -- twitch-rewind plays a broadcast's VOD from a temporary playlist, so the path alone names nothing.
    if not path:find('twitch%.tv/') and not known.channel then return end
    local vod = twitch_vod() or (known.mode == 'vod' and known.vod_id) or nil
    local channel = known.channel or (not vod and path:match('twitch%.tv/([%w_]+)'))
        or (mp.get_property_native('metadata') or {}).uploader
    local date = known.date or (vod and vod_dates[vod]) or (live and not vod and os.date('%Y-%m-%d'))
    return 'twitch.tv/' .. (channel or '?') .. (vod and (' · VOD ' .. vod) or ' · live stream')
        .. (date and (' · ' .. date) or '')
end

local function read_json(file_path)
    local file = io.open(file_path, 'rb')
    if not file then return end
    local text = file:read('*a')
    file:close()
    return utils.parse_json(text)
end
local function write_json(folder, name, value)
    local staged = utils.join_path(folder, name .. '.tmp')
    local file = io.open(staged, 'wb')
    if not file then return end
    file:write(utils.format_json(value))
    file:close()
    os.remove(utils.join_path(folder, name))
    os.rename(staged, utils.join_path(folder, name))
end

-- The cached range that holds a moment of the stream. Ranges end on a keyframe, so at the live edge
-- the playhead can be a few seconds past the end of the range it is playing from.
local function cached_range(t)
    local state = mp.get_property_native('demuxer-cache-state') or {}
    for _, range in ipairs(state['seekable-ranges'] or {}) do
        if range.start <= t + 0.5 and range['end'] >= t - 10 then return range end
    end
end

local function sibling_tool(name)
    local path = opt.ffmpeg or 'ffmpeg'
    local replaced, count = path:gsub('[Ff][Ff][Mm][Pp][Ee][Gg](%.?%a*)$', name .. '%1')
    return count > 0 and replaced or name
end

local WHITELIST = 'file,tcp,tls,https,http,crypto,data'

-- Runs a tool without blocking the player. cb(stdout) on success, cb(nil, message) on failure.
local function run_tool(args, cb)
    mp.command_native_async({name='subprocess', playback_only=false, capture_stdout=true, capture_stderr=true, args=args},
        function(ok, result)
            if not ok or not result or result.status ~= 0 then
                local text = (result and (result.stderr or '') or ''):gsub('%s+$', '')
                return cb(nil, text ~= '' and text or (args[1] .. ' did not run (check ffmpeg in clipper.conf)'))
            end
            cb(result.stdout or '')
        end)
end

-- Cuts [first, last] out of a playlist with a stream copy, so only those segments are fetched. Positions are
-- seconds on the playlist's own timeline, which starts at `origin_ts` (its demuxer start time; the main
-- player's by default). A copy begins on the keyframe at or before `first`, so the capture's real first
-- position is measured and handed to done(start). On failure done(nil, message).
local function cut_playlist(source, first, last, out, done, origin_ts)
    local staged = out .. '.abs.mkv'
    origin_ts = origin_ts or mp.get_property_number('demuxer-start-time', 0) or 0
    -- Timestamps stay absolute in this first file (-copyts), so its end is an absolute time too, and the
    -- position of its first packet can be probed.
    run_tool({opt.ffmpeg, '-v', 'error', '-y', '-protocol_whitelist', WHITELIST, '-ss', ('%.3f'):format(first), '-i', source,
              '-to', ('%.3f'):format(last + origin_ts), '-map', '0:v:0', '-map', '0:a:0?', '-c', 'copy', '-copyts', '-f', 'matroska', staged},
        function(_, err)
            if err then os.remove(staged); return done(nil, err) end
            run_tool({sibling_tool('ffprobe'), '-v', 'error', '-show_entries', 'format=start_time', '-of', 'csv=p=0', staged},
                function(text, perr)
                    local absolute = tonumber((text or ''):match('[%d%.]+'))
                    if perr or not absolute then os.remove(staged); return done(nil, perr or 'ffprobe could not read the cut') end
                    -- Then shift the capture to start at zero, like a cache dump does.
                    run_tool({opt.ffmpeg, '-v', 'error', '-y', '-i', staged, '-c', 'copy', '-copyts',
                              '-output_ts_offset', ('%.6f'):format(-absolute), '-f', 'matroska', out},
                        function(_, rerr)
                            os.remove(staged)
                            if rerr then return done(nil, rerr) end
                            done(absolute - origin_ts)
                        end)
                end)
        end)
end

-- Joins two captures end to start into `out` (stream copy).
local function concat_files(first, second, out, done)
    local list = out .. '.txt'
    local file = io.open(list, 'wb')
    if not file then return done('Cannot write ' .. list) end
    for _, name in ipairs({first, second}) do
        file:write("file '", (name:gsub('\\', '/'):gsub("'", "'\\''")), "'\n")
    end
    file:close()
    run_tool({opt.ffmpeg, '-v', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', list, '-c', 'copy', '-f', 'matroska', out},
        function(_, err) os.remove(list); done(err) end)
end

-- While live, twitch-rewind can build a seekable playlist of the broadcast's VOD, which holds footage that has
-- left the live cache. Copied into the session folder, it outlives twitch-rewind's own temporary file.
local snapshot_waiter
mp.register_script_message('dvr-snapshot', function(path, length, err)
    local waiter = snapshot_waiter
    snapshot_waiter = nil
    if waiter then waiter(path, tonumber(length), err) end
end)
local function vod_playlist(session, cached, done)
    if cached.value then return done(cached.value) end
    if snapshot_waiter then return done(nil, 'Still preparing the VOD. Try again in a moment.') end
    snapshot_waiter = function(path, length, err)
        if not path or path == '' then return done(nil, 'No VOD to read earlier footage from: ' .. tostring(err)) end
        local source = io.open(path, 'rb')
        if not source then return done(nil, 'The VOD playlist is gone.') end
        local text = source:read('*a')
        source:close()
        local copy = utils.join_path(session, 'vod.m3u8')
        local target = io.open(copy, 'wb')
        if not target then return done(nil, 'Cannot write ' .. copy) end
        target:write(text)
        target:close()
        -- The playlist's own timeline starts at its first packet.
        run_tool({sibling_tool('ffprobe'), '-v', 'error', '-protocol_whitelist', WHITELIST, '-show_entries', 'format=start_time',
                  '-of', 'csv=p=0', copy}, function(out, perr)
            local origin = tonumber((out or ''):match('[%d%.]+'))
            if not origin then return done(nil, perr or 'Cannot read the VOD playlist.') end
            cached.value = {path=copy, length=length, origin=origin}
            done(cached.value)
        end)
    end
    notify('Reading the VOD for earlier footage…')
    mp.commandv('script-message-to', 'twitch_rewind', 'snapshot', mp.get_script_name())
end

-- Serves an editor's requests for more of the stream from this player's cache. Each answer is a new
-- dump of the whole wanted range that keeps one end where it was, so the editor can line it up exactly.
local function serve_fetches(session, original, dvr_source, vod_offset)
    local busy, timer = false, nil
    local current_media, vod_cache = 'capture.mkv', {}
    local function finish(result)
        busy = false
        if result.ok and result.file then current_media = result.file end
        write_json(session, 'fetched.json', result)
    end
    local function dump(request, first, last, exact)
        local name = ('part-%d.mkv'):format(request.id)
        write_json(session, 'fetch-status.json', {id=request.id, state='dumping', file=name})
        mp.command_native_async({'dump-cache', tostring(first), tostring(last), utils.join_path(session, name)},
            function(done, _, reason)
                if not done then return finish({id=request.id, ok=false, message='Cache capture failed: ' .. tostring(reason)}) end
                finish({id=request.id, ok=true, file=name, start=first, ['end']=last, exact=exact})
            end)
    end
    local function fail(request, message) finish({id=request.id, ok=false, message=message}) end
    -- DVR playlist: the whole VOD is reachable, so more footage is cut from it, not taken from the cache.
    local function handle_dvr(request)
        local first, last = request.have_start, request.have_end
        if request.side == 'before' then
            first = math.max(0.1, first - request.seconds)
            if request.have_start - first < 1 then return fail(request, 'This is the start of the VOD.') end
        else
            -- Start just after the earlier capture's first frame so the cut begins on the same keyframe.
            first = first + 0.1
            last = math.min(mp.get_property_number('duration', 0), last + request.seconds)
            if last - request.have_end < 1 then return fail(request, 'This is the end of the downloaded VOD.') end
        end
        local name = ('part-%d.mkv'):format(request.id)
        write_json(session, 'fetch-status.json', {id=request.id, state='dumping', file=name})
        cut_playlist(dvr_source, first, last, utils.join_path(session, name), function(start, err)
            if not start then return fail(request, 'Could not cut the VOD: ' .. tostring(err)) end
            finish({id=request.id, ok=true, file=name, start=start, ['end']=last, exact=true})
        end)
    end
    -- Live on Twitch: footage older than the cache is cut from the VOD up to where the current capture begins,
    -- and joined to the capture. A live time-pos is the stream's own timestamp, so VOD time = live time - vod_offset.
    local function handle_vod_before(request)
        vod_playlist(session, vod_cache, function(vod, err)
            if not vod then return fail(request, err) end
            local join = request.have_start - vod_offset
            if join > vod.length - 2 then
                return fail(request, 'That footage is not in the VOD yet. Try again in a minute.')
            end
            local first = math.max(0.1, join - request.seconds)
            if join - first < 1 then return fail(request, 'This is the start of the broadcast.') end
            local name = ('part-%d.mkv'):format(request.id)
            local head = utils.join_path(session, ('part-%d-head.mkv'):format(request.id))
            write_json(session, 'fetch-status.json', {id=request.id, state='dumping', file=name})
            cut_playlist(vod.path, first, join, head, function(start, cut_err)
                if not start then return fail(request, 'Could not cut the VOD: ' .. tostring(cut_err)) end
                concat_files(head, utils.join_path(session, current_media), utils.join_path(session, name), function(join_err)
                    os.remove(head)
                    if join_err then return fail(request, 'Could not join the footage: ' .. tostring(join_err)) end
                    finish({id=request.id, ok=true, file=name, start=start + vod_offset, ['end']=request.have_end, exact=false})
                end)
            end, vod.origin)
        end)
    end
    -- Live on Twitch, once the capture reaches back past the cache: later footage is cut from the VOD too,
    -- as one cut of the whole capture's range.
    local function handle_vod_after(request)
        vod_cache.value = nil   -- the VOD has grown since it was first read
        vod_playlist(session, vod_cache, function(vod, err)
            if not vod then return fail(request, err) end
            local first = request.have_start - vod_offset + 0.1
            local last = math.min(request.have_end + request.seconds - vod_offset, vod.length - 0.5)
            if last - (request.have_end - vod_offset) < 1 then return fail(request, 'Nothing later is in the VOD yet.') end
            local name = ('part-%d.mkv'):format(request.id)
            write_json(session, 'fetch-status.json', {id=request.id, state='dumping', file=name})
            cut_playlist(vod.path, first, last, utils.join_path(session, name), function(start, cut_err)
                if not start then return fail(request, 'Could not cut the VOD: ' .. tostring(cut_err)) end
                finish({id=request.id, ok=true, file=name, start=start + vod_offset, ['end']=last + vod_offset, exact=true})
            end, vod.origin)
        end)
    end
    local function handle(request)
        if generation ~= original then return fail(request, 'The main player moved on to another video.') end
        if dvr_source then return handle_dvr(request) end
        local range = cached_range(request.have_start)
        if not range or range.start > request.have_start + 0.5 or range['end'] < request.have_end - 10 then
            -- The capture no longer lines up with the cache (it was extended from the VOD, or has aged out).
            if vod_offset then
                return (request.side == 'before' and handle_vod_before or handle_vod_after)(request)
            end
            return fail(request, 'This part of the stream has left the main player\'s cache.')
        end
        if request.side == 'before' then
            -- The cache cannot give all of it: while live on Twitch, the rest comes from the broadcast's VOD.
            if vod_offset and range.start > request.have_start - request.seconds + 0.5 then
                return handle_vod_before(request)
            end
            local first = math.max(range.start, request.have_start - request.seconds)
            if request.have_start - first < 1 then
                return fail(request, 'No earlier footage is in the main player\'s cache. A larger back buffer keeps more.')
            end
            -- A dump from the very start of the cached range begins exactly there: ranges start on a keyframe.
            return dump(request, first, request.have_end, first <= range.start + 0.001)
        end
        -- Later footage has to arrive first. Give up waiting once the cache stops growing.
        local want, seen, stalled = request.have_end + request.seconds, range['end'], 0
        local waiter
        waiter = mp.add_periodic_timer(0.5, function()
            local now = cached_range(request.have_start)
            local last = now and now['end'] or seen
            stalled = last > seen + 0.05 and 0 or stalled + 0.5
            seen = last
            if generation ~= original or not now or now.start > request.have_start + 0.5 then
                waiter:kill()
                return fail(request, 'This part of the stream has left the main player\'s cache.')
            end
            if last < want and stalled < 4 then
                return write_json(session, 'fetch-status.json', {id=request.id, state='waiting',
                    buffered=math.max(0, last - request.have_end), want=request.seconds})
            end
            waiter:kill()
            local finish_at = math.min(want, last)
            if finish_at - request.have_end < 1 then
                return fail(request, mp.get_property_native('pause')
                    and 'Nothing later is buffered yet. The main player is paused.'
                    or 'Nothing later is buffered yet.')
            end
            dump(request, request.have_start, finish_at)
        end)
    end
    timer = mp.add_periodic_timer(0.4, function()
        if busy then return end
        local alive = io.open(utils.join_path(session, 'session.json'), 'rb')
        if not alive then return timer:kill() end
        alive:close()
        local request = read_json(utils.join_path(session, 'fetch.json'))
        if type(request) ~= 'table' then return end
        os.remove(utils.join_path(session, 'fetch.json'))
        busy = true
        handle(request)
    end)
end

local function open_editor(force_cache)
    if preparing then return end
    local source = mp.get_property('path')
    local t = mp.get_property_number('time-pos')
    if not source or not t or t <= 0 then return notify('Play some video before clipping.') end
    if not mp.get_property_number('vid') then return notify('Clip requires a selected video track.') end
    local ring = os.getenv('MPV_CLIP_RING')
    local dvr = ring == nil and not force_cache and dvr_playlist()
    local live = ring ~= nil or force_cache or dvr or stream_info()
    -- Live on Twitch with its VOD known: footage older than the cache can come from the VOD.
    local twitch = mp.get_property_native('user-data/twitch')
    local vod_offset = (live and not dvr and ring == nil and type(twitch) == 'table' and twitch.mode == 'live'
        and twitch.dvr_offset) or nil
    local first = 0
    local history = math.max(1, opt.seconds, opt.history)
    local fetch = live and not ring
    local range_start
    if dvr then
        -- The VOD is seekable and remote, so the clip is cut from it: its length never depends on what
        -- happens to be cached behind the playhead.
        first = math.max(0.1, t - math.max(1, opt.seconds, opt.backread))
    elseif live and not ring then
        local range = cached_range(t)
        local earliest = range and range.start
        if not earliest or t - earliest < 0.1 then return notify('No preceding video in the mpv cache.') end
        -- Open quickly with one segment. The editor then asks for more on either side.
        first = math.max(earliest, t - math.max(1, opt.seconds))
        range_start = earliest
    end
    if opt.pause_on_clip then mp.set_property_native('pause', true) end
    local cfg = {source=source, cwd=mp.get_property('working-directory'), anchor=t, start=first,
        ring=ring, history=tonumber(os.getenv('MPV_CLIP_HISTORY')) or history, live=live == true, seconds=math.max(1, opt.seconds), title=mp.get_property('media-title'),
        source_name=mp.get_property('filename/no-ext'), output=opt.output, date=os.date('%Y/%m/%d'),
        mpv=opt.mpv, ffmpeg=opt.ffmpeg, pid=utils.getpid(), volume=mp.get_property_number('volume'), tracks={},
        hover=modernz_hover(), dwidth=mp.get_property_number('dwidth'), dheight=mp.get_property_number('dheight'),
        origin=origin(live), fetch=fetch == true, range_start=range_start,
        backread=math.max(opt.seconds, opt.backread), preloaded=dvr == true}
    -- A borderless or title-bar-free player gets a matching editor window.
    if opt.match_titlebar then
        cfg.border, cfg.title_bar = mp.get_property_native('border'), mp.get_property_native('title-bar')
    end
    for _, track in ipairs(mp.get_property_native('track-list') or {}) do
        if track.selected and (track.type == 'video' or track.type == 'audio') then
            cfg.tracks[track.type] = {id=track.id, index=track['ff-index'], external=track['external-filename']}
        end
    end
    for _, key in ipairs({'user-agent', 'referrer', 'http-header-fields', 'cookies', 'cookies-file', 'ytdl-format'}) do
        cfg[key] = mp.get_property_native(key)
    end
    local original = generation
    preparing = true
    local function finish_error(message) preparing = false; notify(message) end
    mp.command_native_async({name='subprocess', args=python_args(worker, 'prepare'),
        playback_only=false, capture_stdout=true, capture_stderr=true},
        function(ok, result)
            if not ok or not result or result.status ~= 0 then
                return finish_error('Clip setup failed. Check Python and clipper.conf. ' .. (result and result.stderr or ''))
            end
            local session = utils.parse_json(result.stdout or '')
            if not session then return finish_error('Clip setup returned an invalid session.') end
            local function dispose() mp.command_native({name='subprocess',args=python_args(worker,'discard',session),detach=true,playback_only=false}) end
            local function write_cfg()
                local file, err = io.open(utils.join_path(session,'session.json'),'wb')
                if not file then return false, err end
                local written = file:write(utils.format_json(cfg))
                local closed = file:close()
                return written and closed, err
            end
            local wrote, werr = write_cfg()
            if not wrote then dispose(); return finish_error('Cannot create clip session: '..tostring(werr)) end
            local function launch()
                preparing = false
                local r = mp.command_native({name='subprocess', args=python_args(worker,'edit',session),
                    detach=true, playback_only=false})
                if not r or r.status ~= 0 then dispose(); notify('Could not launch clip editor.') end
            end
            if generation ~= original then dispose(); return finish_error('Source changed. Press Clip again.') end
            if dvr then
                notify('Preparing footage from the VOD…')
                return cut_playlist(source, first, t, utils.join_path(session, 'capture.mkv'), function(start, err)
                    if not start then dispose(); return finish_error('Could not cut the VOD: ' .. tostring(err)) end
                    if generation ~= original then dispose(); return finish_error('Source changed. Press Clip again.') end
                    cfg.start = start
                    if not write_cfg() then dispose(); return finish_error('Cannot write clip session.') end
                    serve_fetches(session, original, source)
                    launch()
                end)
            end
            if not live or ring then return launch() end
            notify('Preparing cached live footage…')
            mp.command_native_async({'dump-cache', tostring(first), tostring(t), utils.join_path(session, 'capture.mkv')},
                function(done, _, reason)
                    if not done then dispose(); return finish_error('Cache capture failed: ' .. tostring(reason)) end
                    serve_fetches(session, original, nil, vod_offset)
                    launch()
                end)
        end)
end
mp.add_key_binding('Ctrl+g', 'open', function() open_editor(false) end)
mp.add_key_binding(nil, 'open-live', function() open_editor(true) end)

-- Add a Clip button to modernz or ModernX when either is installed. The patch
-- applies once and is reapplied after the controller updates. It shows after a restart.
local function integrate_osc()
    if not opt.osc_button then return end
    local scripts = mp.command_native({'expand-path', '~~/scripts'})
    for _, name in ipairs({'modernz.lua', 'modernx.lua'}) do
        local target = utils.join_path(scripts, name)
        local file = io.open(target, 'rb')
        local text = file and file:read('*a')
        if file then file:close() end
        if text and not text:find('clipper', 1, true) and not text:find('clip-window', 1, true) then
            mp.command_native_async({name='subprocess', playback_only=false, capture_stdout=true, capture_stderr=true,
                args=python_args(utils.join_path(mp.get_script_directory(), 'integrate.py'), target)},
                function(ok, result)
                    if ok and result and result.status == 0 then
                        notify('Clip button added to ' .. name .. '. Restart mpv to show it.')
                    else
                        mp.msg.warn('Could not add the Clip button to ' .. name .. ': '
                            .. tostring(result and result.stderr or 'Python failed'))
                    end
                end)
        end
    end
end
integrate_osc()

package.path = mp.get_script_directory() .. '/?.lua;' .. package.path
-- The rolling recorder keeps its own history, so cache advice does not apply there.
require('advice').setup(opt, function() return not os.getenv('MPV_CLIP_RING') and stream_info() end,
    modernz_hover() or 'E6A85C')
