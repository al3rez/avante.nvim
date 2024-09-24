local api = vim.api
local curl = require("plenary.curl")
local Utils = require("avante.utils")
local Config = require("avante.config")
local Path = require("avante.path")
local P = require("avante.providers")

---@class avante.LLM
local M = {}

M.CANCEL_PATTERN = "AvanteLLMEscape"

------------------------------Prompt and type------------------------------

local group = api.nvim_create_augroup("avante_llm", { clear = true })

---@alias LlmMode "planning" | "editing" | "suggesting"
---
---@class TemplateOptions
---@field use_xml_format boolean
---@field ask boolean
---@field question string
---@field code_lang string
---@field file_content string
---@field selected_code string | nil
---@field project_context string | nil
---@field memory_context string | nil
---
---@class StreamOptions: TemplateOptions
---@field ask boolean
---@field bufnr integer
---@field instructions string
---@field mode LlmMode
---@field provider AvanteProviderFunctor | nil
---@field on_chunk AvanteChunkParser
---@field on_complete AvanteCompleteParser

---@param opts StreamOptions
M.stream = function(opts)
    local mode = opts.mode or "planning"
    ---@type AvanteProviderFunctor
    local Provider = opts.provider or P[Config.provider]

    -- Optimize image path extraction
    local image_paths = {}
    local instructions = opts.instructions:gsub("image: ([^\n]+)", function(path)
        table.insert(image_paths, path)
        return ""
    end)

    Path.prompts.initialize(Path.prompts.get(opts.bufnr))

    local filepath = Utils.relative_path(api.nvim_buf_get_name(opts.bufnr))

    local template_opts = {
        use_xml_format = Provider.use_xml_format,
        ask = opts.ask,
        question = instructions,
        code_lang = opts.code_lang,
        filepath = filepath,
        file_content = opts.file_content,
        selected_code = opts.selected_code,
        project_context = opts.project_context,
        memory_context = opts.memory_context,
    }

    -- Pre-compute user prompts
    local user_prompts = {
        Path.prompts.render_file("_project.avanterules", template_opts),
        Path.prompts.render_file("_memory.avanterules", template_opts),
        Path.prompts.render_file("_context.avanterules", template_opts),
        Path.prompts.render_mode(mode, template_opts),
    }
    user_prompts = vim.tbl_filter(function(k) return k ~= "" end, user_prompts)

    Utils.debug(user_prompts)

    ---@type AvantePromptOptions
    local code_opts = {
        system_prompt = Config.system_prompt,
        user_prompts = user_prompts,
        image_paths = image_paths,
    }

    ---@type string
    local current_event_state = nil

    ---@type AvanteHandlerOptions
    local handler_opts = { on_chunk = opts.on_chunk, on_complete = opts.on_complete }
    ---@type AvanteCurlOutput
    local spec = Provider.parse_curl_args(Provider, code_opts)

    Utils.debug(spec)

    ---@param line string
    local function parse_stream_data(line)
        local event = line:match("^event: (.+)$")
        if event then
            current_event_state = event
            return
        end
        local data_match = line:match("^data: (.+)$")
        if data_match then Provider.parse_response(data_match, current_event_state, handler_opts) end
    end

    local completed = false

    local active_job

    -- Use LuaJIT FFI for faster JSON encoding
    local ffi = require("ffi")
    local cjson = ffi.load("cjson")
    ffi.cdef[[
        char *cJSON_Print(const char *item);
        void free(void *ptr);
    ]]

    local json_str = ffi.string(cjson.cJSON_Print(ffi.new("const char*", vim.json.encode(spec.body))))
    ffi.C.free(ffi.cast("void*", json_str))

    active_job = curl.post(spec.url, {
        headers = spec.headers,
        proxy = spec.proxy,
        insecure = spec.insecure,
        body = json_str,
        stream = function(err, data, _)
            if err then
                completed = true
                opts.on_complete(err)
                return
            end
            if not data then return end
            if Config.options[Config.provider] == nil and Provider.parse_stream_data ~= nil then
                Provider.parse_stream_data(data, handler_opts)
            else
                if Provider.parse_stream_data ~= nil then
                    Provider.parse_stream_data(data, handler_opts)
                else
                    parse_stream_data(data)
                end
            end
        end,
        on_error = function()
            active_job = nil
            completed = true
            opts.on_complete(nil)
        end,
        callback = function(result)
            active_job = nil
            if result.status >= 400 then
                if Provider.on_error then
                    Provider.on_error(result)
                else
                    Utils.error("API request failed with status " .. result.status, { once = true, title = "Avante" })
                end
                if not completed then
                    completed = true
                    opts.on_complete(
                        "API request failed with status " .. result.status .. ". Body: " .. vim.inspect(result.body)
                    )
                end
            end
        end,
    })

    api.nvim_create_autocmd("User", {
        group = group,
        pattern = M.CANCEL_PATTERN,
        once = true,
        callback = function()
            if active_job then
                pcall(function() active_job:shutdown() end)
                Utils.debug("LLM request cancelled", { title = "Avante" })
                active_job = nil
            end
        end,
    })

    return active_job
end

function M.cancel_inflight_request() api.nvim_exec_autocmds("User", { pattern = M.CANCEL_PATTERN }) end

return M
