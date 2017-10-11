local _M = {
  _VERSION = '1.4.1'
}

--- Pre checks --------------------------------------------------------------------------------

if not ngx.config or not ngx.config.ngx_lua_version or ngx.config.ngx_lua_version < 9005 then
  error("ngx_lua 0.9.5+ required")
end

local lock, http

do
  local ok

  ok, lock = pcall(require, "resty.lock")
  if not ok then
    error("resty.lock module required")
  end

  ok, http = pcall(require, "resty.http")
  if not ok then
    error("resty.http module required")
  end
end

--- Log wrappers-------------------------------------------------------------------------------

local debug_enabled = false

local function warn(...)
  ngx.log(ngx.WARN, "healthcheck: ", ...)
end

local function errlog(...)
  ngx.log(ngx.ERR, "healthcheck: ", ...)
end

local function debug(...)
  if debug_enabled then
    ngx.log(ngx.DEBUG, "healthcheck: ", ...)
  end
end

--- Helpers -----------------------------------------------------------------------------------

local function gen_peer_key(prefix, peer)
  return prefix .. peer.upstream.name .. ":" .. peer.name
end

--- Implementation ----------------------------------------------------------------------------

local function set_peer_state_globally(ctx, peer, state)
  local ok, _, err = state.fun(peer.upstream.name, peer)
  if not ok then
    errlog("failed to set peer state: ", err)
  end
  peer.down = state.down
  ctx.set_dict_key("down", peer, peer.down)
end

local function state_up(ctx)
  return {
    fun = ctx.set_peer_up,
    down = false
  }
end

local function state_down(ctx)
  return {
    fun = ctx.set_peer_down,
    down = true
  }
end

local function peer_fail(ctx, peer)
  local ok, fails = ctx.get_dict_key("fail", peer, 0)
  if not ok then
    return
  end

  fails = fails + 1

  if fails == 1 then
    ctx.set_dict_key("succ", peer, 0)
  end

  ctx.set_dict_key("fail", peer, fails)

  if fails >= peer.upstream.healthcheck.fall and not peer.down then
    warn("upstream: ", peer.upstream.name, " peer: ", peer.name, " is turned down after ", fails, " failure(s)")
    set_peer_state_globally(ctx, peer, state_down(ctx))
  end

  ctx.incr_dict_key("g_fails", peer)
end

local function peer_ok(ctx, peer)
  local ok, succ = ctx.get_dict_key("succ", peer, 0)
  if not ok then
    return
  end

  succ = succ + 1

  if succ == 1 then
    ctx.set_dict_key("fail", peer, 0)
  end

  ctx.set_dict_key("succ", peer, succ)

  if succ >= peer.upstream.healthcheck.rise and peer.down then
    debug("upstream: ", peer.upstream.name, " peer: ", peer.name, " is turned up after ", succ, " success(es)")
    set_peer_state_globally(ctx, peer, state_up(ctx))
  end

  ctx.incr_dict_key("g_successes", peer)
end

local function change_peer_state(ok, ctx, peer)
  if not ok then
    peer_fail(ctx, peer)
  else
    peer_ok(ctx, peer)
  end
end

local function check_tcp(ctx, peer)
  local sock
  local ok, err

  debug("Checking ", ctx.upstream_type, " peer ", peer.name, " with tcp")

  sock, err = ngx.socket.tcp()
  if not sock then
    errlog("failed to create stream socket: ", err)
    return
  end

  sock:settimeout(peer.upstream.healthcheck.timeout)

  if peer.host then
    ok, err = sock:connect(peer.host, peer.port)
  else
    ok, err = sock:connect(peer.name)
  end

  if not ok then
    if not peer.down then
      errlog("failed to connect to ", peer.name, ": ", err)
    end
  else
    if peer.upstream.healthcheck.command then
      local bytes
      bytes, err = sock:send(peer.upstream.healthcheck.command.body)
      local expected = peer.upstream.healthcheck.command.expected or {}
      if not err and expected.body then
        local data = ""
        while true
        do
          local part
          part, err = sock:receive("*l")
          if part then
            data = data .. part
            if ngx.re.match(data, expected.body, "mx") then
              break
            end
          else
            err = "pattern is not found"
            break
          end
        end
      end
      if not bytes then
        ok = nil
        if not peer.down then
          errlog("failed to check ", peer.name, ": ", err)
        end
      end
    end
    sock:close()
  end

  change_peer_state(ok, ctx, peer)
end

