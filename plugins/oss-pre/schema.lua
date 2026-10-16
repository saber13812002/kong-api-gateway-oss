-- Custom plugin "oss-pre" — request pre-processing (ACCESS phase).
-- Capabilities (all OSS, no enterprise dependency):
--   * required_headers:    validate presence of request headers
--                          (JSON error response on failure)
--   * correlation_id_header: add a generated correlation id when missing
--   * body_rename:         rename top-level JSON body keys (request
--                          body transformation, e.g. customer_id -> customerId)
--
-- NOTE: schema shape follows the Kong 3.9.4 plugin contract (see bundled
-- plugins such as rate-limiting): top-level `fields` and `config.fields`
-- are ARRAYS of single-key tables; the plugin VERSION lives in handler.lua,
-- not here.
local typedefs = require "kong.db.schema.typedefs"

return {
  name = "oss-pre",
  fields = {
    { protocols = typedefs.protocols_http },
    { config = {
        type = "record",
        fields = {
          { required_headers = {
              type = "array",
              elements = { type = "string" },
              description = "request headers that must be present (presence check)",
            } },
          { correlation_id_header = {
              type = "string",
              description = "header receiving a generated correlation id when missing",
            } },
          { body_rename = {
              type = "map",
              keys = { type = "string" },
              values = { type = "string" },
              description = "top-level JSON body key renames: from -> to",
            } },
          { max_body_bytes = {
              type = "integer",
              default = 1048576,
              between = { 0, 10485760 },
              description = "maximum declared request body size (bytes) that will be read and transformed; 0 disables body handling entirely (bodies always pass through untransformed)",
            } },
        },
      },
    },
  },
}
