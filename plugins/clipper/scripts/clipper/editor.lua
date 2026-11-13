local mp = require 'mp'
local utils = require 'mp.utils'
local folder = assert(os.getenv('MPV_CLIP_SESSION'))
local function path(name) return utils.join_path(folder, name) end
local function read(name)
    local file = io.open(path(name), 'rb')
    if not file then return end
    local contents = file:read('*a')
    file:close()
    return utils.parse_json(contents)
end
local cfg = assert(read('session.json'))
local overlay = mp.create_osd_overlay('ass-events')
local font = package.config:sub(1, 1) == '\\' and 'Segoe UI' or 'sans-serif'
-- ASS colours are BBGGRR. Alpha runs from 0x00 (opaque) to 0xFF (invisible).
local ACCENT, ACCENT_HI, WHITE, BLACK, INK = 'E6A85C', 'F7D3A6', 'FFFFFF', '000000', '1A1410'
local PANEL, FIELD, RAISED, TRACK, ERROR = '120F0F', '2A2626', '3A3535', '3F3A3A', '7A7AFF'
-- Hovered controls take modernz's hover colour when it is installed.
local HOVER = type(cfg.hover) == 'string' and cfg.hover:match('^%x%x%x%x%x%x$') and cfg.hover or ACCENT
local CARET = '{\\1c&H' .. ACCENT .. '&}|{\\1c&H' .. WHITE .. '&}'
local SHADOW = '\\bord1.6\\3c&H000000&\\3a&H50&\\blur3'
-- The editing panel sits below the video in a reserved bottom margin.
local P, pad, min_span = 180, 24, 0.01

-- The worker names the file after this title. It matches the worker's own default.
local remote = (cfg.source or ''):match('^%a[%w+.-]*://') ~= nil
local default_title = (remote or cfg.live) and cfg.title or cfg.source_name
if type(default_title) ~= 'string' or default_title == '' then default_title = 'Clip' end
local title = default_title
local has_audio = cfg.tracks.audio ~= nil

local A, B, left, right, duration, offset, audio
local preview_mute = false
local drag, grab, target, hover, mx, my, ibeam
local editing, edit_target, draft, caret = false, nil, '', 0
local focus, last_click
-- Fraction by which the controls over the video are faded out: 0 shown, 1 hidden.
local fade, fade_target, fade_timer = 0, 0
-- Streams: the span of the main player's timeline held by the current capture, and requests for more.
local SEGMENT = math.max(1, cfg.seconds or 30)
local have = {start = cfg.start or 0, last = cfg.anchor}
local media_name, media_size = cfg.fetch and 'capture.mkv' or nil, 0
local pending, queue, fetch_id, fetch_timer, reload = nil, {}, 0, nil, nil
local mode, note, progress, saved, poller = 'edit'
local job = 0
local W, H, vy = 960, 640, 440
local bar = {x1 = pad, x2 = 960 - pad, y1 = 0, y2 = 0}
local slider = {x1 = 0, x2 = 1}
local zones = {}
local draw, action, commit_edit

local function clamp(v, lo, hi) return math.min(hi, math.max(lo, v)) end
local function clock(t)
    local ms = math.floor(math.max(0, t) * 1000 + 0.5)
    return ('%02d:%02d:%02d.%03d'):format(math.floor(ms/3600000), math.floor(ms/60000)%60, math.floor(ms/1000)%60, ms%1000)
end
local function stamp(t)
    local ds = math.floor(math.max(0, t) * 10 + 0.5)
    local h, m, s = math.floor(ds/36000), math.floor(ds/600) % 60, (ds % 600) / 10
    return h > 0 and ('%d:%02d:%04.1f'):format(h, m, s) or ('%d:%04.1f'):format(m, s)
end
local function precise(t)
    local ms = math.floor(math.max(0, t) * 1000 + 0.5)
    local h, m, s = math.floor(ms/3600000), math.floor(ms/60000) % 60, (ms % 60000) / 1000
    return h > 0 and ('%d:%02d:%06.3f'):format(h, m, s) or ('%d:%06.3f'):format(m, s)
end
local function fps()
    local rate = mp.get_property_number('container-fps') or mp.get_property_number('estimated-vf-fps')
    return rate and rate > 0 and rate or nil
end
local function frame_time() return 1 / (fps() or 30) end
local function escape(s)
    -- A word joiner after the backslash stops libass reading it as an override.
    return (tostring(s):gsub('\\', '\\\226\129\160'):gsub('{', '\\{'):gsub('[\r\n]+', ' '))
end
local function chars(s) return select(2, s:gsub('[^\128-\191]', '')) end
local function fit(s, n, from_end)
    if chars(s) <= n then return s end
    return from_end and '…' .. s:sub(-n * 2):gsub('^[\128-\191]+', '') or s:sub(1, n):gsub('[\192-\255][\128-\191]*$', '') .. '…'
end
local function x_for(t) return bar.x1 + (bar.x2-bar.x1) * clamp((t-left)/(right-left), 0, 1) end
local function time_for(x) return left + clamp((x-bar.x1)/(bar.x2-bar.x1), 0, 1) * (right-left) end
local function position() return target or mp.get_property_number('time-pos', A) end
-- The timeline's limits. Footage that is still being fetched extends them past the loaded capture.
local function lo() return pending and pending.side == 'before' and -pending.seconds or 0 end
local function hi() return duration + (pending and pending.side == 'after' and pending.seconds or 0) end
local function pending_text()
    if pending.state == 'waiting' then
        return ('Waiting for the stream  ·  %d of %d s buffered'):format(pending.buffered or 0, pending.seconds)
    end
    return ('Fetching %d s %s  ·  %s'):format(pending.seconds, pending.side == 'before' and 'earlier' or 'later',
        pending.progress and ('%d%%'):format(pending.progress * 100) or 'starting')
end
-- Keyframe seeks keep dragging responsive. The release seek is exact.
local function seek(t, fast) mp.commandv('seek', t, fast and 'absolute+keyframes' or 'absolute+exact') end
local function stop() mp.set_property_native('pause', true) end
local function apply_loop()
    mp.set_property_number('ab-loop-a', A)
    mp.set_property_number('ab-loop-b', B)