local function check_peer(ctx, peer)
  if ctx.typ == "tcp" or not peer.upstream.healthcheck.command then
    check_tcp(ctx, peer)
    return
  end

  debug("Checking ", ctx.upstream_type, " upstream: ", peer.upstream.name, " peer: ", peer.name, " with http")

  local httpc = http.new()

  httpc:set_timeout(peer.upstream.healthcheck.timeout)

  local ok, err = httpc:connect(peer.host, peer.port or 80)
  if not ok then
    warn("Checking ", ctx.upstream_type, " upstream: ", peer.upstream.name, " peer ", peer.name, " : ", err)
    peer_fail(ctx, peer)
    return
  end

  peer.upstream.healthcheck.command.path = peer.upstream.healthcheck.command.uri

  local response, err = httpc:request(peer.upstream.healthcheck.command)

  if not response then
    warn("Checking ", ctx.upstream_type, " upstream: ", peer.upstream.name, " peer ", peer.name, " : ", err)
    peer_fail(ctx, peer)
    return
  end

  if not peer.upstream.healthcheck.command.expected then
    httpc:close()
    peer_ok(ctx, peer)
    return
  end

  local check_status = function(valid_statuses, status)
    if not valid_statuses then
      return true
    end
    for i=1,#valid_statuses
    do
      if valid_statuses[i] == status then
        return true
      end
    end
    debug("Checking ", ctx.upstream_type, " upstream: ", peer.upstream.name,
          " peer ", peer.name, " : http status=", status, " is not in the valid statuses list")
    return false
  end

  response.body, err = response:read_body()

  httpc:close()

  if err then
    warn("Checking ", ctx.upstream_type, " upstream: ", peer.upstream.name, " peer ", peer.name, " : ", err)
    peer_fail(ctx, peer)
    return
  end

  debug("Checking ", ctx.upstream_type, " upstream: ", peer.upstream.name,
        " peer ", peer.name, " : http status=", response.status, " body=[", response.body, "]")

  if not check_status(peer.upstream.healthcheck.command.expected.codes, response.status) then
    peer_fail(ctx, peer)
    return
  end

  if peer.upstream.healthcheck.command.expected.body then
    if not ngx.re.match(response.body, peer.upstream.healthcheck.command.expected.body) then
      debug("Checking ", ctx.upstream_type, " upstream: ", peer.upstream.name, " peer ", peer.name,
            " : body=[", response.body, "] is not match the re=", peer.upstream.healthcheck.command.expected.body)
      peer_fail(ctx, peer)
      return
    end
  end

  peer_ok(ctx, peer)
end

local function check_peers(ctx, peers)
  local total = #peers
  local step_size = math.min(ctx.concurrency, total)
  local steps = math.ceil(total / step_size)

  for i = 0, steps - 1
  do
    local threads = {}
    local size = math.min(step_size, total - i * step_size)

    for j = 1, size
    do
      table.insert(threads, ngx.thread.spawn(check_peer, ctx, peers[i * step_size + j]))
    end

    for j = 1, size
    do
      local ok, err = ngx.thread.wait(threads[j])
      if not ok then
        warn(err)
      end
    end
  end
end

local function preprocess_peers(peers, upstream)
  for _, peer in pairs(peers)
  do
    peer.upstream = upstream
    if peer.name then
      local from, to = ngx.re.find(peer.name, [[^(.*):\d+$]], "jo", nil, 1)
      if from then
        peer.host = peer.name:sub(1, to)
        peer.port = tonumber(peer.name:sub(to + 2))
      end
    end
  end
  return peers
end

local function do_check(ctx)
  local elapsed = ctx.mutex:lock("mutex:hc:cycle")
  if not elapsed then
    return
  end

  local all_peers = {}
  local now = ngx.now()


  local ok, upstreams, err = ctx.get_upstreams()
  if not ok then
    warn("failed to get upstreams: ", err)
    return
  end

  for _, u in ipairs(upstreams)
  do
    local ok, peers, err = ctx.get_peers(u.name)
    if not ok then
      warn("failed to get peers [upstream:" .. u.name .. "]: ", err)
    else
      for _, peer in pairs(preprocess_peers(peers, u))
      do
        local _, disabled = ctx.get_dict_key("disabled", peer)
        if not disabled then
          if peer.upstream.healthcheck or ctx.check_all then
            if not peer.upstream.healthcheck then
              peer.upstream.healthcheck = ctx.healthcheck
            end
            if not peer.upstream.healthcheck.interval then
              peer.upstream.healthcheck.interval = ctx.healthcheck.interval
            end
            local _, last = ctx.get_dict_key("last", peer, 0)
            if last + peer.upstream.healthcheck.interval <= now then
              table.insert(all_peers, peer)
              ctx.set_dict_key("last", peer, now)
            end
          end
        end
      end
    end
  end

  check_peers(ctx, all_peers)

  ctx.mutex:unlock()
end

local check
check = function (premature, ctx)
  if premature or ctx.stop then
    return
  end

  local ok, err

  ok, err = pcall(do_check, ctx)
  if not ok then
    errlog("failed to run healthcheck cycle: ", err)
  end

  ok, err = ngx.timer.at(1, check, ctx)
  if not ok then
    if err ~= "process exiting" then
      errlog("failed to create timer: ", err)
    end
  end
end

