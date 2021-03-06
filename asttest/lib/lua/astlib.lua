--
-- Asterisk -- An open source telephony toolkit.
--
-- Copyright (C) 1999 - 2008, Digium, Inc.
--
-- Matthew Nicholson <mnicholson@digium.com>
--
-- See http://www.asterisk.org for more information about
-- the Asterisk project. Please do not directly contact
-- any of the maintainers of this project for assistance;
-- the project provides a web site, mailing lists and IRC
-- channels for your use.
--
-- This program is free software, distributed under the terms of
-- the GNU General Public License Version 2. See the LICENSE file
-- at the top of the source tree.
--

module(..., package.seeall)

function exists()
	return select(1, proc.exists(path .. "/usr/sbin/asterisk"))
end

function new()
	return asterisk:new()
end

function version(ver)
	local version = ver or _version()
	if version == "unknown" then
		-- read version from Asterisk
		local ast = proc.exec_io("asterisk", "-V")
		if not ast then
			error("error determining asterisk version; unable to execute asterisk -V")
		end
		version = ast.stdout:read("*all")
		version = string.gsub(version,"Asterisk ", "")
		if not version then
			error("error determining asterisk version")
		end
	end
	return asterisk_version:new(version)
end

function has_major_version(v)
	if v == "trunk" then
		v = "SVN-trunk-r00000"
	end

	local v1 = version(v)
	local v2 = version()

	return v1.branch == v2.branch
end

function asterisk_gc(a, p)
	return function()
		_stop(a, p)
	end
end

_set_asterisk_gc_generator(asterisk_gc)
_set_asterisk_gc_generator = nil

-- asterisk table is created in astlib.c
function asterisk:new()
	local a = self:_new()
	a.configs = {}
	a.asterisk_conf = a.work_area .. "/etc/asterisk/asterisk.conf"
	a.essential_configs = {
		["asterisk.conf"] = asterisk.generate_asterisk_conf,
		["logger.conf"] = asterisk.generate_logger_conf,
	}

	setmetatable(a, self)
	return a
end

function asterisk:path(path)
	return self.work_area .. path
end

function asterisk:_spawn()
	local p = proc.exec(self.asterisk_binary,
		"-f", "-g", "-q", "-m",
		"-C", self.asterisk_conf
	)
	_setup_gc(self, p)
	rawset(self, "proc", p)
end

-- note this timesout after five minutes
function asterisk:cli(command)
	local p = proc.exec_io(self.asterisk_binary,
		"-r", "-x", command,
		"-C", self.asterisk_conf
	)

	-- wait up to 5 minutes for the process to exit.  If the process does
	-- not exit within 5 minutes, return a error.
	local res, err = p:wait(300000)
	if not res then
		return res, err
	end

	if res ~= 0 then
		local output = p.stdout:read("*a")
		if not output then
			return nil, "error connecting to asterisk cli"
		end
		return nil, output
	end

	return p.stdout:read("*a")
end

function asterisk:_waitfullybooted()
	-- wait for asterisk to be fully booted.  We do this by reading the
	-- output of the 'core waitfullybooted' command and looking for the
	-- string 'fully booted'.  We will try 45 times before completely
	-- giving up with a 1000 ms delay in between each try.  This is
	-- necessary to give asterisk time to start the CLI socket.
	local booted
	local output = ""
	for _=1,45 do
		local err
		booted, err = self:cli("core waitfullybooted")
		
		if #output ~= 0 then
			output = output .. "=====\n"
		end

		if booted then
			output = output .. booted

			if booted:find("fully booted") then
				break
			end
		else
			output = output .. err
		end

		posix.usleep(1000000)
	end
	if booted and not booted:find("fully booted") then
		print("error waiting for asterisk to fully boot: " .. booted)
		print("checking to see if asterisk is still running")
		local res, err = proc.perror(self:wait(1000))
		if not res and err == "timeout" then
			print("seems like asterisk is still running, but we cannot wait for it to be fully booted.  That is odd.")
		elseif res then
			print("asterisk exited with " .. res)
		end

		print("\noutput from all of our 'core waitfullybooted' attempts:")
		print(output)

		print("\nfull log follows:\n")
		self:dump_full_log()
		
		error("error starting asterisk")
	end
