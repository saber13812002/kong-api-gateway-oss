-- STEP 4 custom plugin "step4-pre" — request pre-processing (ACCESS phase).
--
-- 1) validates required request headers -> controlled JSON error (400)
-- 2) adds a correlation id when missing (never overwrites an incoming one)
-- 3) renames top-level JSON body keys (request body transformation)
--
-- Body preservation: unless a rename actually applies, the request body is
-- left completely untouched (non-JSON bodies pass through as-is).
local cjson = require "cjson.safe"
local kong = kong

math.randomseed(os.time())

local Step4Pre = {
  NAME = "step4-pre",
  PRIORITY = 500, -- before request-transformer (801) and post plugins
  PHASES = { access = 1 },
}


local function read_full_body()
  ngx.req.read_body()
  local data = ngx.req.get_body_data()
  if data then
    return data
  end
  -- large body was buffered to a temp file by nginx
  local file = ngx.req.get_body_file()
  if file then
    local f, err = io.open(file, "rb")
    if not f then
      ngx.log(ngx.ERR, "step4-pre: cannot open body file: ", err)
      return nil
    end
    local d = f:read("*a")
    f:close()
    return d
  end
  return nil
end


function Step4Pre:access()
  local conf = (kong.plugin.get_conf() or {}).config or {}

  -- 1) required header validation -> controlled JSON error
  if conf.required_headers then
    local req_headers = kong.request.get_headers()
    for _, name in ipairs(conf.required_headers) do
      local got = req_headers[name:lower()]
      if not got or got == "" then
        return kong.response.exit(400, {
          error = "missing_required_header",
          header = name,
          plugin = "step4-pre",
        })
      end
    end
  end

  -- 2) correlation id (add if missing; never overwrite an existing one)
  if conf.correlation_id_header then
    local cur = kong.request.get_header(conf.correlation_id_header)
    local id = cur
    if not id or id == "" then
      id = string.format("step4-%x-%08x-%08x",
        os.time(),
        math.random(0, 0xFFFFFFFF),
        math.random(0, 0xFFFFFFFF))
      kong.service.request.set_header(conf.correlation_id_header, id)
    end
    -- expose to same-request plugins (e.g. step4-post echo)
    ngx.ctx.step4_correlation_id = id
  end

  -- 3) request JSON body transformation: rename top-level keys
  local renames = conf.body_rename
  if renames and next(renames) then
    local method = kong.request.get_method()
    if method == "POST" or method == "PUT" or method == "PATCH" then
      local body = read_full_body()
      if body and #body > 0 then
        local obj = cjson.decode(body)
        if type(obj) == "table" then
          local changed = false
          for from, to in pairs(renames) do
            if obj[from] ~= nil and obj[to] == nil then
              obj[to] = obj[from]
              obj[from] = nil
              changed = true
            end
          end
          if changed then
            local encoded = cjson.encode(obj)
            if encoded then
              -- adjusts Content-Length automatically
              kong.service.set_raw_body(encoded)
            else
              ngx.log(ngx.ERR,
                "step4-pre: failed to re-encode body; passing original")
            end
          end
        end
        -- non-JSON body: leave untouched (documented limitation)
      end
    end
  end
end

return Step4Pre
