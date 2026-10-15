-- STEP 4 custom plugin "step4-post" — response post-processing
-- (ACCESS + body_filter phases).
return {
  name = "step4-post",
  fields = {
    config = {
      type = "record",
      required = true,
      fields = {
        resp_header_name = {
          type = "string",
          required = false,
          description = "response header name to add (default X-Step4-Post)",
        },
        resp_header_value = {
          type = "string",
          required = false,
          description = "response header value (default processed)",
        },
        transform_body = {
          type = "bool",
          required = false,
          description = "enable response JSON body key renames",
        },
        key_rename = {
          type = "map",
          required = false,
          map = { name = "string", value = "string" },
          description = "top-level response JSON key renames: from -> to",
        },
        echo_request_header = {
          type = "string",
          required = false,
          description = "request header to echo back as a response header "
                        "(e.g. the generated correlation id)",
        },
        max_body_bytes = {
          type = "integer",
          required = false,
          description = "refuse to transform bodies larger than this "
                        "(default 1048576 = 1 MiB)",
        },
      },
    },
  },
}