end

function asterisk:spawn()
	self:clean_work_area()
	self:create_work_area()
	self:generate_essential_configs()
	self:write_configs()
	self:_spawn()
	self:_waitfullybooted()
end

function asterisk:spawn_and_wait()
	self:spawn()
	return self:wait()
end

function asterisk:wait(timeout)
	if not self.proc then return nil, "error" end
	return self.proc:wait(timeout)
end

function _stop(a, p)
	local res, err

	-- 1.6+ stop commands
	local stop_gracefully = "core stop gracefully"
	local stop_now = "core stop now"

	-- if this is 1.4 or less use 1.4 stop commands
	if version() < version("1.6") then
		stop_gracefully = "stop gracefully"
		stop_now = "stop now"
	end

	a:cli(stop_gracefully)
	res, err = p:wait(5000)
	if res or (not res and err ~= "timeout") then
		return res, err
	end

	a:cli(stop_now)
	res, err = p:wait(5000)
	if res or (not res and err ~= "timeout") then
		return res, err
	end

	return p:term_or_kill()
end

function asterisk:stop()
	if not self.proc then return nil, "error" end
	return _stop(self, self.proc)
end

asterisk.term_or_kill = asterisk.stop

function asterisk:__newindex(conffile_name, conffile)
	if (getmetatable(conffile) ~= config) then
		error("got " .. type(conffile) .. " expected type config")
	end
	self.configs[conffile_name] = conffile
	if conffile.name == "asterisk.conf" then
		self.asterisk_conf = conffile.filename
	end
end

--- Index an asterisk object
-- This function will return either the config with the given name, the actual
-- table member with the given name, or if neither of those exist, it will
-- create a config with the given name.
function asterisk:__index(key)
	if self.configs[key] then
		return self.configs[key]
	end

	if asterisk[key] ~= nil then
		return asterisk[key]
	end

	return self:new_config(key)
end

function asterisk:manager_connect()
	local m = manager:new()

	local res, err = m:connect(self.configs["manager.conf"]["general"].bindaddr, self.configs["manager.conf"]["general"].port)
	if not res then
		return nil, err
	end

	return m
end

function asterisk:load_config(file, conf_name)
	-- if conf_name is not specified, pull it from the string
	if not conf_name then
		if file:find("/") then
			conf_name = file:match(".*/(.+)$")
		else
			conf_name = file
		end
	end

	local c = config:from_file(conf_name, file, self:path("/etc/asterisk/") .. conf_name)
	self[conf_name] = c
	return c
end

function asterisk:new_config(name)
	local c = config:new(name, self:path("/etc/asterisk/") .. name)
	self[name] = c
	return c
end

function asterisk:write_configs()
	for _, conf in pairs(self.configs) do
		conf:_write()
	end
end

--- Setup default asterisk.conf with our work area directories.
function asterisk:generate_asterisk_conf()
	-- return if it exists already
	if self.configs["asterisk.conf"] then return end

	local c = self:new_config("asterisk.conf")
	local s = c:new_section("directories")
	s["astetcdir"] = self:path("/etc/asterisk")
	s["astmoddir"] = self:path("/usr/lib/asterisk/modules")
	s["astvarlibdir"] = self:path("/var/lib/asterisk")
	s["astdbdir"] = self:path("/var/lib/asterisk")
	s["astkeydir"] = self:path("/var/lib/asterisk")
	s["astdatadir"] = self:path("/var/lib/asterisk")
	s["astagidir"] = self:path("/var/lib/asterisk/agi-bin")
	s["astspooldir"] = self:path("/var/spool/asterisk")
	s["astrundir"] = self:path("/var/run")
	s["astlogdir"] = self:path("/var/log/asterisk")

	s = c:new_section("options")
	s["documentation_language"] = "en_US"
	s["sendfullybooted"]="yes"
	s["verbose"] = 10
	s["debug"] = 10
	s["nocolor"] = "yes"

	s = c:new_section("compat")
	s["pbx_realtime"] = "1.6"
	s["res_agi"] = "1.6"
	s["app_set"] = "1.6"
end

