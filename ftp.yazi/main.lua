--- A read-oriented FTP/FTPS provider for Yazi, backed by `curl`.
---
--- MIT

local M = {}

-- === Configuration ===

local MONTHS = {
	Jan = 1,
	Feb = 2,
	Mar = 3,
	Apr = 4,
	May = 5,
	Jun = 6,
	Jul = 7,
	Aug = 8,
	Sep = 9,
	Oct = 10,
	Nov = 11,
	Dec = 12,
}

-- Number of bits each of the nine `rwx` positions contributes to the mode
local WEIGHTS = { 64, 64, 64, 8, 8, 8, 1, 1, 1 }

local function truthy(value)
	return value == true or value == "true"
end

local function opts(job)
	return job.opts or {}
end

-- Not every op carries the URL directly: `Revalidate` carries a `file` and
-- `Rename` carries `from`.
local function job_url(job)
	return job.url or (job.file and job.file.url) or job.from
end

local function cfg(job)
	local o = opts(job)
	local url = job_url(job)
	return {
		host = tostring(o.host or (url and url.spec.domain) or ""),
		port = tostring(o.port or 21),
		user = tostring(o.user or "anonymous"),
		password = tostring(o.password or "anonymous@"),
		tls = truthy(o.tls),
		seek = truthy(o.seek),
		timeout = tostring(o.timeout or 30),
	}
end