local function init_down_state(ctx)
  local ok, upstreams, err = ctx.get_upstreams()
  if not ok then
    error(err)
  end
  for _, u in pairs(upstreams)
  do
    local ok, peers, err = ctx.get_peers(u.name)
    if not ok then
      error(err)
    end
    for _, peer in ipairs(peers)
    do
      peer.upstream = u
      if u.healthcheck or ctx.check_all then
        local _, disabled = ctx.get_dict_key("disabled", peer)
        local _, down = ctx.get_dict_key("down", peer, true)
        if not disabled and not down then
          local ok, succ = ctx.get_dict_key("succ", peer, 0)
          if ok and succ >= (u.healthcheck or ctx.healthcheck).rise then
            ctx.set_peer_up(u.name, peer)
          end
        else
          ctx.set_peer_down(u.name, peer)
        end
      end
    end
  end
end

local function spawn_checker(self)
  local opts = self.opts

  self.ctx = {
    upstream_type = opts.upstream_type,

    healthcheck = opts.healthcheck or {
      fall = 1,
      rise = 1,
      timeout = 1000
    },
    check_all = opts.check_all,
    dict      = ngx.shared[opts.shm],
    typ       = opts.typ or "tcp",
    shm       = opts.shm,

    concurrency = opts.concurrency or 100,

    set_peer_down = self.tab.set_peer_down,
    set_peer_up   = self.tab.set_peer_up,
    get_peers     = self.tab.get_peers,
    get_upstreams = self.tab.get_upstreams,

    set_dict_key = function(prefix, peer, val)
      local key = gen_peer_key(self.ctx.upstream_type .. ":" .. prefix .. ":", peer)
      local ok, err = self.ctx.dict:set(key, val)
      if not ok then
        errlog("failed to set key " .. key .. ", error: ", err)
      end
    end,

    get_dict_key = function(prefix, peer, default)
      local key = gen_peer_key(self.ctx.upstream_type .. ":" .. prefix .. ":", peer)
      local val, err = self.ctx.dict:get(key)
      if val == nil then
        if err then
          errlog("failed to get key " .. key .. ", error: ", err)
          return false, nil
        end
        val = default
      end
      return true, val
    end,

    incr_dict_key = function(prefix, peer)
      local key = gen_peer_key(self.ctx.upstream_type .. ":" .. prefix .. ":", peer)
      local ok, err = self.ctx.dict:incr(key, 1, 0)
      if not ok then
        errlog("failed to increment key " .. key .. ", error: ", err)
      end
    end,
  }

  local ctx = self.ctx

  if not ctx.healthcheck.interval then
    ctx.healthcheck.interval = ((opts.interval or 10) > 0) and (opts.interval or 10) or 10
  end

  if not ctx.shm then
    return nil, "'shm' option required"
  end

  if not ctx.dict then
    return nil, "shm '" .. tostring(ctx.shm) .. "' not found"
  end

  if ctx.typ ~= "http" and ctx.typ ~= "tcp" then
    return nil, "'http' and 'tcp' type can be used"
  end

  local ok, err
  ctx.mutex, err = lock:new(ctx.shm)
  if not ctx.mutex then
    return nil, "failed to create timer: " .. err
  end

  if ngx.worker.id() == 0 then
    init_down_state(ctx)
  end

  ok, err = ngx.timer.at(0, check, ctx)
  if not ok then
    return nil, "failed to create timer: " .. err
  end

  return true
end

--- API ---------------------------------------------------------------------------------------

function _M.new(upstream_type, opts, tab)
  local hc = {}

  hc.opts = opts
  hc.opts.upstream_type = upstream_type
  hc.tab = tab

  local mt = { __index = {
    start         = spawn_checker,
    stop          = function(self)
      self.ctx.stop = true
    end,
    upstream_type = _M.upstream_type
  } }

  return setmetatable(hc, mt)
end

function _M.successes(upstream_type, dict, u, peer)
  peer.upstream = { name = u }
  local val, _ = dict:get(gen_peer_key(upstream_type .. ":g_successes:", peer))
  if not val then
    val = "-"
  end
  return val
end

function _M.fails(upstream_type, dict, u, peer)
  peer.upstream = { name = u }
  local val, _ = dict:get(gen_peer_key(upstream_type .. ":g_fails:", peer))
  if not val then
    val = "-"
  end
  return val
end

function _M.upstream_type(self)
  return self.ctx.upstream_type
end

function _M.enable_debug()
  debug_enabled = true
end

function _M.disable_peer(upstream_type, dict, u, peer_name)
  if u and peer_name then
    local peer = {
      name = peer_name,
      upstream = { name = u }
    }
    dict:set(gen_peer_key(upstream_type .. ":disabled:", peer), 1)
  end
end

function _M.enable_peer(upstream_type, dict, u, peer_name)
  if u and peer_name then
    local peer = {
      name = peer_name,
      upstream = { name = u }
    }
    dict:delete(gen_peer_key(upstream_type .. ":disabled:", peer))
  end
end

return _M