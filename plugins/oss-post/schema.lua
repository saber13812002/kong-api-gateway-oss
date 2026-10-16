-- Custom plugin "oss-post" — response post-processing
-- (ACCESS + body_filter phases).
--
-- NOTE: schema shape follows the Kong 3.9.4 plugin contract (see bundled
-- plugins such as rate-limiting): top-level `fields` and `config.fields`
-- are ARRAYS of single-key tables; the plugin VERSION lives in handler.lua,
-- not here.
local typedefs = require "kong.db.schema.typedefs"

return {
  name = "oss-post",
  fields = {
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          { resp_header_name = {
              type = "string",
              description = "response header name to add (default X-Oss-Post)",
            } },
          { resp_header_value = {
              type = "string",
              description = "response header value (default processed)",
            } },
          { transform_body = {
              type = "boolean",
              description = "enable response JSON body key renames",
            } },
          { key_rename = {
              type = "map",
              keys = { type = "string" },
              values = { type = "string" },
              description = "top-level response JSON key renames: from -> to",
            } },
          { echo_request_header = {
              type = "string",
              description = "request header to echo back as a response header (e.g. the generated correlation id)",
            } },
          { max_body_bytes = {
              type = "integer",
              default = 1048576,
              between = { 0, 10485760 },
              description = "refuse to transform bodies larger than this (default 1048576 = 1 MiB)",
            } },
        },
      },
    },
  },
}
