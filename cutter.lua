-- cutter.lua : a simple cutting tool for mpv, powered by ffmpeg
--
-- INSTALL
--   Windows: put this file in  %APPDATA%\mpv\scripts\cutter.lua
--   ffmpeg must be in your PATH (or set ffmpeg_path, see below).
--
-- USAGE
--   c      1st press: marks the START of the cut and opens the quality menu
--          2nd press: marks the END and starts ffmpeg
--   In the menu:  UP/DOWN to move, ENTER or c to confirm, 1-9 to quick-pick,
--                 ESC to cancel the whole cut
--   C      (shift+c) re-open the quality menu while a cut is in progress
--   r      re-mark the START of the current cut at the current position
--   x      cancel the current cut
--
-- OPTIONAL CONFIG  (%APPDATA%\mpv\script-opts\cutter.conf)
--   output_dir=C:/Videos
--   ffmpeg_path=C:/ffmpeg/bin/ffmpeg.exe
--   default_profile=2
--   show_status=yes

local mp      = require 'mp'
local utils   = require 'mp.utils'
local msg     = require 'mp.msg'
local options = require 'mp.options'

local is_windows = package.config:sub(1, 1) == "\\"

------------------------------------------------------------------------
-- SETTINGS
------------------------------------------------------------------------

local opts = {
    -- Leave empty to use  <your user folder>\Videos  (e.g. C:\Users\You\Videos)
    -- If you really mean C:\Videos, set output_dir=C:/Videos in cutter.conf
    output_dir      = "",
    ffmpeg_path     = "ffmpeg",
    default_profile = 4,      -- which profile is highlighted the first time (4 = Small)
    show_status     = true,   -- small "CUTTING" indicator while a cut is open
}
options.read_options(opts, "cutter")

-- Keybinds (change these to whatever you like)
local KEY_CUT          = "c"   -- start / finish cut
local KEY_CHANGE_QUAL  = "C"   -- re-open quality menu mid-cut (shift+c)
local KEY_CANCEL       = "x"   -- cancel current cut
local KEY_RESTART      = "r"   -- move the cut's start to the current position

------------------------------------------------------------------------
-- QUALITY PROFILES  (edit / add your own!)
--   name : shown in the menu
--   desc : small grey text in the menu
--   ext  : output container
--   args : ffmpeg output arguments for the video/audio codecs
--   subs : true = also keep subtitle tracks (only sensible for mkv)
------------------------------------------------------------------------

local profiles = {
    {
        name = "Lossless (stream copy)",
        desc = "Instant, no quality loss. Cuts snap to keyframes.",
        ext  = "mkv",
        subs = true,
        args = { "-c", "copy" },
    },
    {
        name = "High  (H.264, CRF 18)",
        desc = "Near-transparent quality, large files.",
        ext  = "mp4",
        args = { "-c:v", "libx264", "-preset", "slow", "-crf", "18",
                 "-pix_fmt", "yuv420p",
                 "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart" },
    },
    {
        name = "Medium  (H.264, CRF 23)",
        desc = "Good balance of size and quality.",
        ext  = "mp4",
        args = { "-c:v", "libx264", "-preset", "medium", "-crf", "23",
                 "-pix_fmt", "yuv420p",
                 "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart" },
    },
    {
        name = "Small  (720p, CRF 28)",
        desc = "Small files for sharing (e.g. Discord).",
        ext  = "mp4",
        args = { "-vf", "scale=-2:720",
                 "-c:v", "libx264", "-preset", "fast", "-crf", "28",
                 "-pix_fmt", "yuv420p",
                 "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart" },
    },
    {
        name = "NVENC  (GPU H.264)",
        desc = "Fast GPU encode. Needs an NVIDIA card.",
        ext  = "mp4",
        args = { "-c:v", "h264_nvenc", "-preset", "p5", "-rc", "vbr",
                 "-cq", "21", "-b:v", "0", "-pix_fmt", "yuv420p",
                 "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart" },
    },
}

------------------------------------------------------------------------
-- STATE
------------------------------------------------------------------------