--- Generate logger.conf with debug, messages, and full logs (disable console
-- log).
function asterisk:generate_logger_conf()
	-- return if it exists already
	if self.configs["logger.conf"] then return end

	local c = self:new_config("logger.conf")
	local s = c:new_section("general")
	s = c:new_section("logfiles")
	s["debug"] = "debug"
	s["messages"] = "notice,warning,error"
	s["full"] = "notice,warning,error,debug,verbose,*"
end

--- Generate manager.conf with a unique port.
function asterisk:generate_manager_conf()
	-- return if it exists already
	if self.configs["manager.conf"] then return end

	local c = self:new_config("manager.conf")
	local s = c:new_section("general")
	s["enabled"] = "yes"
	s["bindaddr"] = "127.0.0." .. self.index
	s["port"] = "5038"

	s = c:new_section("asttest")
	s["secret"] = "asttest"
	s["read"] = "all"
	s["write"] = "all"
end

function asterisk:generate_essential_configs()
	for conf, func in pairs(self.essential_configs) do
		if not self.configs[conf] then
			func(self)
		end
	end
end

function asterisk:dump_full_log()
	local log, err = io.open(self:path("/var/log/asterisk/full"), "r")
	if not log then
		print("error opening '" .. self:path("/var/log/asterisk/full") .. "': " .. err)
		return
	end

	print(log:read("*a"))
	log:close()
end

asterisk_version = {}
asterisk_version.__index = asterisk_version
function asterisk_version:new(version)
	local v = {
		version = version,
		order = {},
	}
	setmetatable(v, self)

	v:_parse()
	return v
end

function asterisk_version:_parse_svn()
	self.svn = true
	self.branch, self.revision, self.parent = self.version:match("SVN%-(.*)%-r(%d+M?)%-(.*)")
	if not self.branch then
		self.branch, self.revision = self.version:match("SVN%-(.*)%-r(%d+M?)")
	end

	if not self.branch then
		error("error parsing SVN version number: " .. self.version)
	end

	-- generate a synthetic version number for svn branch versions
	self.patch = self.revision:match("(%d+)M?")
	self.concept, self.major, self.minor = self.branch:match("branch%-([^.]+).(%d+).(%d+)")
	if not self.concept then
		self.minor = "999" -- assume the SVN branch is newer than all released versions
		self.patch = self.revision:match("(%d+)M?")
		self.concept, self.major = self.branch:match("branch%-([^.]+).(%d+)")
	end
	if not self.concept then
		self.concept = self.branch:match("branch%-(%d%d+)")
		self.major = self.revision:match("(%d+)M?") or "999"
		self.minor = nil
		self.patch = nil
	end
	if not self.concept then
		if self.branch == "trunk" then
			self.concept = "999"
			self.major = "0"
			self.minor = "0"
			self.patch = self.revision:match("(%d+)M?")
		else
			-- branch names that don't match are greater
			-- than everything except trunk
			self.concept = "998"
			self.major = "0"
			self.minor = "0"
			self.patch = self.revision:match("(%d+)M?")
		end
	end

	-- branch C.3 is minor version 998, other C.3 branches are 999
	if self.branch == "branch-C.3" then
		self.minor = "998"
	end

	-- store ordering information
	-- if self.concept is not a number, assume a BE branch.  Treat
	-- BE like asterisk 1.5.
	if not self.concept:match("^%d+$") then
		self.order.concept = 1
		self.order.major = 5
		self.order.minor = tonumber(self.minor)
		self.order.patch = tonumber(self.patch)
	else
		self.order.concept = tonumber(self.concept)
		self.order.major = tonumber(self.major)
		self.order.minor = tonumber(self.minor)
		self.order.patch = tonumber(self.patch)
	end

end

