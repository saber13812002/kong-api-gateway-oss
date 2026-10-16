-- Custom plugin "oss-post" — response post-processing.
--
-- Phases:
--   * ACCESS:         store per-request state (conf, transform flag, budget)
--   * header_filter:  add response header(s) directly on ngx.header; if a
--                     body transform is configured, CLEAR the upstream
--                     Content-Length so the client framing becomes
--                     Transfer-Encoding: chunked. (Kong 3.x has no
--                     kong.service.response header API; the bundled
--                     response-transformer likewise works in header_filter.)
--   * body_filter:    optionally transform the (small) JSON response body
--                     (top-level key renames, e.g. status -> success)
--
-- WHY Content-Length is cleared in header_filter (critical, documented):
--   nginx flushes response headers to the client in the header-filter
--   stage, BEFORE any body filter runs. If the transform changed the body
--   length, the original Content-Length would be wrong and the client
--   would hang (body shorter) or desynchronize (body longer). By clearing
--   the header in the header_filter phase the final response is framed as
--   "Transfer-Encoding: chunked" and the body filter can safely emit a
--   transformed body of ANY length.
--   Consequence (documented limitation): responses from routes with
--   transform_body=true are always chunked, including pass-through
--   responses (empty / non-JSON / errors).
--
-- Body transformation only applies when ALL of the following hold:
--   - transform_body = true and at least one key_rename is configured
--   - upstream status < 300 (errors pass through untouched)
--   - Content-Type contains "json" (text/binary pass through untouched)
--   - total body size <= max_body_bytes (default 1 MiB)
--
-- response_buffering (route option):
--   Recommended "on" for transform routes: nginx keeps the whole upstream
--   body in its proxy buffers before writing to the client, which bounds
--   the time the transformed body is held and keeps client-side latency
--   deterministic. The plugin works with buffering off as well (it
--   accumulates chunks in Lua regardless), at the cost of delaying the
--   client response until the upstream stream ends (no streaming).
--
-- Memory:
--   The body is accumulated in Lua memory and the budget is enforced
--   incrementally: once accumulated bytes exceed max_body_bytes the
--   plugin stops buffering, flushes what it has, and passes all
--   subsequent chunks through untouched (no transform). Worst-case
--   Lua memory for one request = max_body_bytes + one chunk
--   (<= the nginx proxy buffer size, default 4 KiB x2).
--
-- Security:
--   * No request/response secrets are logged; only neutral diagnostics.
--   * Correlation id echoed back is either the client's own header
--     value or a value the plugin generated — no server data.
--   * JSON decode/encode are wrapped in pcall; malformed input falls
--     back to the original body, never an error response.
local cjson = require "cjson.safe"
local kong = kong

local OssPost = {
  NAME = "oss-post",
  VERSION = "1.0.0",
  PRIORITY = -500, -- after pre plugins in the ACCESS phase
  PHASES = {
    access = 1,
    header_filter = 2,
    body_filter = 3,
  },
}


function OssPost:access(conf)
  conf = conf or {}

  local do_transform = (conf.transform_body == true)
    and (conf.key_rename and next(conf.key_rename) ~= nil)

  ngx.ctx.oss_post = {
    conf = conf,
    transform = do_transform,
    max_bytes = conf.max_body_bytes or (1024 * 1024),
    parts = nil,
    first_handled = false,
    pass_through = false,
  }
end


function OssPost:header_filter()
  local st = ngx.ctx.oss_post
  if not st then
    return -- not our request
  end

  local conf = st.conf
  ngx.header[conf.resp_header_name or "X-Oss-Post"] =
    conf.resp_header_value or "processed"

  if conf.echo_request_header then
    local v = ngx.ctx.oss_correlation_id
      or kong.request.get_header(conf.echo_request_header)
    if v and v ~= "" then
      ngx.header[conf.echo_request_header] = v
    end
  end

  if st.transform then
    -- force chunked client framing (see header comment)
    ngx.header["Content-Length"] = nil
  end
end


function OssPost:body_filter()
  local st = ngx.ctx.oss_post
  if not st then
    return -- not our request / transform disabled
  end

  local chunk = ngx.arg[1] or ""
  local is_last = ngx.arg[2] and true or false

  -- Decide on the first chunk: upstream status + Content-Type are known now.
  if not st.first_handled then
    st.first_handled = true
    local status = tonumber(ngx.var.status) or 0
    local ct = tostring(ngx.header["Content-Type"] or "")
    if status >= 300 or not ct:find("json", 1, true) then
      st.pass_through = true
    end
  end

  if not st.transform then
    return -- nothing to do; original stream untouched
  end

  -- Budget exceeded mid-stream: stop buffering, flush, pass through.
  if st.over_budget then
    ngx.arg[1] = chunk
    return
  end

  if not st.parts then
    st.parts = {}
  end
  st.parts[#st.parts + 1] = chunk
  st.total = (st.total or 0) + #chunk
  if st.total > st.max_bytes then
    -- Budget exceeded: flush EVERYTHING accumulated so far (including this
    -- chunk) in one piece, then pass the rest of the stream through
    -- untouched. This guarantees the client receives the COMPLETE,
    -- untransformed body (the earlier chunks were swallowed with
    -- ngx.arg[1] = "" and must be re-emitted here).
    st.over_budget = true
    local acc = table.concat(st.parts)
    st.parts = nil
    ngx.arg[1] = acc
    return
  end

  if not is_last then
    ngx.arg[1] = "" -- swallow until the final chunk
    return
  end

  local body = table.concat(st.parts)
  st.parts = nil

  if st.pass_through or st.over_budget or #body == 0 then
    ngx.arg[1] = body
    -- re-emit original (over-budget bodies pass through untouched)
    return
  end

  local ok, out = pcall(function()
    local obj = cjson.decode(body)
    if type(obj) ~= "table" then
      return nil
    end
    local changed = false
    for from, to in pairs(st.conf.key_rename) do
      if obj[from] ~= nil and obj[to] == nil then
        obj[to] = obj[from]
        obj[from] = nil
        changed = true
      end
    end
    if not changed then
      return nil
    end
    return cjson.encode(obj)
  end)

  if ok and out then
    ngx.arg[1] = out -- chunked framing absorbs the length change
  else
    -- not JSON / no rename applied / encode error: original body
    ngx.arg[1] = body
  end
end

return OssPost
