-- STEP 4 custom plugin "step4-post" — response post-processing.
--
-- Phases:
--   * ACCESS:      add response header(s) via kong.service.response.set_header
--                  (same mechanism as the bundled response-transformer);
--                  if a body transform is configured, CLEAR the upstream
--                  Content-Length via kong.service.response.clear_header so
--                  the client framing becomes Transfer-Encoding: chunked.
--   * body_filter: optionally transform the (small) JSON response body
--                  (top-level key renames, e.g. status -> success)
--
-- WHY Content-Length is cleared in ACCESS (critical, documented):
--   nginx flushes response headers to the client in the header-filter
--   stage, BEFORE any body filter runs. If the transform changed the body
--   length, the original Content-Length would be wrong and the client
--   would hang (body shorter) or desynchronize (body longer). By clearing
--   the header in the ACCESS phase — Kong merges service-response header
--   overrides in the header-filter stage, exactly like the
--   response-transformer does — the final response is framed as
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
--   The body is accumulated in Lua memory, bounded by max_body_bytes
--   (bodies over the limit are re-emitted untouched). One extra chunk
--   (<= ngx proxy buffer size) may transiently exceed the limit.
local cjson = require "cjson.safe"
local kong = kong

local Step4Post = {
  NAME = "step4-post",
  PRIORITY = -500, -- after pre plugins in the ACCESS phase
  PHASES = {
    access = 1,
    body_filter = 2,
  },
}


function Step4Post:access()
  local conf = (kong.plugin.get_conf() or {}).config or {}

  kong.service.response.set_header(
    conf.resp_header_name or "X-Step4-Post",
    conf.resp_header_value or "processed")

  if conf.echo_request_header then
    local v = ngx.ctx.step4_correlation_id
      or kong.request.get_header(conf.echo_request_header)
    if v and v ~= "" then
      kong.service.response.set_header(conf.echo_request_header, v)
    end
  end

  local do_transform = (conf.transform_body == true)
    and (conf.key_rename and next(conf.key_rename) ~= nil)

  if do_transform then
    -- force chunked client framing (see header comment)
    kong.service.response.clear_header("Content-Length")
  end

  ngx.ctx.step4_post = {
    conf = conf,
    transform = do_transform,
    max_bytes = conf.max_body_bytes or (1024 * 1024),
    parts = nil,
    first_handled = false,
    pass_through = false,
  }
end


function Step4Post:body_filter()
  local st = ngx.ctx.step4_post
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

  if not st.parts then
    st.parts = {}
  end
  st.parts[#st.parts + 1] = chunk

  if not is_last then
    ngx.arg[1] = "" -- swallow until the final chunk
    return
  end

  local body = table.concat(st.parts)
  st.parts = nil

  if st.pass_through or #body == 0 then
    ngx.arg[1] = body -- re-emit original (empty for zero-length bodies)
    return
  end

  if #body > st.max_bytes then
    ngx.arg[1] = body -- too large: re-emit original untouched
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

return Step4Post