function asterisk_version:_parse_release()
	self.concept, self.major, self.minor, self.patch = self.version:match("([^.]+).(%d+).(%d+).(%d+)")
	if not self.concept then
		self.concept, self.major, self.minor = self.version:match("([^.]+).(%d+).(%d+)")
	end
	if not self.concept then
		self.concept, self.major = self.version:match("([^.]+).(%d+)")
	end
	if not self.concept then
		self.concept = self.version:match("(%d%d+)")
	end

	if not self.concept then
		error("error parsing version number: " .. self.version)
	end

	-- generate synthetic svn information
	if ((tonumber(self.concept) or 0) >= 10) then
		self.branch = "branch-" .. self.concept
	else
		self.branch = "branch-" .. self.concept .. "." .. self.major
	end

	-- special handling for 1.6 branches
	if self.concept == "1" and self.major == "6"  and self.minor ~= nil then
		self.branch = self.branch .. "." .. self.minor
	end
	self.revision = "00000"
	
	-- store ordering information
	-- if self.concept is not a number, assume a BE branch.  Treat
	-- BE like asterisk 1.5.
	if not self.concept:match("^%d+$") then
		self.order.concept = 1
		self.order.major = 5
		self.order.minor = tonumber(self.major:match("%d"))
		self.order.patch = tonumber(self.patch or 0)
	else
		self.order.concept = tonumber(self.concept)
		self.order.major = tonumber(self.major or 0)
		self.order.minor = tonumber(self.minor or 0)
		self.order.patch = tonumber(self.patch or 0)
	end
end

function asterisk_version:_parse()
	if self.version:sub(1,3) == "SVN" then
		self:_parse_svn()
	else
		self:_parse_release()
	end
end

function asterisk_version:__tostring()
	return self.version
end

function asterisk_version:__lt(other)
	-- compare each component of the version number starting with the most
	-- significant.  Synthetic version numbers are generated for SVN
	-- versions.
	
	local v = {
		{self.order.concept, other.order.concept},
		{self.order.major, other.order.major},
		{self.order.minor, other.order.minor},
		{self.order.patch, other.order.patch},
	}

	for _, i in ipairs(v) do
		if i[1] < i[2] then
			return true
		elseif i[1] ~= i[2] then
			return false
		end
	end
	return false
end

function asterisk_version:__eq(other)
	return self.version == other.version
end

config = {}
function config:from_file(name, src_filename, dst_filename)
	local ac = config:new(name, dst_filename)

	local f, err = io.open(src_filename, "r");
	if not f then
		error("error opening file '" .. src_filename .. "': " .. err)
	end

	ac:verbatim(f:read("*a"))
	f:close()

	return ac
end

function config:new(name, filename)
	local ac = {
		name = name,
		filename = filename or name,
		sections = {},
		section_index = {},
	}
	setmetatable(ac, self)
	return ac
end

function config:verbatim(data)
	table.insert(self.sections, data)
end

function config:add_section(new_section)
	if (getmetatable(new_section) ~= conf_section) then
		error("got " .. type(new_section) .. " expected type conf_section")
	end
	table.insert(self.sections, new_section)
	if not self.section_index[new_section.name] then
		self.section_index[new_section.name] = #self.sections
	end
end

function config:new_section(section_name)
	s = conf_section:new(section_name)
	self:add_section(s)
	return s
end

--- Index the config object
-- This function will return the section of the config indicated if it exists,
-- if it does not exist it will return the table data member with the given
-- name if it exists, otherwise it will create a section with the given name
-- and return that.
function config:__index(key)
	local s = self.sections[self.section_index[key]]
	if s then return s end

	if config[key] ~= nil then
		return config[key]
	end

	return self:new_section(key)
end

function config:_write(filename)
	if not filename then
		filename = self.filename
	end

	-- remove any existing file or symlink
	unlink(filename)

	local f, e = io.open(filename, "w")
	if not f then
		return error("error writing config file: " .. e)
	end

	for _, section in ipairs(self.sections) do
		if getmetatable(section) == conf_section then
			section:_write(f)
		else
			f:write(tostring(section))
		end
	end

	f:close()
end

conf_section = {}
function conf_section:new(name)
	local s = {
		name = name,
		template = false,
		inherit = {},
		values = {},
		value_index = {},
	}
	setmetatable(s, self)
	return s
end

function conf_section:__newindex(key, value)
	table.insert(self.values, {key, value})
	if not self.value_index[key] then
		self.value_index[key] = #self.values
	end
end

function conf_section:__index(key)
	local v = self.values[self.value_index[key]]
	if v then
		return v[2]
	end

	return conf_section[key]
end

