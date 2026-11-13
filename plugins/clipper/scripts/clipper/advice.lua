-- Notices when a stream's cache settings leave clips little history, and offers better ones.
-- Accepted settings are stored in clipper.conf and applied to streams. mpv.conf is never changed.
local mp = require 'mp'
local M = {}

local WHITE, BLACK, PANEL, RAISED, TRACK = 'FFFFFF', '000000', '1A1616', '3A3535', '4A4444'
local font = package.config:sub(1, 1) == '\\' and 'Segoe UI' or 'sans-serif'

local function clamp(v, lo, hi) return math.min(hi, math.max(lo, v)) end
local function mib(bytes) return ('%dMiB'):format(math.floor(bytes / 1048576 + 0.5)) end
local function span(seconds)
    if seconds >= 90 then return ('%d min'):format(math.floor(seconds / 60 + 0.5)) end
    return ('%d s'):format(math.floor(seconds + 0.5))
end
local function rect(x1, y1, x2, y2)
    return ('m %.1f %.1f l %.1f %.1f %.1f %.1f %.1f %.1f'):format(x1, y1, x2, y1, x2, y2, x1, y2)
end
local function round(x1, y1, x2, y2, r)
    local k = r * 0.45
    return ('m %.1f %.1f l %.1f %.1f b %.1f %.1f %.1f %.1f %.1f %.1f l %.1f %.1f b %.1f %.1f %.1f %.1f %.1f %.1f '
        .. 'l %.1f %.1f b %.1f %.1f %.1f %.1f %.1f %.1f l %.1f %.1f b %.1f %.1f %.1f %.1f %.1f %.1f'):format(
        x1+r, y1, x2-r, y1, x2-k, y1, x2, y1+k, x2, y1+r, x2, y2-r, x2, y2-k, x2-k, y2, x2-r, y2,
        x1+r, y2, x1+k, y2, x1, y2-k, x1, y2-r, x1, y1+r, x1, y1+k, x1+k, y1, x1+r, y1)
end

