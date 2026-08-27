-- ytquality.lua
--
-- Native mpv quality selector for yt-dlp.
--
-- Open with the "g-y" chord (or override/disable in input.conf):
--   g-y ignore
--   F3 script-binding ytquality/toggle
--
-- Optional config in ~/.config/mpv/script-opts/ytquality.conf:
--   yt_dlp=yt-dlp        yt-dlp executable or absolute path
--   max_qualities=20     maximum number of quality levels listed
--   refresh_formats=no   re-run yt-dlp on every open instead of caching
--   timeout=12           auto-close the menu after N seconds (0 = off)
--
-- Requires: mpv >= 0.39 (mp.input.select) and yt-dlp.

local mp = require("mp")
local msg = require("mp.msg")
local options = require("mp.options")
local utils = require("mp.utils")

local input_ok, input = pcall(require, "mp.input")

if not input_ok or not input or not input.select or not input.terminate then
	msg.error("ytquality requires mpv >= 0.39 (mp.input.select)")
	return
end

-- ============================================================================
-- Options
-- ============================================================================

local opts = {
	yt_dlp = "yt-dlp",
	max_qualities = 20,
	refresh_formats = false,
	timeout = 12,
}

options.read_options(opts, "ytquality")

-- ============================================================================
-- State
-- ============================================================================

local state = {
	open = false,

	-- Incremented per request so a stale async callback (e.g. from an
	-- aborted subprocess) cannot clobber the current request.
	request_id = 0,

	request = nil,

	-- cache[url].items = quality items for that URL.
	cache = {},

	timeout = nil,

	-- True only while the select dialog is shown; input.terminate()
	-- must not be called before it is.
	menu_shown = false,
}

-- Forward declarations.
local close_menu
local open_menu
local toggle_menu
local apply_format
local reload_current

-- ============================================================================
-- Small helpers
-- ============================================================================

local function current_url()
	local path = mp.get_property("path", "")

	if path:sub(1, 7) == "ytdl://" then
		path = path:sub(8)
	end

	return path
end

local function current_video_height()
	local height = mp.get_property_number("video-params/h", nil)

	if not height or height <= 0 then
		return nil
	end

	return math.floor(height)
end

local function show_error(text)
	text = tostring(text)

	msg.error("ytquality: " .. text)

	if mp.get_property_bool("vo-configured", false) then
		mp.osd_message("ytquality: " .. text, 4)
	end
end

local function stop_timeout()
	if state.timeout then
		state.timeout:kill()
		state.timeout = nil
	end
end

local function start_timeout()
	stop_timeout()

	if opts.timeout <= 0 then
		return
	end

	state.timeout = mp.add_timeout(opts.timeout, function()
		state.timeout = nil

		if state.open then
			close_menu()
		end
	end)
end

local function stop_request()
	if state.request then
		mp.abort_async_command(state.request)
		state.request = nil
	end
end

-- ============================================================================
-- yt-dlp executable
-- ============================================================================

local function resolve_ytdlp()
	local configured = opts.yt_dlp

	if configured:sub(1, 1) == "/" then
		return configured
	end

	local home = os.getenv("HOME")

	if home and home ~= "" then
		local local_bin = home .. "/.local/bin/yt-dlp"

		local file = io.open(local_bin, "r")

		if file then
			file:close()
			return local_bin
		end
	end

	return configured
end

-- ============================================================================
-- yt-dlp metadata
-- ============================================================================

local function fetch_metadata(url, callback)
	stop_request()

	state.request_id = state.request_id + 1

	local request_id = state.request_id

	local args = {
		resolve_ytdlp(),
		"--no-warnings",
		"--no-playlist",
		"--dump-single-json",
		"--",
		url,
	}

	msg.debug("Executing yt-dlp: " .. table.concat(args, " "))

	local handle, start_error = mp.command_native_async({
		name = "subprocess",
		playback_only = false,
		capture_stdout = true,
		capture_stderr = true,
		args = args,
	}, function(success, result, error)
		-- Only clear the handle for this request, so an aborted request's
		-- late callback cannot clobber a newer in-flight handle.
		if state.request == handle then
			state.request = nil
		end

		if request_id ~= state.request_id then
			return
		end

		if not success then
			callback(nil, error or "yt-dlp subprocess failed")
			return
		end

		if result.status ~= 0 then
			local stderr = (result.stderr or ""):gsub("^%s+", ""):gsub("%s+$", "")

			if stderr == "" then
				stderr = "yt-dlp exited with status " .. tostring(result.status)
			end

			callback(nil, stderr)
			return
		end

		local stdout = result.stdout or ""

		if stdout == "" then
			callback(nil, "yt-dlp returned empty output")
			return
		end

		local data, parse_error = utils.parse_json(stdout)

		if not data then
			callback(nil, "failed to parse yt-dlp JSON: " .. tostring(parse_error))
			return
		end

		callback(data, nil)
	end)

	if not handle then
		callback(nil, start_error or "failed to initialize yt-dlp")
		return
	end

	state.request = handle
end

-- ============================================================================
-- Quality list
-- ============================================================================

local function quality_name(height)
	if height >= 4320 then
		return "8K"
	elseif height >= 2160 then
		return "4K"
	elseif height >= 1440 then
		return "1440p"
	elseif height >= 1080 then
		return "1080p"
	elseif height >= 720 then
		return "720p"
	elseif height >= 480 then
		return "480p"
	elseif height >= 360 then
		return "360p"
	elseif height >= 240 then
		return "240p"
	end

	return string.format("%dp", height)