local state = {
    active  = false,   -- a cut has been started
    start   = 0,       -- start time in seconds
    input   = nil,     -- full path of the source file
    profile = math.min(math.max(opts.default_profile, 1), #profiles),
}

local menu = { open = false, sel = 1, cancel_on_esc = false, keys = {} }
local menu_overlay   = mp.create_osd_overlay("ass-events")
local status_overlay = mp.create_osd_overlay("ass-events")
local status_timer
local pending_jobs = 0

------------------------------------------------------------------------
-- HELPERS
------------------------------------------------------------------------

local function clock(t)
    t = math.max(t or 0, 0)
    return string.format("%02d:%02d:%02d",
        math.floor(t / 3600), math.floor(t / 60) % 60, math.floor(t % 60))
end

local function dashclock(t)
    return clock(t):gsub(":", "-")
end

local function get_output_dir()
    local dir = opts.output_dir
    if dir == nil or dir == "" then
        local home = os.getenv("USERPROFILE") or os.getenv("HOME") or "C:"
        dir = home .. "/Videos"
    end
    dir = dir:gsub("\\", "/"):gsub("/+$", "")
    return dir
end

local function ensure_dir(dir)
    local info = utils.file_info(dir)
    if info and info.is_dir then return true end
    local args
    if is_windows then
        args = { "cmd", "/c", "mkdir", (dir:gsub("/", "\\")) }
    else
        args = { "mkdir", "-p", dir }
    end
    mp.command_native({ name = "subprocess", args = args,
                        capture_stdout = true, capture_stderr = true })
    info = utils.file_info(dir)
    return info and info.is_dir
end

local function unique_path(dir, base, ext)
    local path = string.format("%s/%s.%s", dir, base, ext)
    local n = 2
    while utils.file_info(path) do
        path = string.format("%s/%s_%d.%s", dir, base, n, ext)
        n = n + 1
    end
    return path
end

local function sanitize(name)
    return (name:gsub('[<>:"/\\|?*%c]', "_"))
end

local function say(text, seconds)
    mp.osd_message(text, seconds or 3)
    msg.info((text:gsub("\n", " ")))
end

------------------------------------------------------------------------
-- STATUS INDICATOR
------------------------------------------------------------------------

local function update_status()
    if not (opts.show_status and state.active) then
        status_overlay:remove()
        return
    end
    local pos = mp.get_property_number("time-pos") or state.start
    status_overlay.data = string.format(
        "{\\an9\\fs24\\bord2\\c&H0000FF&}●{\\c&HFFFFFF&} CUTTING  %s  {\\c&HBBBBBB&}[%s]",
        clock(pos - state.start), profiles[state.profile].name)
    status_overlay:update()
end

local function start_status()
    if not opts.show_status then return end
    if not status_timer then
        status_timer = mp.add_periodic_timer(0.25, update_status)
    end
    status_timer:resume()
    update_status()
end

local function stop_status()
    if status_timer then status_timer:kill() end
    status_overlay:remove()
end

------------------------------------------------------------------------
-- QUALITY MENU
------------------------------------------------------------------------

local function render_menu()
    local lines = {}
    lines[#lines + 1] = string.format(
        "{\\b1\\fs32}Cut quality{\\b0\\fs22\\c&HBBBBBB&}    start at %s",
        clock(state.start))
    lines[#lines + 1] = ""
    for i, p in ipairs(profiles) do
        if i == menu.sel then
            lines[#lines + 1] = string.format(
                "{\\fs28\\c&H00D7FF&}▶ %d. %s{\\fs18\\c&HBBBBBB&}   %s",
                i, p.name, p.desc or "")
        else
            lines[#lines + 1] = string.format(
                "{\\fs28\\c&HFFFFFF&}   %d. %s{\\fs18\\c&H888888&}   %s",
                i, p.name, p.desc or "")
        end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "{\\fs20\\c&HBBBBBB&}↑/↓ select   Enter / " .. KEY_CUT ..
        " confirm   1-" .. math.min(#profiles, 9) .. " quick pick"
    lines[#lines + 1] = "{\\fs20\\c&HBBBBBB&}" .. KEY_RESTART ..
        " re-mark start here   Esc cancel"

    menu_overlay.data = "{\\an7\\bord2\\shad1}" .. table.concat(lines, "\\N")
    menu_overlay:update()
end

local function close_menu()
    for _, name in ipairs(menu.keys) do
        mp.remove_key_binding(name)
    end
    menu.keys = {}
    menu.open = false
    menu_overlay:remove()
end

local function cancel_cut(silent)
    if menu.open then close_menu() end
    local was_active = state.active
    state.active = false
    stop_status()
    if was_active and not silent then say("Cut cancelled") end
end

local function confirm_menu(index)
    if index then menu.sel = index end
    state.profile = menu.sel
    close_menu()
    say(string.format("Cut started at %s\nProfile: %s\n%s = finish   %s = re-mark start   %s = cancel",
        clock(state.start), profiles[state.profile].name, KEY_CUT, KEY_RESTART, KEY_CANCEL), 4)
    start_status()
end

local function bind_menu(key, name, fn, flags)
    mp.add_forced_key_binding(key, name, fn, flags)
    table.insert(menu.keys, name)
end

local function open_menu(cancel_on_esc)
    if menu.open then return end
    menu.open = true
    menu.sel = state.profile
    menu.cancel_on_esc = cancel_on_esc

    bind_menu("UP", "cutter-up", function()
        menu.sel = (menu.sel - 2) % #profiles + 1
        render_menu()
    end, { repeatable = true })

    bind_menu("DOWN", "cutter-down", function()
        menu.sel = menu.sel % #profiles + 1
        render_menu()
    end, { repeatable = true })

    bind_menu("ENTER", "cutter-enter", function() confirm_menu() end)
    bind_menu("KP_ENTER", "cutter-kpenter", function() confirm_menu() end)
    bind_menu(KEY_CUT, "cutter-confirm-c", function() confirm_menu() end)

    bind_menu("ESC", "cutter-esc", function()
        if menu.cancel_on_esc then
            cancel_cut()
        else
            close_menu()
        end
    end)

    for i = 1, math.min(#profiles, 9) do
        bind_menu(tostring(i), "cutter-pick-" .. i, function() confirm_menu(i) end)
    end

    render_menu()
end

------------------------------------------------------------------------
-- FFMPEG
------------------------------------------------------------------------

-- Progress bar: ffmpeg writes its progress to a temp file (-progress), and a
-- timer reads that file and draws a bar in the bottom-left corner.

local jobs = {}
local job_counter = 0
local progress_overlay = mp.create_osd_overlay("ass-events")
local progress_timer
local BAR_WIDTH = 30

local function new_progress_path()
    job_counter = job_counter + 1
    local tmp = (os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp")
    tmp = tmp:gsub("\\", "/"):gsub("/+$", "")
    return string.format("%s/mpv_cutter_%d_%d.progress", tmp, os.time(), job_counter)
end

local function read_progress(job)
    local f = io.open(job.progress_file, "r")
    if not f then return end
    local data = f:read("*a") or ""
    f:close()
    local last
    for v in data:gmatch("out_time_us=(%d+)") do last = v end
    if not last then
        -- older ffmpeg builds (this one is also in microseconds)
        for v in data:gmatch("out_time_ms=(%d+)") do last = v end
    end
    if last and job.duration > 0 then
        job.progress = math.min(tonumber(last) / 1000000 / job.duration, 1)
    end
end

local function render_progress()
    if #jobs == 0 then
        progress_overlay:remove()
        return
    end
    local lines = {}
    for _, job in ipairs(jobs) do
        local filled = math.floor(job.progress * BAR_WIDTH + 0.5)
        local name = job.label
        if #name > 40 then name = name:sub(1, 37) .. "..." end
        lines[#lines + 1] = string.format(
            "{\\fs20\\c&HFFFFFF&}%s  {\\c&H00D7FF&}%s{\\c&H555555&}%s{\\c&HFFFFFF&} %3d%%",
            name,
            string.rep("█", filled),
            string.rep("█", BAR_WIDTH - filled),
            math.floor(job.progress * 100))
    end
    progress_overlay.data = "{\\an1\\bord2\\shad1}" .. table.concat(lines, "\\N")
    progress_overlay:update()
end

local function tick_progress()
    for _, job in ipairs(jobs) do read_progress(job) end
    render_progress()
end

local function add_job(outfile, duration, progress_file)
    local job = {
        label         = (outfile:match("[^/]+$") or outfile):gsub("[{}\\]", ""),
        duration      = duration,
        progress      = 0,
        progress_file = progress_file,
    }
    jobs[#jobs + 1] = job
    if not progress_timer then
        progress_timer = mp.add_periodic_timer(0.4, tick_progress)
    end
    progress_timer:resume()
    render_progress()
    return job
end

local function remove_job(job)
    for i, j in ipairs(jobs) do
        if j == job then table.remove(jobs, i) break end
    end
    os.remove(job.progress_file)
    if #jobs == 0 and progress_timer then progress_timer:kill() end
    render_progress()
end

local function build_args(input, start, duration, profile, outfile, progress_file)
    local a = {
        opts.ffmpeg_path, "-hide_banner", "-loglevel", "error", "-nostdin",
        "-nostats", "-progress", progress_file,
        "-ss", string.format("%.3f", start),
        "-i", input,
        "-t", string.format("%.3f", duration),
        "-map", "0:v:0", "-map", "0:a?",
    }
    if profile.subs then
        a[#a + 1] = "-map"
        a[#a + 1] = "0:s?"
    end
    for _, v in ipairs(profile.args) do a[#a + 1] = v end
    a[#a + 1] = "-avoid_negative_ts"
    a[#a + 1] = "make_zero"
    a[#a + 1] = outfile
    return a
end

local function run_ffmpeg(args, outfile, label, duration, progress_file)
    pending_jobs = pending_jobs + 1
    local job = add_job(outfile, duration, progress_file)
    say(string.format("Cutting...\n%s", label), 3)
    msg.info("Running: " .. table.concat(args, " "))

    mp.command_native_async({
        name = "subprocess",
        args = args,
        capture_stdout = true,
        capture_stderr = true,
        playback_only = false,
    }, function(success, res, err)
        pending_jobs = pending_jobs - 1
        remove_job(job)
        if success and res and res.status == 0 then
            say("Saved:\n" .. outfile, 5)
        else
            local detail = ""
            if res and res.error_string == "init" then
                detail = "Could not run ffmpeg. Is it in your PATH?\n" ..
                         "(or set ffmpeg_path in script-opts/cutter.conf)"
            else
                local e = (res and res.stderr) or err or "unknown error"
                msg.error(e)
                detail = "ffmpeg failed - see the mpv console (` key)"
            end
            say("Cut FAILED\n" .. detail, 6)
            -- clean up a partial file if one was left behind
            if utils.file_info(outfile) then os.remove(outfile) end
        end
    end)
end

local function finish_cut()
    local stop = mp.get_property_number("time-pos")
    if not stop then
        say("Can't read the playback position")
        return
    end

    local s, e = state.start, stop
    if e < s then s, e = e, s end
    local duration = e - s
    if duration < 0.1 then
        say("Cut is too short - move forward and press " .. KEY_CUT .. " again")
        return
    end

    local profile = profiles[state.profile]
    local dir = get_output_dir()
    if not ensure_dir(dir) then
        say("Could not create output folder:\n" .. dir, 6)
        return
    end

    local source = mp.get_property("filename/no-ext") or "clip"
    local base = string.format("%s_%s_%s", sanitize(source), dashclock(s), dashclock(e))
    local outfile = unique_path(dir, base, profile.ext)

    local progress_file = new_progress_path()
    local args = build_args(state.input, s, duration, profile, outfile, progress_file)
    local label = string.format("%s -> %s\n[%s]", clock(s) .. " - " .. clock(e),
        outfile:match("[^/]+$"), profile.name)

    state.active = false
    stop_status()
    run_ffmpeg(args, outfile, label, duration, progress_file)
end

------------------------------------------------------------------------
-- MAIN KEY HANDLERS
------------------------------------------------------------------------

local function on_cut_key()
    if menu.open then return end   -- (menu has its own binding for this key)

    if not state.active then
        local path = mp.get_property("path")
        if not path or path == "" then
            say("Cutter: no file is loaded")
            return
        end
        if path:match("^%a[%w+.-]*://") then
            say("Cutting only works on local files, not streams/URLs", 4)
            return
        end
        local pos = mp.get_property_number("time-pos")
        if not pos then
            say("Cutter: can't read the playback position yet")
            return
        end

        state.input = utils.join_path(mp.get_property("working-directory") or "", path)
        state.start = pos
        state.active = true
        open_menu(true)
    else
        finish_cut()
    end
end

local function on_change_quality()
    if not state.active then
        say("No cut in progress - press " .. KEY_CUT .. " to start one")
        return
    end
    open_menu(false)
end

local function on_restart_start()
    if not state.active then
        say("No cut in progress - press " .. KEY_CUT .. " to start one")
        return
    end
    local pos = mp.get_property_number("time-pos")
    if not pos then return end
    state.start = pos
    if menu.open then
        render_menu()
    else
        say(string.format("Start moved to %s\nPress %s to finish", clock(pos), KEY_CUT), 3)
        update_status()
    end
end

local function on_cancel()
    if state.active then
        cancel_cut()
    end
end

-- Forced bindings take priority over input.conf and other scripts
mp.add_forced_key_binding(KEY_CUT, "cutter-toggle", on_cut_key)
mp.add_forced_key_binding(KEY_CHANGE_QUAL, "cutter-quality", on_change_quality)
mp.add_forced_key_binding(KEY_CANCEL, "cutter-cancel", on_cancel)
mp.add_forced_key_binding(KEY_RESTART, "cutter-restart", on_restart_start)

-- Drop any open cut if the file changes, so you never cut the wrong video
mp.register_event("end-file", function()
    if state.active then cancel_cut(true) end
end)

msg.info("cutter.lua loaded. Output folder: " .. get_output_dir())