-- Rewrites or appends key=value lines in clipper.conf, keeping everything else.
local function save_options(values)
    local file_path = mp.command_native({'expand-path', '~~/script-opts/clipper.conf'})
    local lines, seen = {}, {}
    local file = io.open(file_path, 'rb')
    if file then
        for line in file:lines() do
            line = line:gsub('\r$', '')
            local key = line:match('^%s*([%w_]+)%s*=')
            if key and values[key] ~= nil then line, seen[key] = key .. '=' .. values[key], true end
            lines[#lines+1] = line
        end
        file:close()
    end
    for key, value in pairs(values) do
        if not seen[key] then lines[#lines+1] = key .. '=' .. value end
    end
    local out, err = io.open(file_path, 'wb')
    if not out then return nil, err end
    out:write(table.concat(lines, '\n') .. '\n')
    out:close()
    return true
end

function M.setup(opt, is_stream, accent)
    local overlay = mp.create_osd_overlay('ass-events')
    overlay.z = 2000
    local shown, suggestion, hover, zones, hide_timer, check_timer, checked
    local section = 'clipper_advice'

    local function draw()
        if not shown then overlay:remove(); return end
        local w, h = mp.get_osd_size()
        if not w or w < 1 or h < 1 then return end
        overlay.res_x, overlay.res_y = w, h
        local s = clamp(h / 720, 0.75, 2)
        local out = {}
        zones = {}
        local function shape(outline, color, alpha)
            out[#out+1] = ('{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H%s&\\1a&H%02X&\\p1}%s{\\p0}'):format(color, alpha or 0, outline)
        end
        local function text(x, y, value, size, an, color, alpha, bold)
            out[#out+1] = ('{\\an%d\\pos(%.1f,%.1f)\\q2\\fn%s\\fs%.1f\\b%d\\bord0\\shad0\\1c&H%s&\\1a&H%02X&}%s'):format(
                an, x, y, font, size * s, bold and 1 or 0, color or WHITE, alpha or 0, value)
        end
        local function button(id, x, y, label, primary)
            local width = (#label * 7.6 + 24) * s
            local hot = hover == id
            shape(round(x, y, x + width, y + 26*s, 3*s), primary and accent or (hot and TRACK or RAISED), primary and (hot and 0 or 0x18) or 0)
            text(x + width/2, y + 13*s, label, 13.5, 5, primary and '1A1410' or (hot and accent or WHITE), 0, primary)
            zones[#zones+1] = {id = id, x1 = x, y1 = y, x2 = x + width, y2 = y + 26*s}
            return x + width + 8*s
        end
        if shown == 'tip' then
            local tw, th = 420*s, 74*s
            local x1, y1 = w - tw - 16*s, 48*s
            shape(round(x1, y1, x1 + tw, y1 + th, 4*s), PANEL, 0x18)
            shape(rect(x1, y1 + 4*s, x1 + 3*s, y1 + th - 4*s), accent)
            text(x1 + 16*s, y1 + 18*s, ('Clips can reach back only about %s on this stream.'):format(span(suggestion.now)), 14, 4)
            local bx = button('review', x1 + 14*s, y1 + 36*s, 'Improve…', true)
            button('mute', bx, y1 + 36*s, "Don't show again")
            text(x1 + tw - 14*s, y1 + 14*s, '✕', 13, 5, hover == 'close' and accent or WHITE, 0x40)
            zones[#zones+1] = {id = 'close', x1 = x1 + tw - 28*s, y1 = y1, x2 = x1 + tw, y2 = y1 + 28*s}
            mp.set_mouse_area(x1, y1, x1 + tw, y1 + th, section)
        else
            shape(rect(0, 0, w, h), BLACK, 0x70)
            local rows = suggestion.rows
            local pw, ph = 560*s, (180 + 26 * #rows) * s
            local x1, y1 = (w - pw) / 2, (h - ph) / 2
            shape(round(x1, y1, x1 + pw, y1 + ph, 4*s), PANEL)
            text(x1 + 20*s, y1 + 26*s, 'Better settings for stream clips', 17, 4, WHITE, 0, true)
            local y = y1 + 58*s
            text(x1 + 330*s, y, 'Now', 12.5, 5, WHITE, 0x70)
            text(x1 + 460*s, y, 'Suggested', 12.5, 5, WHITE, 0x70)
            for _, row in ipairs(rows) do
                y = y + 26*s
                text(x1 + 20*s, y, row[1], 14, 4, WHITE, 0x20)
                text(x1 + 330*s, y, row[2], 14, 5, WHITE, 0x40)
                text(x1 + 395*s, y, '→', 14, 5, WHITE, 0x70)
                text(x1 + 460*s, y, row[3], 14, 5, accent, 0, true)
            end
            text(x1 + 20*s, y + 30*s, ('History for clips: about %s → about %s. Uses up to %s of memory while watching.'):format(
                span(suggestion.now), span(suggestion.after), suggestion.back), 12.5, 4, WHITE, 0x40)
            text(x1 + 20*s, y + 48*s, 'Applied to streams and saved in clipper.conf. Your mpv.conf is not changed.', 12.5, 4, WHITE, 0x40)
            local bx = button('apply', x1 + 20*s, y1 + ph - 42*s, 'Apply', true)
            bx = button('later', bx, y1 + ph - 42*s, 'Not now')
            button('mute', bx, y1 + ph - 42*s, "Don't show again")
            mp.set_mouse_area(0, 0, w, h, section)
        end
        overlay.data = table.concat(out, '\n')
        overlay:update()
    end

    local function hit(x, y)
        for _, zone in ipairs(zones or {}) do
            if x >= zone.x1 and x <= zone.x2 and y >= zone.y1 and y <= zone.y2 then return zone.id end
        end
    end
    local function on_mouse(_, mouse)
        if not shown or not mouse then return end
        local id = hit(mouse.x, mouse.y)
        if id ~= hover then hover = id; draw() end
    end
    local function hide()
        shown, hover = nil, nil
        if hide_timer then hide_timer:kill() end
        mp.disable_key_bindings(section)
        mp.unobserve_property(on_mouse)
        draw()
    end

    local function apply_settings()
        mp.set_property('cache', 'yes')
        mp.set_property('demuxer-seekable-cache', 'yes')
        mp.set_property('demuxer-max-back-bytes', opt.stream_back_bytes)
    end

    local function choose(id)
        if id == 'review' then
            shown, hover = 'review', nil
            if hide_timer then hide_timer:kill() end
            draw()
        elseif id == 'apply' then
            opt.stream_back_bytes = suggestion.back
            apply_settings()
            local ok, err = save_options({stream_back_bytes = suggestion.back})
            hide()
            mp.osd_message(ok and 'Stream clip settings applied.' or ('Applied for now, but could not save: ' .. tostring(err)), 3)
        elseif id == 'mute' then
            opt.stream_tips = false
            local ok, err = save_options({stream_tips = 'no'})
            hide()
            mp.osd_message(ok and 'Stream tips off. Set stream_tips=yes in clipper.conf to bring them back.'
                or ('Could not save: ' .. tostring(err)), 4)
        elseif id == 'close' or id == 'later' then
            hide()
        elseif shown == 'review' and not id then
            hide()
        end
    end

    local function show(kind)
        shown = kind
        mp.set_key_bindings({{'mbtn_left', function()
            local x, y = mp.get_mouse_pos()
            choose(hit(x, y))
        end}}, section, 'force')
        mp.enable_key_bindings(section)
        mp.observe_property('mouse-pos', 'native', on_mouse)
        -- The notice fades by itself unless the pointer is over it.
        hide_timer = mp.add_periodic_timer(15, function()
            if shown == 'tip' and not hover then hide() end
        end)
        draw()
    end

    local function evaluate(attempt)
        if not opt.stream_tips or not is_stream() then return end
        local rate = (mp.get_property_number('video-bitrate') or 0) + (mp.get_property_number('audio-bitrate') or 0)
        if rate <= 0 then
            local cache = mp.get_property_native('demuxer-cache-state') or {}
            rate = (cache['raw-input-rate'] or 0) * 8
        end
        if rate <= 0 then
            if attempt < 4 then check_timer = mp.add_timeout(10, function() evaluate(attempt + 1) end) end
            return
        end
        local bytes_per_second = rate / 8
        local back = mp.get_property_number('demuxer-max-back-bytes', 0)
        local cache_on = mp.get_property('cache') ~= 'no'
        local seekable = mp.get_property('demuxer-seekable-cache') ~= 'no'
        local wanted = opt.history * 1.15 * bytes_per_second
        local now = (cache_on and seekable) and back / bytes_per_second or 0
        if now >= opt.history * 0.9 then return end
        local suggested = math.max(64, math.ceil(wanted / 1048576 / 50) * 50) * 1048576
        local rows = {{'Back buffer (demuxer-max-back-bytes)', mib(back), mib(suggested)}}
        if not cache_on then table.insert(rows, 1, {'Cache (cache)', 'no', 'yes'}) end
        if not seekable then rows[#rows+1] = {'Seekable cache (demuxer-seekable-cache)', 'no', 'yes'} end
        suggestion = {now = now, after = suggested / bytes_per_second, back = mib(suggested), rows = rows}
        show('tip')
    end

    mp.register_event('file-loaded', function()
        if check_timer then check_timer:kill() end
        if shown then hide() end
        if not is_stream() then return end
        if opt.stream_back_bytes ~= '' then apply_settings() end
        if opt.stream_tips and not checked then
            -- Wait for the bitrate to settle. Check once per mpv session.
            checked = true
            check_timer = mp.add_timeout(12, function() evaluate(1) end)
        end
    end)
    mp.observe_property('osd-dimensions', 'native', function() if shown then draw() end end)
end

return M