local function curl(c)
	local args = {
		"--silent",
		"--show-error",
		"--connect-timeout",
		c.timeout,
		"--user",
		c.user .. ":" .. c.password,
	}
	if c.tls then
		args[#args + 1] = "--ssl-reqd"
	end
	return Command("curl"):arg(args)
end

local function origin(c)
	return "ftp://" .. c.host .. ":" .. c.port
end

local function ftp_path(url)
	local path = tostring(url.path)
	if path == "" then
		return "/"
	elseif path:sub(1, 1) ~= "/" then
		return "/" .. path
	end
	return path
end

local function dir_url(c, path)
	if path:sub(-1) ~= "/" then
		path = path .. "/"
	end
	return origin(c) .. path
end

-- Curl exit code to filesystem error kind
local EXIT = {
	[6] = { kind = "NetworkUnreachable", message = "Could not resolve host" },
	[7] = { kind = "ConnectionRefused", message = "Could not connect to host" },
	[9] = { kind = "PermissionDenied", message = "FTP access denied" },
	[28] = { kind = "TimedOut", message = "FTP operation timed out" },
	[67] = { kind = "PermissionDenied", message = "FTP login denied" },
	[78] = { kind = "NotFound", message = "Remote file not found" },
}

local function failure(output, context)
	local code = output.status.code
	local known = code and EXIT[code]
	if known then
		return Error.fs { kind = known.kind, message = known.message .. ": " .. context }
	end

	local message = context
	if code then
		message = message .. " (curl exit " .. code .. ")"
	end
	local stderr = tostring(output.stderr):gsub("%s+$", "")
	if stderr ~= "" then
		message = message .. ": " .. stderr
	end
	return Error.fs { kind = "Other", message = message }
end

-- === Directory listing parsing ===

local function mode_from_perms(perms)
	local base
	local t = perms:sub(1, 1)
	if t == "d" then
		base = 0x4000
	elseif t == "l" then
		base = 0xA000
	elseif t == "b" then
		base = 0x6000
	elseif t == "c" then
		base = 0x2000
	elseif t == "p" then
		base = 0x1000
	elseif t == "s" then
		base = 0xC000
	else
		base = 0x8000
	end

	local bits = 0
	for i = 1, 9 do
		local ch = perms:sub(i + 1, i + 1)
		local v = 0
		if ch == "r" then
			v = 4
		elseif ch == "w" then
			v = 2
		elseif ch == "x" or ch == "s" or ch == "t" then
			v = 1
		end
		bits = bits + v * WEIGHTS[i]
	end
	return base + bits
end

local function list_mtime(mon, day, extra, now)
	local month = MONTHS[mon]
	if not month then
		return nil
	end

	local year, hour, min = now.year, 0, 0
	local h, m = extra:match("^(%d+):(%d+)$")
	if h then
		hour, min = tonumber(h), tonumber(m)
	else
		year = tonumber(extra) or now.year
	end

	return os.time {
		year = year,
		month = month,
		day = tonumber(day),
		hour = hour,
		min = min,
		sec = 0,
	}
end

-- Unix `ls -l` style entry
local function parse_unix(line, now)
	local perms, size, mon, day, extra, name =
		line:match("^(%S+)%s+%S+%s+%S+%s+%S+%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(.+)$")
	if not perms or #perms < 10 or not perms:match("^[%-dlbcps]") then
		return nil
	end

	name = name:gsub("%s+$", "")
	local target
	if perms:sub(1, 1) == "l" then
		local at = name:find(" %-> ")
		if at then
			target = name:sub(at + 4)
			name = name:sub(1, at - 1):gsub("%s+$", "")
		end
	end

	local is_dir = perms:sub(1, 1) == "d"
	return {
		name = name,
		link = target,
		mode = mode_from_perms(perms),
		size = is_dir and 0 or (tonumber(size) or 0),
		mtime = list_mtime(mon, day, extra, now),
	}
end

-- Machine-readable MLSD (RFC 3659) style entry
local function parse_mlsd(line)
	if not line:match("^[%w%.]+=[^;]*;") then
		return nil
	end

	local facts, name = line:match("^(%S+)%s+(.+)$")
	if not facts then
		return nil
	end

	local f = {}
	for k, v in facts:gmatch("([%w%.]+)=([^;]*);") do
		f[k] = v
	end

	local t = f.type
	if not t or t == "cdir" or t == "pdir" then
		return nil
	end

	local is_dir = t == "dir"
	local perm = tonumber(f["unix.mode"] or "", 8)
	if not perm then
		perm = is_dir and 493 or 420 -- 00755 / 00644
	end

	local mtime
	local Y, Mo, D, H, Mi, S =
		(f.modify or ""):match("^(%d%d%d%d)(%d%d)(%d%d)(%d%d)(%d%d)(%d%d)")
	if Y then
		mtime = os.time {
			year = tonumber(Y),
			month = tonumber(Mo),
			day = tonumber(D),
			hour = tonumber(H),
			min = tonumber(Mi),
			sec = tonumber(S),
		}
	end

	return {
		name = name:gsub("%s+$", ""),
		mode = (is_dir and 0x4000 or 0x8000) + perm,
		size = is_dir and 0 or (tonumber(f.size or "") or 0),
		mtime = mtime,
	}
end

local function parse_line(line, now)
	line = line:gsub("[\r\n]+$", "")
	if line == "" or line:match("^total%s") then
		return nil
	end
	return parse_mlsd(line) or parse_unix(line, now)
end

-- === Conversion to Yazi types ===

local function to_stat(entry)
	return Stat { mode = entry.mode, len = entry.size or 0, mtime = entry.mtime }
end

-- Whether two stats describe the same file, used by `Revalidate` so that Yazi's
-- periodic remote refresh only re-lists a directory when its metadata changed.
local function hits(new, old)
	return new.mode == old.mode and new.len == old.len and new.mtime == old.mtime
end

local function to_file(url, entry)
	local stat = to_stat(entry)
	local lstat, link_to = stat, nil
	if entry.link then
		lstat = Stat { mode = 0xA000 + 0x1FF, len = #entry.link, mtime = entry.mtime }
		link_to = entry.link
	end
	return File { url = url, stat = stat, lstat = lstat, link_to = link_to }
end

-- === Network operations ===

local function list(job, dir)
	local c = cfg(job)
	local path = ftp_path(dir)

	local output, err = curl(c):arg(dir_url(c, path)):output()
	if not output then
		return nil, err
	end
	if not output.status.success then
		return nil, failure(output, "Failed to list " .. path)
	end

	local now = os.date("*t")
	local entries = {}
	for line in tostring(output.stdout):gmatch("[^\r\n]+") do
		local entry = parse_line(line, now)
		if entry then
			entries[#entries + 1] = entry
		end
	end
	return entries
end

local function quote(job, url, commands)
	local c = cfg(job)
	local parent = url.parent or url

	local args = {}
	for _, command in ipairs(commands) do
		args[#args + 1] = "-Q"
		args[#args + 1] = command
	end

	local devnull = ya.target_os() == "windows" and "NUL" or "/dev/null"
	local output, err = curl(c)
		:arg(args)
		:arg("-o")
		:arg(devnull)
		:arg(dir_url(c, ftp_path(parent)))
		:output()
	if not output then
		return nil, err
	end
	if not output.status.success then
		return nil, failure(output, commands[1])
	end
	return true
end

local function entry_of(job, url)
	local path = ftp_path(url)
	if path == "/" then
		return { mode = 0x4000 + 493, size = 0 }
	end

	local parent = url.parent
	local name = url.name and tostring(url.name) or nil
	if not parent or not name or name == "" then
		return nil, Error.fs { kind = "NotFound", message = "No such file: " .. path }
	end

	local entries, err = list(job, parent)
	if not entries then
		return nil, err
	end
	for _, entry in ipairs(entries) do
		if entry.name == name then
			return entry
		end
	end
	return nil, Error.fs { kind = "NotFound", message = "No such file: " .. path }
end

local function file_of(job, url)
	local entry, err = entry_of(job, url)
	if not entry then
		return nil, err
	end
	return to_file(url, entry)
end

local function stat_of(job, url)
	local entry, err = entry_of(job, url)
	if not entry then
		return nil, err
	end
	return to_stat(entry)
end

-- === File handles ===

local handles = 0

local function read(job)
	return ya.co(function()
		local c = cfg(job)
		local offset = job.offset and job.offset.value or 0
		if offset < 0 then
			offset = 0
		end

		local cmd = curl(c)
		if offset > 0 then
			cmd = cmd:arg({ "--range", tostring(offset) .. "-" })
		end
		local child, err = cmd:arg(origin(c) .. ftp_path(job.url)):stdout(Command.PIPED):spawn()
		if not child then
			return nil, err
		end

		while true do
			local data, event = child:read(65536)
			if event ~= 0 or not data or #data == 0 then
				break
			end
			coroutine.yield(data)
		end
		child:wait()
	end)
end

-- === Provide ===

function M:provide(job)
	local op = job.op

	if op == "Capabilities" then
		return {
			absolute = 1,
			file = 1,
			metadata = 1,
			symlink_metadata = 1,
			read_dir = 1,
			revalidate = 1,
			open = 1,
			create_dir = 1,
			remove_dir = 1,
			remove_file = 1,
			rename = 1,
		}
	elseif op == "Absolute" then
		return job.url
	elseif op == "File" then
		return file_of(job, job.url)
	elseif op == "Revalidate" then
		local file, err = file_of(job, job.file.url)
		if not file then
			return nil, err
		elseif hits(file.stat, job.file.stat) then
			return nil
		end
		return file
	elseif op == "Metadata" or op == "SymlinkMetadata" then
		return stat_of(job, job.url)
	elseif op == "ReadDir" then
		return ya.co(function()
			local c = cfg(job)
			local entries, err = list(job, job.url)
			if not entries then
				return nil, err
			end
			for _, entry in ipairs(entries) do
				coroutine.yield(to_file(job.url:join(entry.name), entry))
			end
		end)
	elseif op == "Open" then
		handles = handles + 1
		return { id = handles, seekless = not cfg(job).seek }
	elseif op == "Read" then
		return read(job)
	elseif op == "Close" then
		return true
	elseif op == "CreateDir" then
		return quote(job, job.url, { "MKD " .. ftp_path(job.url) })
	elseif op == "RemoveDir" then
		return quote(job, job.url, { "RMD " .. ftp_path(job.url) })
	elseif op == "RemoveFile" then
		return quote(job, job.url, { "DELE " .. ftp_path(job.url) })
	elseif op == "Rename" then
		local to = tostring(job.to)
		if to:sub(1, 1) ~= "/" then
			to = "/" .. to
		end
		return quote(job, job.from, { "RNFR " .. ftp_path(job.from), "RNTO " .. to })
	end

	return false, Error.fs {
		kind = "Unsupported",
		message = "ftp:// does not support " .. op,
	}
end

return M