end

local function build_items(data)
	local seen_heights = {}
	local heights = {}

	for _, format in ipairs(data.formats or {}) do
		if format.vcodec and format.vcodec ~= "none" and format.height and format.height > 0 then
			local height = math.floor(format.height)

			if not seen_heights[height] then
				seen_heights[height] = true
				heights[#heights + 1] = height
			end
		end
	end

	table.sort(heights, function(a, b)
		return a > b
	end)

	local items = {
		{
			label = "Auto",
			format = "bestvideo*+bestaudio/best",
			height = nil,
		},
	}

	local limit = math.min(#heights, opts.max_qualities)

	for index = 1, limit do
		local height = heights[index]

		items[#items + 1] = {
			label = quality_name(height),
			format = string.format("bestvideo*[height<=%d]+bestaudio/best[height<=%d]", height, height),
			height = height,
		}
	end

	return items
end

-- Marks the currently active quality with a bullet:
--   1. the item whose format string equals the applied ytdl-format
--   2. the item matching the current video height
--   3. the Auto entry
local function build_labels(items)
	local applied = mp.get_property("ytdl-format", "")
	local current = current_video_height()

	local labels = {}
	local default_item = 1

	for index, item in ipairs(items) do
		labels[index] = "  " .. item.label
	end

	if applied ~= "" then
		for index, item in ipairs(items) do
			if item.format == applied then
				labels[index] = "● " .. item.label
				return labels, index
			end
		end
	end

	for index, item in ipairs(items) do
		if item.height and current and item.height == current then
			labels[index] = "● " .. item.label
			return labels, index
		end
	end

	if not current then
		labels[1] = "● " .. items[1].label
	end

	return labels, default_item
end

-- ============================================================================
-- Menu
-- ============================================================================

local function show_menu(items)
	local labels, default_item = build_labels(items)

	state.open = true
	start_timeout()
	state.menu_shown = true

	local function finish_menu()
		stop_timeout()

		state.open = false
		state.menu_shown = false
	end

	input.select({
		prompt = "Video quality:",
		items = labels,
		default_item = default_item,

		submit = function(index)
			finish_menu()

			local item = items[index]

			if item then
				apply_format(item)
			end
		end,

		closed = function()
			finish_menu()
		end,
	})
end

-- ============================================================================
-- Open / close / toggle
-- ============================================================================

open_menu = function()
	if state.open then
		return
	end

	local url = current_url()

	if url == "" then
		show_error("no media is currently playing")
		return
	end

	local protocol = url:match("^([%a][%w+.-]*):")

	if protocol ~= "http" and protocol ~= "https" then
		show_error("current media is not an HTTP(S) URL")
		return
	end

	if not opts.refresh_formats then
		local cached = state.cache[url]

		if cached then
			show_menu(cached.items)
			return
		end
	end

	state.open = true

	mp.osd_message("Fetching available qualities…", 2)

	fetch_metadata(url, function(data, error)
		if not state.open then
			return
		end

		if error then
			close_menu()
			show_error(error)
			return
		end

		state.cache[url] = {
			items = build_items(data),
		}

		show_menu(state.cache[url].items)
	end)
end

toggle_menu = function()
	if state.open then
		close_menu()
		return
	end

	open_menu()
end

close_menu = function()
	if not state.open then
		return
	end

	state.open = false

	if state.menu_shown then
		state.menu_shown = false
		input.terminate()
	end

	stop_timeout()

	-- Invalidate callbacks from the in-flight request.
	state.request_id = state.request_id + 1

	stop_request()
end

-- ============================================================================
-- Apply quality
-- ============================================================================

apply_format = function(item)
	if not item or not item.format then
		return
	end

	msg.info(string.format("Selecting quality: %s (%s)", item.label, item.format))

	local ok, err = mp.set_property("ytdl-format", item.format)

	if not ok then
		show_error("failed to set ytdl-format: " .. tostring(err))
		return
	end

	reload_current()
end

-- ============================================================================
-- Reload
-- ============================================================================

reload_current = function()
	local duration = mp.get_property_number("duration", 0)
	local position = mp.get_property_number("time-pos", 0)

	-- Only restore the position for finite, seekable media.
	local restore_position = duration > 0 and position > 0

	local restored = false

	local function on_file_loaded()
		mp.unregister_event(on_file_loaded)

		if not restore_position or restored then
			return
		end

		restored = true

		-- Let the new stream initialize before seeking.
		mp.add_timeout(0, function()
			mp.commandv("seek", position, "absolute", "exact")
		end)
	end

	if restore_position then
		mp.register_event("file-loaded", on_file_loaded)
	end

	mp.commandv("playlist-play-index", "current")
end

-- ============================================================================
-- Bindings / events
-- ============================================================================

mp.register_script_message("toggle", toggle_menu)
mp.register_script_message("open", open_menu)
mp.register_script_message("close", close_menu)

-- Non-forced, so it can be rebound or removed from input.conf by name.
mp.add_key_binding("g-y", "toggle", toggle_menu)

mp.register_event("end-file", function()
	if state.open then
		close_menu()
	end
end)

mp.register_event("shutdown", function()
	state.request_id = state.request_id + 1

	stop_request()
	stop_timeout()
end)
