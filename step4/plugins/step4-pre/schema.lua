-- STEP 4 custom plugin "step4-pre" — request pre-processing (ACCESS phase).
-- Capabilities (all OSS, no enterprise dependency):
--   * required_headers:    validate presence of request headers
--                          (JSON error response on failure)
--   * correlation_id_header: add a generated correlation id when missing
--   * body_rename:         rename top-level JSON body keys (request
--                          body transformation, e.g. customer_id -> customerId)
return {
  name = "step4-pre",
  fields = {
    config = {
      type = "record",
      required = true,
      fields = {
        required_headers = {
          type = "array",
          required = false,
          elements = "string",
          description = "request headers that must be present (presence check)",
        },
        correlation_id_header = {
          type = "string",
          required = false,
          description = "header receiving a generated correlation id when missing",
        },
        body_rename = {
          type = "map",
          required = false,
          map = { name = "string", value = "string" },
          description = "top-level JSON body key renames: from -> to",
        },
        max_body_bytes = {
          type = "integer",
          required = false,
          default = 1048576,
          between = { 0, 10485760 },
          description = "maximum declared request body size (bytes) that "
                        "will be read and transformed; 0 disables body "
                        "handling entirely (bodies always pass through "
                        "untransformed)",
        },
      },
    },
  },
}