end
-- The preview is silent when the clip will be, so it matches the export.
local function apply_audio() mp.set_property_native('mute', preview_mute or not audio) end

-- Vector outlines, in overlay coordinates.
local function rect(x1, y1, x2, y2)
    return ('m %.1f %.1f l %.1f %.1f %.1f %.1f %.1f %.1f'):format(x1, y1, x2, y1, x2, y2, x1, y2)
end
local function round(x1, y1, x2, y2, r)
    local k = r * 0.45
    return ('m %.1f %.1f l %.1f %.1f b %.1f %.1f %.1f %.1f %.1f %.1f l %.1f %.1f b %.1f %.1f %.1f %.1f %.1f %.1f '
        .. 'l %.1f %.1f b %.1f %.1f %.1f %.1f %.1f %.1f l %.1f %.1f b %.1f %.1f %.1f %.1f %.1f %.1f'):format(
        x1+r, y1, x2-r, y1, x2-k, y1, x2, y1+k, x2, y1+r,
        x2, y2-r, x2, y2-k, x2-k, y2, x2-r, y2,
        x1+r, y2, x1+k, y2, x1, y2-k, x1, y2-r,
        x1, y1+r, x1, y1+k, x1+k, y1, x1+r, y1)
end
local function circle(cx, cy, r) return round(cx-r, cy-r, cx+r, cy+r, r) end
local function poly(cx, cy, points)
    local out = {}
    for i = 1, #points, 2 do
        out[#out+1] = ('%s %.1f %.1f'):format(i == 1 and 'm' or (i == 3 and 'l' or ''), cx+points[i], cy+points[i+1])
    end
    return table.concat(out, ' ')
end
local function line(x1, y1, x2, y2, t)
    local dx, dy = x2-x1, y2-y1
    local n = t / (2*math.sqrt(dx*dx + dy*dy))
    local ox, oy = -dy*n, dx*n
    return ('m %.1f %.1f l %.1f %.1f %.1f %.1f %.1f %.1f'):format(x1+ox, y1+oy, x2+ox, y2+oy, x2-ox, y2-oy, x1-ox, y1-oy)
end
-- Out and back along one curve: no area, so only the border is drawn.
local function arc(cx, cy, x, y, bulge)
    return ('m %.1f %.1f b %.1f %.1f %.1f %.1f %.1f %.1f b %.1f %.1f %.1f %.1f %.1f %.1f'):format(
        cx+x, cy-y, cx+x+bulge, cy-y*0.6, cx+x+bulge, cy+y*0.6, cx+x, cy+y,
        cx+x+bulge, cy+y*0.6, cx+x+bulge, cy-y*0.6, cx+x, cy-y)
end

local function layout()
    local w, h = mp.get_osd_size()
    if not w or w < 1 or h < 1 then return false end
    local scale = clamp(math.min(w/960, h/640), 0.5, 3)
    W, H = math.floor(w/scale + 0.5), math.floor(h/scale + 0.5)
    vy = H - P
    bar = {x1 = pad, x2 = W - pad, y1 = vy + 18, y2 = vy + 46}
    local ratio = clamp(P/H, 0, 0.9)
    if math.abs(ratio - mp.get_property_number('video-margin-ratio-bottom', 0)) > 0.002 then
        mp.set_property_number('video-margin-ratio-bottom', ratio)
    end
    overlay.res_x, overlay.res_y = W, H
    return true
end

function draw()
    if not A or not layout() then return end
    local out = {}
    local dim = 0
    local function fa(alpha) return 255 - math.floor((255 - (alpha or 0)) * (1 - dim) + 0.5) end
    local function shape(outline, color, alpha, extra)
        local fade_border = dim > 0 and ('\\3a&H%02X&'):format(fa(0x50)) or ''
        out[#out+1] = ('{\\an7\\pos(0,0)\\bord0\\shad0%s%s\\1c&H%s&\\1a&H%02X&\\p1}%s{\\p0}'):format(
            extra or '', fade_border, color, fa(alpha), outline)
    end
    local function stroke(outline, alpha, color, width)
        out[#out+1] = ('{\\an7\\pos(0,0)\\shad0\\bord%.1f\\1a&HFF&\\3c&H%s&\\3a&H%02X&\\p1}%s{\\p0}'):format(
            width or 0.9, color or WHITE, fa(alpha), outline)
    end
    local function glyph(outline, alpha, color) shape(outline, color or WHITE, alpha, SHADOW) end
    local function raw_text(x, y, s, size, an, color, alpha, bold, extra)
        -- Shadows are part of the border, so they fade with the fill.
        local fade_border = dim > 0 and ('\\3a&H%02X&'):format(fa(0x50)) or ''
        out[#out+1] = ('{\\an%d\\pos(%.1f,%.1f)\\q2\\fn%s\\fs%d\\b%d\\bord0\\shad0%s%s\\1c&H%s&\\1a&H%02X&}%s'):format(
            an, x, y, font, size, bold and 1 or 0, extra or '', fade_border, color or WHITE, fa(alpha), s)
    end
    local function text(x, y, s, size, an, color, alpha, bold, extra)
        raw_text(x, y, escape(s), size, an, color, alpha, bold, extra)
    end
    zones = {}
    local function zone(id, x1, y1, x2, y2) zones[#zones+1] = {id=id, x1=x1, y1=y1, x2=x2, y2=y2} end
    local function hovered(id) return hover == id and not drag end
    local editable = mode == 'edit'
    local pos = position()

    -- Player controls over the bottom of the video, on a strong fade. They fade out with the pointer.
    dim = fade
    local first_control_zone = #zones + 1
    for i = 1, 34 do
        local y = vy - 170 + (i-1)*5
        shape(rect(0, y, W, y+5), BLACK, 255 - math.floor(225 * (i/34)^1.4))
    end
    local row = vy - 26
    -- Square hover highlights with a small radius, as in modernz.
    local function icon(id, cx, cy, r, enabled, painter, also)
        local hot = enabled and (hovered(id) or (also and hovered(also)))
        if hot then shape(round(cx-r, cy-r, cx+r, cy+r, 4), WHITE, 0xD0) end
        painter(cx, cy, enabled and 0 or 0xA0, hot and HOVER or WHITE)
        if enabled then zone(id, cx-r, cy-r, cx+r, cy+r) end
    end
    icon('play', pad+12, row, 15, editable, function(cx, cy, a, c)
        if mp.get_property_native('pause') then
            glyph(poly(cx, cy, {-5, -8, 8, 0, -5, 8}), a, c)
        else
            glyph(rect(cx-6, cy-8, cx-2.5, cy+8), a, c)
            glyph(rect(cx+2.5, cy-8, cx+6, cy+8), a, c)
        end
    end)
    local muted = preview_mute or not audio
    local volume = mp.get_property_number('volume', 100)
    icon('speaker', pad+48, row, 15, editable, function(cx, cy, a, c)
        glyph(poly(cx-3, cy, {-7, -2.5, -3.5, -2.5, 1, -7, 1, 7, -3.5, 2.5, -7, 2.5}), a, c)
        if muted then
            glyph(line(cx+2, cy-3.5, cx+8, cy+3.5, 1.4), a, c)
            glyph(line(cx+8, cy-3.5, cx+2, cy+3.5, 1.4), a, c)
        else
            stroke(arc(cx-3, cy, 3, 4, 3), a, c)
            if volume > 50 then stroke(arc(cx-3, cy, 5.5, 7, 5), a, c) end
        end
    end, 'volume')
    slider = {x1 = pad+70, x2 = pad+160}
    local kx = slider.x1 + (slider.x2-slider.x1) * (muted and 0 or clamp(volume/100, 0, 1))
    local vol_hot = editable and (hovered('volume') or hovered('speaker') or drag == 'volume')
    shape(rect(slider.x1, row-1, slider.x2, row+1), WHITE, 0x90, SHADOW)
    if kx > slider.x1 then shape(rect(slider.x1, row-1, kx, row+1), vol_hot and HOVER or WHITE) end
    shape(circle(kx, row, 5), vol_hot and HOVER or WHITE, editable and 0 or 0xA0, SHADOW)
    if editable then zone('volume', slider.x1-8, row-10, slider.x2+8, row+10) end
    if vol_hot then
        local cx = (slider.x1 + slider.x2) / 2
        shape(round(cx-48, row-38, cx+48, row-16, 3), '201C1C', 0x08)
        text(cx, row-27, muted and 'Volume: muted' or ('Volume: %d'):format(volume + 0.5), 13, 5, WHITE)
    end
    text(slider.x2+20, row, stamp(pos-A) .. ' / ' .. stamp(B-A), 15, 4, WHITE, 0, false, SHADOW)
    icon('back', W-pad-48, row, 15, editable, function(cx, cy, a, c)
        glyph(rect(cx-6.5, cy-6, cx-4.5, cy+6), a, c)
        glyph(poly(cx, cy, {6, -6, -3, 0, 6, 6}), a, c)
    end)
    icon('forward', W-pad-14, row, 15, editable, function(cx, cy, a, c)
        glyph(poly(cx, cy, {-6, -6, 3, 0, -6, 6}), a, c)
        glyph(rect(cx+4.5, cy-6, cx+6.5, cy+6), a, c)
    end)
    if fade >= 0.5 then
        for i = #zones, first_control_zone, -1 do zones[i] = nil end
    end
    dim = 0

    -- Trim panel.
    shape(rect(0, vy, W, H), PANEL)
    local y1, y2 = bar.y1, bar.y2
    shape(rect(bar.x1, y1, bar.x2, y2), TRACK)
    -- Footage on its way from the main player: darker, hatched, with its progress along the bottom.
    if pending then
        local g1, g2 = x_for(pending.side == 'before' and lo() or duration), x_for(pending.side == 'before' and 0 or hi())
        if g2 > g1 + 1 then
            shape(rect(g1, y1, g2, y2), PANEL, 0x30)
            local hatch = {}
            for x = g1 + 4, g2 - 2, 7 do hatch[#hatch+1] = line(x, y2 - 2, math.min(g2, x + 6), y1 + 2, 1) end
            if #hatch > 0 then shape(table.concat(hatch, ' '), WHITE, 0xD8) end
            if pending.progress then shape(rect(g1, y2 - 2, g1 + (g2 - g1) * pending.progress, y2), WHITE, 0x50) end
            if g2 - g1 > 150 then
                text((g1 + g2) / 2, (y1 + y2) / 2, pending.state == 'waiting' and 'Waiting for stream…'
                    or (pending.progress and ('Fetching %d%%'):format(pending.progress * 100) or 'Fetching…'), 12, 5, WHITE, 0x30)
            end
        end
    end
    local per = (bar.x2-bar.x1) / (right-left)
    local step = 300
    for _, s in ipairs({0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300}) do
        if s * per >= 9 then step = s; break end
    end
    local ticks = {}
    for i = math.ceil((left+offset)/step), math.floor((right+offset)/step) do
        local x = x_for(i*step - offset)
        ticks[#ticks+1] = rect(x-0.5, y2 - (i % 5 == 0 and 9 or 5), x+0.5, y2-2)
    end
    if #ticks > 0 then shape(table.concat(ticks, ' '), WHITE, 0xB8) end
    -- The view can be zoomed or panned away from the selection, so draw only what is in view.
    local function shown(t) return t >= left - 1e-6 and t <= right + 1e-6 end
    local ax, bx, px = x_for(A), x_for(B), x_for(pos)
    if bx > ax then
        shape(rect(ax, y1, bx, y2), ACCENT, 0x98)
        shape(rect(ax, y1, bx, y1+1.5), ACCENT)
        shape(rect(ax, y2-1.5, bx, y2), ACCENT)
    end
    for _, handle in ipairs({{'a', ax-8, A}, {'b', bx, B}}) do
        local which, x1 = handle[1], handle[2]
        if shown(handle[3]) then
            shape(round(x1, y1, x1+8, y2, 1.5), (drag == which or hovered(which)) and ACCENT_HI or ACCENT)
            local dots = {}
            for r = -1, 1 do dots[#dots+1] = circle(x1+4, (y1+y2)/2 + r*4, 0.9) end
            shape(table.concat(dots, ' '), WHITE)
        end
    end
    text(bar.x1+5, y1+2, stamp(left+offset), 11, 7, WHITE, 0x50)
    text(bar.x2-5, y1+2, stamp(right+offset), 11, 9, WHITE, 0x50)
    if shown(pos) then
        shape(rect(px-0.75, y1-4, px+0.75, y2+4), WHITE)
        shape(circle(px, y1-4, 3.5), WHITE)
    end
    if editable then
        if shown(A) then zone('a', ax-12, y1-6, ax+3, y2+6) end
        if shown(B) then zone('b', bx-3, y1-6, bx+12, y2+6) end
        if bx > ax then zone('inside', ax, y1, bx, y2) end
        zone('bar', bar.x1-4, y1-6, bar.x2+4, y2+6)
    end
    local active = drag == 'a' or drag == 'b' or drag == 'move'
    local near = hovered('a') or hovered('b') or hovered('inside')
    local function tip(cx, half, top, bottom)
        local ty = y1 - 10
        shape(round(cx-half, ty-40, cx+half, ty, 3), '201C1C', 0x08)
        text(cx, ty-28, top, 15, 5, WHITE, 0, true)
        text(cx, ty-11, bottom, 13, 5, WHITE, 0x40)
    end
    local hover_t = mx and (bar.x1 == bar.x2 and 0 or left + (mx - bar.x1) / (bar.x2 - bar.x1) * (right - left))
    if editable and active then
        tip(clamp((ax+bx)/2, pad+115, W-pad-115), 115, precise(B-A), clock(A+offset) .. '  –  ' .. clock(B+offset))
    elseif editable and pending and hovered('bar') and (hover_t < 0 or hover_t > duration) then
        tip(clamp(mx, pad+150, W-pad-150), 150, pending_text(), 'From the main player\'s cache. Usable once it arrives.')
    elseif editable and (near or hovered('bar')) and mx then
        local t = time_for(mx)
        local rate = fps()
        local label = clock(t+offset) .. (rate and ('   ·   frame %d'):format(math.floor((t+offset)*rate + 1e-6)) or '')
        local hint = hovered('inside') and 'Click to jump  ·  drag to move the selection'
            or 'Scroll to zoom  ·  Shift+scroll to pan'
        tip(clamp(mx, pad+140, W-pad-140), 140, label, hint)
    end

    local function chip(id, x, y, width, label, enabled)
        local hot = enabled and hovered(id)
        if hot then shape(round(x, y-11, x+width, y+11, 3), WHITE, 0xD8) end
        text(x + width/2, y, label, 14, 5, hot and HOVER or WHITE, enabled and 0x10 or 0xB0)
        if enabled then zone(id, x, y-11, x+width, y+11) end
    end
    local ly = vy + 63
    -- Local files show their whole timeline. A stream's capture grows on request, one segment per press.
    if cfg.fetch then
        local function label(side, idle)
            if pending and pending.side == side then
                return pending.state == 'waiting' and 'Waiting…' or (pending.progress and ('Fetching %d%%'):format(pending.progress * 100) or 'Fetching…')
            end
            return idle
        end
        chip('earlier', pad-6, ly, 138, label('before', ('‹  Fetch %d s earlier'):format(SEGMENT)), editable and not pending)
        chip('later', W-pad-132, ly, 138, label('after', ('Fetch %d s later  ›'):format(SEGMENT)), editable and not pending)
    end
    -- Click a field to focus it for arrow-key and frame-step nudges. Double-click to type a value.
    local function field(key, label, x, width, value, strong)
        local typing = editing and edit_target == key
        local outline = round(x, ly-11, x+width, ly+11, 3)
        text(x - 7, ly, label, 13, 6, WHITE, 0x60)
        shape(outline, strong and ACCENT or FIELD, strong and 0x70 or 0)
        if typing or focus == key then stroke(outline, 0, HOVER, 1.2)
        elseif editable and hovered('f_' .. key) then stroke(outline, 0x40, HOVER, 1) end
        if typing then
            raw_text(x + width/2, ly, escape(draft:sub(1, caret)) .. CARET .. escape(draft:sub(caret+1)), 14, 5, WHITE)
        else
            text(x + width/2, ly, value, strong and 15 or 14, 5, WHITE, 0, strong)
        end
        if editable then zone('f_' .. key, x, ly-11, x+width, ly+11) end
    end
    local gx = W/2 - 232
    field('start', 'Start', gx+40, 108, clock(A+offset))
    field('end', 'End', gx+198, 108, clock(B+offset))
    field('len', 'Length', gx+368, 96, precise(B-A), true)

    local f1, f2, fy1, fy2 = pad, W-pad-200, vy+82, vy+110
    local mid = (fy1+fy2)/2
    local hot = (editing and edit_target == 'title') or (editable and hovered('title'))
    shape(round(f1, fy1, f2, fy2, 3), FIELD)
    if hot then stroke(round(f1, fy1, f2, fy2, 3), 0, HOVER, 1) end
    local clip = ('\\clip(%d,%d,%d,%d)'):format(f1+8, fy1, f2-28, fy2)
    if editing and edit_target == 'title' then
        local long = chars(draft) * 8 > f2 - f1 - 44
        raw_text(long and f2-30 or f1+10, mid, escape(draft:sub(1, caret)) .. CARET .. escape(draft:sub(caret+1)),
                 15, long and 6 or 4, WHITE, 0, false, clip)
    else
        text(f1+10, mid, title ~= '' and title or default_title, 15, 4, WHITE, title ~= '' and 0 or 0x80, false, clip)
        local cx = f2-14
        shape(line(cx-4, mid+4, cx+3.5, mid-3.5, 2.2), hot and HOVER or WHITE, hot and 0 or 0x80)
        shape(poly(cx, mid, {-6.5, 6.5, -5.6, 2.8, -2.8, 5.6}), hot and HOVER or WHITE, hot and 0 or 0x80)
    end
    if editable then zone('title', f1, fy1, f2, fy2) end

    local d1, d2, s1, s2 = W-pad-190, W-pad-102, W-pad-94, W-pad
    shape(round(d1, fy1, d2, fy2, 3), hovered('cancel') and TRACK or RAISED)
    text((d1+d2)/2, mid, mode == 'encoding' and 'Cancel' or 'Discard', 14, 5, hovered('cancel') and HOVER or WHITE)
    zone('cancel', d1, fy1, d2, fy2)
    if mode == 'encoding' then
        shape(round(s1, fy1, s2, fy2, 3), RAISED)
        if progress then shape(round(s1, fy1, s1 + math.max(6, (s2-s1)*progress), fy2, 3), ACCENT, 0x40) end
        text((s1+s2)/2, mid, progress and ('Saving %d%%'):format(progress*100) or 'Saving…', 14, 5, WHITE)
    else
        shape(round(s1, fy1, s2, fy2, 3), (editable and hovered('save')) and ACCENT_HI or ACCENT)
        text((s1+s2)/2, mid, mode == 'done' and 'Saved' or 'Save clip', 14, 5, INK, 0, true)
        if editable then zone('save', s1, fy1, s2, fy2) end
    end

    local by = vy + 136
    local can_toggle = editable and has_audio
    local box_alpha = can_toggle and 0 or 0x60
    if audio then
        shape(round(pad, by-7, pad+14, by+7, 2), ACCENT, box_alpha)
        shape(line(pad+3, by, pad+6, by+3.5, 2) .. ' ' .. line(pad+5.3, by+3.5, pad+11, by-3.5, 2), INK, box_alpha)
    else
        stroke(round(pad+0.5, by-6.5, pad+13.5, by+6.5, 2), box_alpha, WHITE, 1)
    end
    local label = not has_audio and 'Source has no audio'
        or (audio and 'Clip audio: included' or 'Clip audio: muted (saved without sound)')
    text(pad+22, by, label, 14, 4, WHITE, (can_toggle and hovered('audio')) and 0 or 0x30)
    if can_toggle then zone('audio', pad-4, by-11, pad+290, by+11) end
    local status, color, alpha
    if note then status, color = fit(note, 72), ERROR
    elseif mode == 'done' then status = 'Saved  ' .. fit(saved, 72, true)
    else status, alpha = 'Saves to  ' .. fit(cfg.output .. '/' .. cfg.date, 64, true), 0x60 end
    text(W-pad, by, status, 13, 6, color or WHITE, alpha or 0)
    text(pad, vy + 160, 'Source', 13, 4, WHITE, 0x60)
    text(pad + 50, vy + 160, fit(cfg.origin or cfg.source or '', 130, true), 13, 4, WHITE, 0x30)

    if editable then zone('video', 0, 0, W, vy) end
    -- mpv cannot change the pointer shape, so the text cursor is drawn in its place.
    if ibeam and mx then
        shape(rect(mx-0.8, my-8, mx+0.8, my+8) .. ' ' .. rect(mx-4, my-9.6, mx+4, my-8) .. ' '
              .. rect(mx-4, my+8, mx+4, my+9.6), WHITE, 0, '\\bord1\\3c&H000000&')
    end
    overlay.data = table.concat(out, '\n')
    overlay:update()
end

local function set_range(which, t, fast)
    if which == 'a' then A = clamp(t, 0, B-min_span); left = math.min(left, A); target = A
    else B = clamp(t, A+min_span, duration); right = math.max(right, B); target = B end
    seek(target, fast)
    apply_loop()
end

local function put(name, value)
    -- Write then rename, so the reader never sees a partial file.
    local file, err = io.open(path(name .. '.tmp'), 'wb')
    local ok = file and file:write(utils.format_json(value))
    ok = file and file:close() and ok
    if ok then os.remove(path(name)); ok, err = os.rename(path(name .. '.tmp'), path(name)) end
    if not ok then os.remove(path(name .. '.tmp')) end
    return ok, err
end

local next_fetch
local function fetch_tick()
    if not pending then return fetch_timer:kill() end
    local status = read('fetch-status.json')
    if status and status.id == pending.id then
        pending.state = status.state
        pending.buffered = status.buffered
        local info = status.file and utils.file_info(path(status.file))
        if info and media_size > 0 then
            local expected = media_size / duration * (have.last - have.start + pending.seconds)
            pending.progress = clamp(info.size / expected, 0, 0.99)
        end
    end
    local result = read('fetched.json')
    if result and result.id == pending.id then
        os.remove(path('fetched.json'))
        fetch_timer:kill()
        if result.ok and mode == 'edit' then
            -- Swap to the larger capture. The file-loaded handler lines the selection up again.
            reload = {side = pending.side, old = duration, pos = position(), file = result.file,
                      start = result.start, last = result['end'], auto = not pending.manual}
            pending.state, pending.progress, drag, grab = 'dumping', 0.99, nil, nil
            return mp.commandv('loadfile', path(result.file), 'replace')
        end
        if result.ok then os.remove(path(result.file)) end
        if pending.manual and not result.ok then note = result.message end
        pending = nil
        left, right = math.max(left, 0), math.min(right, duration)
        if right - left < min_span then left, right = 0, duration end
        next_fetch()
    end
    draw()
end
function next_fetch()
    if pending or #queue == 0 or mode ~= 'edit' then return end
    local item = table.remove(queue, 1)
    fetch_id = fetch_id + 1
    pending = {id = fetch_id, side = item.side, seconds = item.seconds, manual = item.manual, state = 'requested'}
    if not put('fetch.json', {id = fetch_id, side = item.side, seconds = item.seconds,
                              have_start = have.start, have_end = have.last}) then
        pending = nil
        return
    end
    left, right = lo(), hi()
    fetch_timer = mp.add_periodic_timer(0.25, fetch_tick)
    draw()
end

local function poll()
    local status = read('status.json')
    if not status or status.id ~= job then return end
    if status.state == 'encoding' then
        progress = status.progress
    elseif status.state == 'done' then
        poller:kill()
        mode, saved = 'done', status.path
        mp.add_timeout(2.5, function() mp.commandv('quit') end)
    else
        poller:kill()
        mode, note = 'edit', status.message or 'Export failed.'
    end
    draw()
end

local function save()
    if editing then commit_edit() end
    job = job + 1
    local request = {id=job, a=A, b=B, audio=audio, source_start=A+offset, title=title ~= '' and title or default_title,
                     media=media_name}
    local ok, err = put('export.json', request)
    if not ok then
        note = 'Could not save the clip selection: ' .. tostring(err)
        return draw()
    end
    stop()
    mode, note, progress, drag, target = 'encoding', nil, nil, nil, nil
    poller = mp.add_periodic_timer(0.2, poll)
    draw()
end

function action(what)
    if not A then return end
    if what == 'cancel' or mode == 'done' then return mp.commandv('quit') end
    if mode ~= 'edit' then return end
    note = nil
    if what == 'earlier' or what == 'later' then
        if cfg.fetch and not pending then
            queue[#queue+1] = {side = what == 'earlier' and 'before' or 'after', seconds = SEGMENT, manual = true}
            next_fetch()
        end
    elseif what == 'play' or what == 'video' then
        if mp.get_property_native('pause') then
            local now = mp.get_property_number('time-pos', A)
            if now < A or now >= B-0.03 then seek(A) end
            mp.set_property_native('pause', false)
        else stop() end
    elseif what == 'back' then stop(); mp.commandv('frame-back-step')
    elseif what == 'forward' then stop(); mp.commandv('frame-step')
    elseif what == 'audio' then
        if has_audio then audio = not audio; apply_audio() end
    elseif what == 'speaker' then
        if audio then preview_mute = not preview_mute; apply_audio()
        else note = 'Clip audio is muted. Turn it on below to hear the preview.' end
    elseif what == 'save' then return save()
    elseif what == 'a' or what == 'b' then
        stop()
        set_range(what, mp.get_property_number('time-pos', A))
    end
    draw()
end

-- Keyboard shortcuts give way to text entry while the title or a time is being typed.
local shortcuts = {SPACE='play', m='audio', ENTER='save', KP_ENTER='save', ESC='cancel', ['[']='a', [']']='b',
                   ['-']='earlier', ['=']='later', LEFT='back', RIGHT='forward', UP='up', DOWN='down',
                   [',']='prev_frame', ['.']='next_frame'}
local repeating = {back=true, forward=true, up=true, down=true, prev_frame=true, next_frame=true}
-- Nudges for a focused time field, in seconds. Comma and dot step one frame.
local nudges = {back=-0.1, forward=0.1, down=-1, up=1}
local function nudge(key, d)
    stop()
    if key == 'start' then set_range('a', A + d) else set_range('b', B + d) end
end
local function shortcut(command)
    if focus and mode == 'edit' then
        local d = nudges[command]
        if command == 'prev_frame' or command == 'next_frame' then
            d = (command == 'next_frame' and 1 or -1) * frame_time()
        end
        if d then nudge(focus, d); return draw() end
        if command == 'cancel' or command == 'save' then focus = nil; return draw() end
    end
    if command == 'prev_frame' then return action('back') end
    if command == 'next_frame' then return action('forward') end
    if command == 'up' or command == 'down' then
        if mode ~= 'edit' then return end
        preview_mute = false
        mp.set_property_number('volume', clamp(mp.get_property_number('volume', 100) + (command == 'up' and 5 or -5), 0, 100))
        apply_audio()
        return draw()
    end
    action(command)
end
local function bind_shortcuts(on)
    for key, command in pairs(shortcuts) do
        if on then
            mp.add_forced_key_binding(key, 'clip-' .. key, function() shortcut(command) end, {repeatable = repeating[command]})
        else
            mp.remove_key_binding('clip-' .. key)
        end
    end
end

-- Typed times are on the source timeline: seconds, m:s, or h:m:s, with a dot or comma for fractions.
local function parse_time(s)
    s = s:gsub(',', '.'):match('^%s*(.-)%s*$')
    if s == '' then return end
    local t, parts = 0, 0
    for piece in (s .. ':'):gmatch('([^:]*):') do
        local n = tonumber(piece)
        if not n or n < 0 then return end
        t, parts = t * 60 + n, parts + 1
    end
    if parts <= 3 then return t end
end
local function field_text(key)
    if key == 'start' then return clock(A+offset) elseif key == 'end' then return clock(B+offset) end
    return precise(B-A)
end

local function prev_pos(s, i)
    if i <= 0 then return 0 end
    local j = i - 1
    while j > 0 and s:byte(j+1) >= 0x80 and s:byte(j+1) < 0xC0 do j = j - 1 end
    return j
end
local function next_pos(s, i)
    if i >= #s then return #s end
    local j = i + 1
    while j < #s and s:byte(j+1) >= 0x80 and s:byte(j+1) < 0xC0 do j = j + 1 end
    return j
end
local function insert(s)
    if #draft + #s > 300 then return end
    draft = draft:sub(1, caret) .. s .. draft:sub(caret+1)
    caret = caret + #s
end
local bind_text
local function end_edit(keep)
    if not editing then return end
    if keep and edit_target == 'title' then
        title = draft:match('^%s*(.-)%s*$')
    elseif keep then
        local t = parse_time(draft)
        if not t then
            note = ('"%s" is not a time. Use seconds, m:s or h:m:s.'):format(fit(draft, 24))
        elseif edit_target == 'start' then set_range('a', t - offset)
        elseif edit_target == 'end' then set_range('b', t - offset)
        else set_range('b', A + t) end
    end
    if edit_target ~= 'title' then focus = edit_target end
    editing, edit_target = false, nil
    bind_text(false)
    bind_shortcuts(true)
    draw()
end
function commit_edit() end_edit(true) end
local text_keys = {
    BS = function() local p = prev_pos(draft, caret); draft = draft:sub(1, p) .. draft:sub(caret+1); caret = p end,
    DEL = function() draft = draft:sub(1, caret) .. draft:sub(next_pos(draft, caret)+1) end,
    LEFT = function() caret = prev_pos(draft, caret) end,
    RIGHT = function() caret = next_pos(draft, caret) end,
    HOME = function() caret = 0 end,
    END = function() caret = #draft end,
    ['Ctrl+BS'] = function() draft = draft:sub(caret+1); caret = 0 end,
    SPACE = function() insert(' ') end,
    ENTER = function() end_edit(true) end,
    KP_ENTER = function() end_edit(true) end,
    ESC = function() end_edit(false) end,
}
function bind_text(on)
    for key, fn in pairs(text_keys) do
        if on then
            mp.add_forced_key_binding(key, 'title-' .. key, function() fn(); draw() end, {repeatable=true})
        else
            mp.remove_key_binding('title-' .. key)
        end
    end
    if on then
        mp.add_forced_key_binding('ANY_UNICODE', 'title-text', function(event)
            if event.event ~= 'up' and event.key_text then insert(event.key_text); draw() end
        end, {repeatable=true, complex=true})
    else
        mp.remove_key_binding('title-text')
    end
end
local function begin_edit(target, initial)
    if editing or mode ~= 'edit' then return end
    editing, edit_target, draft = true, target, initial
    caret = #draft
    if target ~= 'title' then stop() end
    bind_shortcuts(false)
    bind_text(true)
end

local function pointer()
    local x, y = mp.get_mouse_pos()
    local w, h = mp.get_osd_size()
    if w and w > 0 and h > 0 then return x*W/w, y*H/h end
end
local function hit(x, y)
    for _, z in ipairs(zones) do
        if x >= z.x1 and x <= z.x2 and y >= z.y1 and y <= z.y2 then return z.id end
    end
end
local function move()
    local x = mx
    if not x or not drag then return end
    if drag == 'window' then return end
    if drag == 'video' then
        -- Dragging the picture moves the window, as in mpv. A click without movement plays or pauses.
        -- mpv ignores begin-vo-dragging while window-dragging is off. It stays off otherwise, because
        -- with it on mpv starts a window drag on every press, including presses on the trim controls.
        if math.abs(x - grab.x) + math.abs(my - grab.y) >= 4 then
            drag, grab = 'window', nil
            mp.set_property_native('window-dragging', true)
            mp.commandv('begin-vo-dragging')
        end
        return
    end
    if drag == 'pending' then
        -- A click jumps the playhead. Moving past a few pixels drags the whole selection instead.
        if math.abs(x - grab.x) < 4 then return end
        drag = 'move'
    end
    if drag == 'seek' then target = clamp(time_for(x), 0, duration); seek(target, true)
    elseif drag == 'a' or drag == 'b' then set_range(drag, time_for(x - grab.dx), true)
    elseif drag == 'move' then
        local len = grab.b - grab.a
        A = clamp(grab.a + time_for(x) - grab.t, 0, duration - len)
        B = A + len
        target = A
        seek(A, true)
        apply_loop()
    elseif drag == 'volume' then
        preview_mute = false
        mp.set_property_number('volume', 100 * clamp((x - slider.x1)/(slider.x2 - slider.x1), 0, 1))
        apply_audio()
    end
    draw()
end
local function release()
    if not drag then return end
    if drag == 'window' then
        -- The system move loop ends with mpv releasing all keys, which lands here.
        drag = nil
        mp.set_property_native('window-dragging', false)
        return
    end
    if drag == 'video' then
        drag, grab = nil, nil
        return action('play')
    end
    if drag == 'pending' then target = grab.t end
    local exact = drag ~= 'volume'
    drag, grab = nil, nil
    if exact and target then seek(target) end
    draw()
end
local function click(event)
    if not A then return end
    if event.event == 'up' or event.canceled then return release() end
    if event.event ~= 'down' and event.event ~= 'press' then return end
    local x, y = pointer()
    if not x then return end
    mx, my = x, y
    local id = hit(x, y)
    local editing_zone = edit_target == 'title' and 'title' or ('f_' .. tostring(edit_target))
    if editing and id ~= editing_zone then commit_edit() end
    local is_field = id and id:sub(1, 2) == 'f_'
    if focus and not is_field then focus = nil end
    if id == 'a' or id == 'b' then
        stop()
        drag, grab = id, {dx = x - x_for(id == 'a' and A or B)}
    elseif id == 'inside' then
        stop()
        drag, grab = 'pending', {x = x, t = time_for(x), a = A, b = B}
        target = grab.t
        seek(target, true)
    elseif id == 'bar' then
        stop()
        drag = 'seek'
        move()
    elseif id == 'volume' then
        drag = 'volume'
        move()
    elseif id == 'title' then
        begin_edit('title', title)
    elseif is_field then
        local key, now = id:sub(3), mp.get_time()
        if last_click and last_click.id == id and now - last_click.t < 0.4 then
            focus = key
            begin_edit(key, field_text(key))
        elseif not (editing and edit_target == key) then
            focus = key
        end
        last_click = {id = id, t = now}
    elseif id == 'video' then
        drag, grab = 'video', {x = x, y = y}
    elseif id then
        action(id)
    end
    if event.event == 'press' then release() end
    draw()
end

mp.add_forced_key_binding('MBTN_LEFT', 'pointer', click, {complex=true})
-- Show any part of the source: zoom around the pointer, or pan, over the timeline.
-- Elsewhere the wheel sets the preview volume.
local function view(l, span)
    local first, last = lo(), hi()
    span = clamp(span, math.min(2, last - first), last - first)
    left = clamp(l, first, last - span)
    right = left + span
end
local function wheel(kind, dir)
    if not A or mode ~= 'edit' then return end
    local x, y = pointer()
    if not x then return end
    local id = hit(x, y)
    local span = right - left
    if id == 'a' or id == 'b' or id == 'inside' or id == 'bar' then
        if kind == 'pan' then
            view(left + dir*span*0.2, span)
        else
            local at, f = time_for(x), dir > 0 and 1/1.5 or 1.5
            view(at - (at-left)*f, span*f)
        end
    elseif kind == 'zoom' and y < vy then
        preview_mute = false
        mp.set_property_number('volume', clamp(mp.get_property_number('volume', 100) + dir*5, 0, 100))
        apply_audio()
    end
    draw()
end
for key, args in pairs({WHEEL_UP={'zoom', 1}, WHEEL_DOWN={'zoom', -1}, ['Shift+WHEEL_UP']={'pan', -1},
                        ['Shift+WHEEL_DOWN']={'pan', 1}, WHEEL_LEFT={'pan', -1}, WHEEL_RIGHT={'pan', 1}}) do
    mp.add_forced_key_binding(key, 'wheel-' .. key, function() wheel(args[1], args[2]) end)
end
bind_shortcuts(true)
mp.observe_property('mouse-pos', 'native', function(_, mouse)
    if not A or not mouse then return end
    mx, my = pointer()
    -- Show the video controls while the pointer is in the window, as mpv's OSC does.
    local want = (mouse.hover or drag) and 0 or 1
    if want ~= fade_target then
        fade_target = want
        if not fade_timer then
            fade_timer = mp.add_periodic_timer(1/60, function()
                fade = fade_target > fade and math.min(fade_target, fade + 1/12) or math.max(fade_target, fade - 1/12)
                if fade == fade_target then fade_timer:kill() end
                draw()
            end)
        else
            fade_timer:resume()
        end
    end
    if drag then return move() end
    local id = mouse.hover and mx and hit(mx, my) or nil
    local beam = id == 'title' and mode == 'edit'
    if beam ~= (ibeam or false) then
        ibeam = beam
        mp.set_property('cursor-autohide', beam and 'always' or 'no')
    end
    local follows = id == 'bar' or id == 'inside' or id == 'a' or id == 'b'
    if id ~= hover or ibeam or follows then hover = id; draw() end
end)
-- Hashes of decoded video frames with their timestamps, to find the same frame in two captures.
local first_frame
local function hashes(name, from, length, done)
    local args = {cfg.ffmpeg, '-hide_banner', '-loglevel', 'error', '-nostdin', '-copyts'}
    local function add(...) for _, value in ipairs({...}) do args[#args+1] = value end end
    if from then add('-ss', ('%.3f'):format(from), '-t', ('%.3f'):format(length)) end
    add('-i', path(name), '-map', '0:v:0')
    if not from then add('-frames:v', '1') end
    add('-f', 'framemd5', '-')
    mp.command_native_async({name='subprocess', args=args, playback_only=false, capture_stdout=true, capture_stderr=true},
        function(ok, result)
            local list, unit = {}, 0.001
            for row in ((ok and result and result.status == 0 and result.stdout) or ''):gmatch('[^\r\n]+') do
                local n, d = row:match('^#tb 0: (%d+)/(%d+)')
                local pts, hash = row:match('^%s*0,%s*%-?%d+,%s*(%-?%d+),%s*%d+,%s*%d+,%s*(%x+)')
                if n then unit = n / d elseif pts then list[#list+1] = {pts = pts * unit, hash = hash} end
            end
            done(list)
        end)
end
local function measure()
    media_size = media_name and (utils.file_info(path(media_name)) or {}).size or 0
    first_frame = nil
    if not media_name then return end
    local name = media_name
    hashes(name, nil, nil, function(list) if name == media_name then first_frame = list[1] end end)
end
-- A fetched capture replaced the previous one: keep the selection on the same frames.
local function reloaded(length)
    local r, known = reload, first_frame
    reload = nil
    -- Earlier footage is a prefix, so everything moves right by its length. Later footage changes nothing.
    -- Lengths are only a first estimate: a capture taken at the live edge can end a few frames short.
    local shift = r.side == 'before' and (length - r.old) or 0
    local function move(by)
        A, B, offset = A + by, B + by, offset - by
        B = clamp(B, min_span, length)
        A = clamp(A, 0, B - min_span)
        apply_loop()
    end
    duration = length
    move(shift)
    if r.file ~= media_name then
        os.remove(path(media_name))
        media_name = r.file
    end
    have.start, have.last = r.start, r.last
    left, right = 0, duration
    target = clamp(r.pos + shift, 0, duration)
    seek(target)
    local function settle()
        -- A capture that begins at the start of the cached range has a known place on the stream.
        if r.exact then offset = r.start end
        -- The clip point's segment came up short (little was cached): the automatic backread completes it.
        if r.auto and r.side == 'before' and B - A < SEGMENT - 0.05 then
            A = math.max(0, B - SEGMENT)
            apply_loop()
        end
        pending = nil
        measure()
        next_fetch()
        draw()
    end
    if r.side ~= 'before' or not known then return settle() end
    -- Find the previous capture's first frame in the new one for the exact shift.
    pending = {id = -1, side = 'none', seconds = 0, state = 'aligning'}
    draw()
    hashes(media_name, math.max(0, shift - 1.5), 2.5, function(list)
        for _, frame in ipairs(list) do
            if frame.hash == known.hash then
                move(frame.pts - known.pts - shift)
                break
            end
        end
        settle()
    end)
end
mp.register_event('end-file', function(event)
    -- A fetched capture that will not open: go back to the one that did.
    if event.reason ~= 'error' or not reload then return end
    if reload.file == media_name then return mp.commandv('quit', 2) end
    os.remove(path(reload.file))
    note = 'Could not open the fetched footage.'
    reload = {side = 'same', old = duration, pos = reload.pos, file = media_name, start = have.start, last = have.last}
    mp.commandv('loadfile', path(media_name), 'replace')
end)
mp.register_event('file-loaded', function()
    local length = mp.get_property_number('duration', 0)
    if length < min_span then
        mp.msg.error('No seekable duration for clip editor')
        return mp.commandv('quit', 2)
    end
    if reload then return reloaded(length) end
    duration = length
    -- Live snapshots restart at zero. The offset maps them back to the source.
    offset = cfg.live and cfg.start or 0
    B = clamp(cfg.anchor-offset, min_span, duration)
    A = math.max(0, B-cfg.seconds)
    -- The timeline shows everything that is loaded: the whole file, or the stream captured so far.
    left, right = 0, duration
    audio = has_audio
    measure()
    apply_audio()
    apply_loop()
    seek(A)
    if cfg.fetch then
        -- The clip point's own segment plus earlier footage make up `backread` seconds in total. The capture
        -- may already hold them (DVR playlists are cut that way). Anything more is loaded with the fetch buttons.
        queue = {}
        local extra = (cfg.backread or 2 * SEGMENT) - duration
        if not cfg.preloaded and extra >= 1 then
            queue[1] = {side = 'before', seconds = extra}
            next_fetch()
        end
    end
    draw()
end)
mp.register_event('playback-restart', function()
    if not drag then target = nil; draw() end
end)
mp.observe_property('osd-dimensions', 'native', draw)
mp.observe_property('time-pos', 'number', draw)
mp.observe_property('pause', 'bool', draw)
mp.observe_property('volume', 'number', draw)