function conf_section:_write(f)
	f:write("[" .. self.name .. "]")
	if self.template then
		f:write("(!")
		for _, i in ipairs(self.inherit) do
			f:write("," .. i)
		end
		f:write(")")
	else
		if #self.inherit ~= 0 then
			f:write("(")
			local first = true
			for _, i in ipairs(self.inherit) do
				if not first then
					f:write(",")
				else
					first = false
				end
				f:write(i)
			end
			f:write(")")
		end
	end
	f:write("\n")

	for _, value in ipairs(self.values) do
		f:write(tostring(value[1]) .. " = " .. tostring(value[2]) .. "\n")
	end
	f:write("\n")
end

--
-- Manager Interface Stuff
--

manager = {
	action = {}
}

manager.__index = manager
function manager:new()
	local m = {
		events = {},
		responses = {},
		event_handlers = {},
		response_handlers = {},
	}

	setmetatable(m, self)
	return m
end

function manager:connect(host, port)
	if not port then
		port = 5038
	end
	local err
	self.sock, err = socket.tcp()
	if not self.sock then
		return nil, err
	end
	local res, err = self.sock:connect(host, port)
	if not res then
		return nil, err
	end

	res, err = self:_parse_greeting()
	if not res then
		self.sock:close()
		return nil, err
	end

	return true
end

function manager:disconnect()
	self.sock:shutdown("both")
	self.sock:close()
	self.sock = nil
end
manager.close = manager.disconnect

--- Read data from a socket until a \r\n is encountered.
--
-- Data is read from the socket one character at a time and placed in a table.
-- Once a \r\n is found, the characters are concatinated into a line (minus the
-- \r\n at the end).  Hopefully this prevents the unnecessary garbage
-- collection that would result from appending the characters to a string one
-- at a time as they are read.
local function read_until_crlf(sock)
	local line = {}
	local cr = false
	while true do
		-- reading 1 char at a time is ok as lua socket reads data from
		-- an internal buffer
		local c, err = sock:receive(1)
		if not c then
			return nil, err
		end

		table.insert(line, c)

		if c == '\r' then
			cr = true
		elseif cr and c == '\n' then
			return table.concat(line, nil, 1, #line - 2)
		else
			cr = false
		end
	end
end

function manager:_parse_greeting()
	local line, err = read_until_crlf(self.sock)
	if not line then
		return nil, err
	end

	self.name, self.version = line:match("(.+)/(.+)")
	if not self.name then
		return nil, "error parsing manager greeting: " .. line
	end

	return true
end

function manager:_read_message()
	local line, err = read_until_crlf(self.sock)
	if not line then
		return nil, err
	end

	local header, value = line:match("([^:]+): (.+)")
	if not header then
		return nil, "error parsing message: " .. line
	end

	local m = manager.message:new()
	m[header] = value
	if header == "Event" then
		table.insert(self.events, m)
	elseif header == "Response" then
		table.insert(self.responses, m)
	else
		return nil, "received unknown message type: " .. header
	end

	local follows = (value == "Follows")
	local data_mode = false
	
	while true do
		line, err = read_until_crlf(self.sock)
		if not line then
			return nil, err
		end

		if line == "" and not follows then
			break
		elseif line == "" and follows then
			data_mode = true
		end

		-- don't attempt to match headers when in data mode
		if not data_mode then
			header, value = line:match("([^:]+): ?(.*)")
		else
			header, value = nil, nil
		end

		if not header and not follows then
			return nil, "error parsing message: " .. line
		elseif not header and follows then
			data_mode = true
			if line == "--END COMMAND--" then
				follows = false
				data_mode = false
			else
				m:_append_data(line .. "\n")
			end
		else
			m[header] = value
		end
	end
	return true
end

function manager:_read_response()
	local res, err = self:wait_response()
	if not res then
		return nil, err
	end

	local r = self.responses[1]
	table.remove(self.responses, 1)
	return r
end

function manager:_read_event()
	local res, err = self:wait_event()
	if not res then
		return nil, err
	end

	local e = self.events[1]
	table.remove(self.events, 1)
	return e
end

function manager:pump_messages()
	while true do
		local read, write, err = socket.select({self.sock}, nil, 0)
		if read[1] ~= self.sock or err == "timeout" then
			break
		end

		local res, err = self:_read_message()
		if not res then
			return nil, err
		end
	end
	return true
end

function manager:wait_event()
	while #self.events == 0 do
		local res, err = self:_read_message()
		if not res then
			return nil, err
		end
	end
	return true
end

function manager:wait_response()
	while #self.responses == 0 do
		local res, err = self:_read_message()
		if not res then
			return nil, err
		end
	end
	return true
end

function manager:process_events()
	while #self.events ~= 0 do
		local e = self.events[1]
		table.remove(self.events, 1)

		for event, handlers in pairs(self.event_handlers) do
			if event == e["Event"] then
				for i, handler in ipairs(handlers) do
					handler(e)
				end
			end
		end

		-- now do the catch all handlers
		for event, handlers in pairs(self.event_handlers) do
			if event == "" then
				for i, handler in ipairs(handlers) do
					handler(e)
				end
			end
		end
	end
end

function manager:process_responses()
	while #self.response_handlers ~= 0 and #self.responses ~= 0 do
		local f = self.response_handlers[1]
		table.remove(self.response_handlers, 1);

		f(self:_read_response());
	end
end

function manager:register_event(event, handler)
	local e_handler = self.event_handlers[event]
	if not e_handler then
		self.event_handlers[event] = {}
	end

	table.insert(self.event_handlers[event], handler)
end

function manager:unregister_event(event, handler)
	for e, handlers in pairs(self.event_handlers) do
		if e == event then
			for i, h in pairs(handlers) do
				if h == handler then
					handlers[i] = nil
					if #handlers == 0 then
						self.event_handlers[e] = nil
					end
					return true
				end
			end
		end
	end
	return nil
end

function manager:send_action(action, handler)
	local response = nil
	function handle_response(r)
		response = r
	end

	if handler then
		return self:send_action_async(action, handler)
	end

	local res, err = self:send_action_async(action, handle_response)
	if not res then
		return nil, err
	end

	while not response do
		res, err = self:wait_response()
		if not res then
			return nil, err
		end
		self:process_responses()
	end
	return response
end
manager.__call = manager.send_action

function manager:send_action_async(action, handler)
	local res, err, i = nil, nil, 0
	local a = action:_format()
	
	while i < #a do
		res, err, i = self.sock:send(a, i + 1)
		if err then
			return nil, err
		else
			i = res
		end
	end
	table.insert(self.response_handlers, handler)
	return true
end


--
-- Manager Helpers
--

manager.message = {}
function manager.message:new()
	local m = {
		headers = {},
		index = {},
		data = nil,
	}
	setmetatable(m, self)
	return m
end

function manager.message:__newindex(key, value)
	table.insert(self.headers, {key, value})
	if not self.index[key] then
		self.index[key] = #self.headers
	end
end

function manager.message:__index(key)
	if self.index[key] then
		return self.headers[self.index[key]][2]
	end

	return manager.message[key]
end

function manager.message:_format()
	local msg = ""
	for i, header in ipairs(self.headers) do
		msg = msg .. header[1] .. ": " .. header[2] .. "\r\n"
	end
	msg = msg .. "\r\n"
	return msg
end

function manager.message:_append_data(data)
	if not self.data then
		rawset(self, "data", data)
	else
		self.data = self.data .. data
	end
end

function manager.action:new(action)
	local a = manager.message:new()

	-- support ast.manager.action.new() syntax
	-- XXX eventually this should be the only syntax allowed
	if action == nil and type(self) == "string" then
		action = self
	end

	a["Action"] = action
	return a
end

-- some utility functions to access common manager functions are defined below

--- Create a login action.
-- This function creates a login action.  When called with no arguments, the
-- default 'asttest', 'asttest' username secret is used.
--
-- @param username the username to send (defaults to 'asttest')
-- @param secret the secret to send (defaults to 'asttest')
function manager.action.login(username, secret)
	local a = manager.action.new("Login")

	username = username or "asttest"
	secret = secret or "asttest"

	a["Username"] = username
	a["Secret"] = secret

	return a
end

--- Create a logoff action.
function manager.action.logoff()
	return manager.action.new("Logoff")
end

--- Ping action.
function manager.action.ping()
	return manager.action.new("Ping")
end

--- Status action.
function manager.action.status(channel)
	local a = manager.action.new("Status")

	if channel then
		a["Channel"] = channel
	end

	return a
end

