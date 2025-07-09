local utils = require("json_graph_view.utils")
local edges = require("json_graph_view.edges")

local M = {
    expanded = {},
    config = {
        ---@type boolean
        accept_all_files = true,

        ---@type integer
        max_lines = 5,

        ---@type boolean
        round_units = true,

        ---@type boolean
        round_connections = true,

        ---@type boolean
        disable_line_wrap = true,

        ---@type table
        keymaps = {
            ---@type string
            expand = "E",

            ---@type string
            link_forward = "L",

            ---@type string
            link_backward = "B",

            ---@type string
            set_as_root = "R",

            ---@type string
            quick_action = "<CR>",

            ---@type string
            close_window = "q"
        }
    },
    render_info = {},
    plugin_name = "JsonGraphView"
}

---@alias Vec2 { [1]: integer, [2]: integer }
---@alias Callback {[1]: string, [2]: function}
---@alias TextLine { [1]: string, [2]: string, [3]: string, [4]: Callback[]}

---Converts json object to its string representation
---@param val any
---@return string
M.GetValAsString = function(val)
    if val == vim.NIL then
        return "null"
    elseif val == vim.empty_dict() then
        return "{}"
    elseif type(val) == "string" then
        return '"' .. utils.escape_string(val) .. '"'
    elseif type(val) == "number" then
        return tostring(val)
    elseif type(val) == "boolean" then
        return tostring(val)
    elseif type(val) == "table" then
        if vim.islist(val) then
            return "[]"
        else
            return "{}"
        end
    end
end

---Gets the length of the string representation of
---a json value
---@param val any
---@return integer
M.GetLenOfValue = function(val)
    if val == vim.NIL then
        return 4
    elseif type(val) == "string" then
        return utils.utf8len(val) + 2
    elseif type(val) == "number" then
        return #tostring(val)
    elseif type(val) == "boolean" then
        if val then
            return 4
        else
            return 5
        end
    elseif type(val) == "table" then
        return 2
    end
end

---Builds the top or bottom of a graph unit
---@param top boolean
---@param max_len_left integer
---@param first boolean
---@param origin Vec2
---@param json_obj table
---@param key_set any[]
---@return TextLine
M.BuildBoxCap = function(top, max_len_left, first, origin, json_obj, key_set)
    local left
    local right
    local splitter
    local callbacks

    if top then
        if first then
            left = edges.edge.TOP_LEFT_ROOT
            callbacks = { {
                M.config.keymaps.link_backward,
                function(opts)
                    M.RenderGraph(opts.json_obj, opts.editor_buf, { opts.editor_buf })
                    M.CursorToRoot()
                end
            } }
        else
            left = edges.edge.TOP_LEFT
            callbacks = {
                {
                    M.config.keymaps.link_backward,
                    function(opts)
                        M.JumpToLink(origin[1], origin[2], opts.render_info, true)
                    end
                },
                {
                    M.config.keymaps.set_as_root,
                    function(opts)
                        M.RenderGraph(json_obj, opts.editor_buf, key_set)
                        M.CursorToRoot()
                    end
                }
            }
        end

        right = edges.edge.TOP_RIGHT
        splitter = edges.edge.TOP_SPLITTER
    else
        left = edges.edge.BOTTOM_LEFT
        right = edges.edge.BOTTOM_RIGHT
        splitter = edges.edge.BOTTOM_SPLITTER
    end

    return {
        left .. string.rep(edges.edge.TOP_AND_BOTTOM, max_len_left) .. splitter,
        edges.edge.TOP_AND_BOTTOM,
        right,
        callbacks
    }
end

---Determines if the unit specified by the key_set
---is expanded or not.
---@param key_set any[]
---@param dict table | nil
---@return boolean | nil
M.IsExpanded = function(key_set, dict)
    if dict == nil then
        dict = M.expanded
    end

    for idx, key in pairs(key_set) do
        if dict[key] == nil then
            return nil
        end

        dict = dict[key]

        if idx == #key_set then
            return dict[0]
        end
    end

    return false
end

---Register the unit specified by the key_set as expanded true
---or expanded false.
---@param key_set any[]
---@param val boolean
---@param dict table
M.SetExpanded = function(key_set, val, dict)
    if dict == nil then
        dict = M.expanded
    end

    for idx, key in pairs(key_set) do
        if dict[key] == nil then
            dict[key] = {}
        end

        dict = dict[key]

        if idx == #key_set then
            dict[0] = val
        end
    end
end

---Jumps the cursor to a graph location
---@param layer integer
---@param row integer
---@param render_info table
---@param jump_to_word boolean
M.JumpToLink = function(layer, row, render_info, jump_to_word)
    local col = render_info.col_idxs[layer]
    vim.api.nvim_win_set_cursor(0, { 2, col })

    if row ~= 1 then
        vim.cmd("normal! " .. (row - 1) .. "j")
    end

    if jump_to_word then
        vim.cmd("call search('\\S')")
    end
end

---Creates a text table representation of an object
---with callbacks and returns the top line number.
---OUTPUT WILL BE SENT TO OUT TABLE
---@param json_obj table
---@param out_table table
---@param layer_idx integer
---@param key_set any[]
---@param from_row integer | nil
---@return integer
M.TableObject = function(json_obj, out_table, layer_idx, key_set, from_row)
    if out_table[layer_idx] == nil then
        out_table[layer_idx] = { lines = 0, width = 0, boxes = {} }
    end

    local layer = out_table[layer_idx]

    local max_len_left = 0
    local max_len_right = 2
    local text_lines = {}
    local connections = {}

    for key, val in pairs(json_obj) do
        max_len_left = math.max(max_len_left, #tostring(key))
        max_len_right = math.max(max_len_right, M.GetLenOfValue(val))
    end

    layer.width = math.max(layer.width, max_len_left + max_len_right + 3)
    text_lines[#text_lines + 1] = M.BuildBoxCap(
        true,
        max_len_left,
        layer_idx == 1,
        { layer_idx - 1, from_row },
        json_obj,
        key_set
    )

    local line = 1
    for key, val in pairs(json_obj) do
        local left_edge = edges.edge.LEFT_AND_RIGHT
        if line == M.config.max_lines + 1 then
            left_edge = "╪"
        end

        if line > M.config.max_lines and (not M.IsExpanded(key_set)) then
            text_lines[#text_lines + 1] = {
                left_edge,
                ".",
                edges.edge.LEFT_AND_RIGHT,
                {
                    {
                        M.config.keymaps.expand,
                        function(opts)
                            M.SetExpanded(key_set, true)
                            M.RenderGraph(opts.render_info.shown_obj, opts.editor_buf, opts.render_info.shown_key_set)
                        end
                    }
                }
            }
            break
        else
            line = line + 1

            local collapse_callback
            if line > M.config.max_lines + 1 then
                collapse_callback = {
                    M.config.keymaps.expand,
                    function(opts)
                        M.SetExpanded(key_set, false)
                        M.RenderGraph(opts.render_info.shown_obj, opts.editor_buf, opts.render_info.shown_key_set)
                    end
                }
            end

            local string_key = tostring(key)
            local left = left_edge ..
                string.rep(" ", max_len_left - #string_key) .. string_key .. edges.edge.LEFT_AND_RIGHT
            local right = M.GetValAsString(val)

            if right == "{}" or right == "[]" then
                local from = layer.lines + #text_lines + 1
                local to = M.TableObject(val, out_table, layer_idx + 1, utils.appended_table(key_set, key), from)
                text_lines[#text_lines + 1] = {
                    left, "·", right .. edges.edge.CONNECTION,
                    {
                        {
                            M.config.keymaps.link_forward,
                            function(opts)
                                M.JumpToLink(layer_idx + 1, to, opts.render_info, false)
                            end
                        },
                        collapse_callback
                    }
                }

                connections[#connections + 1] = {
                    from = from,
                    to = to
                }
            else
                text_lines[#text_lines + 1] = { left, "·", right .. edges.edge.LEFT_AND_RIGHT, { collapse_callback } }
            end
        end
    end

    text_lines[#text_lines + 1] = M.BuildBoxCap(false, max_len_left)

    layer.boxes[#layer.boxes + 1] = { connections = connections, text_lines = text_lines, top_line = layer.lines + 1 }
    layer.lines = layer.lines + #text_lines
    return layer.boxes[#layer.boxes].top_line
end

---Apply highlighting to current buffer
M.ApplyHighlighting = function()
    vim.cmd([[highlight MyOperators guifg=#009900]])

    vim.cmd("syn region String start=+\"+ skip=+\\\\\\\\\\|\\\\\"+ end=+\"+ contains=@Spell")
    vim.cmd([[syn match Identifier /│\s*\zs\w\+\ze\s*│/ contains=@Spell]])
    vim.cmd([[syn match Identifier /╪\s*\zs\w\+\ze\s*│/ contains=@Spell]])
    vim.cmd("syn keyword Keyword null")
    vim.cmd("syn match MyOperators \"[{}\\[\\]]\"")
    vim.cmd("syn match MyOperators \"\\.\"")
    vim.cmd([[syn match Comment "·"]])
    vim.cmd("syn keyword Boolean true false")
    vim.cmd("syn match Number \"[-+]\\=\\%(0\\|[1-9]\\d*\\)\\%(\\.\\d*\\)\\=\\%([eE][-+]\\=\\d\\+\\)\\=\"")
    vim.cmd("syn match Number \"[-+]\\=\\%(\\.\\d\\+\\)\\%([eE][-+]\\=\\d\\+\\)\\=\"")
    vim.cmd("syn match Number \"[-+]\\=0[xX]\\x*\"")
    vim.cmd("syn match Number \"[-+]\\=Infinity\\|NaN\"")
end

---Build connections for the given layer
---@param connections {from: integer, to:integer}[]
---@param grid_height integer
---@return TextLine[]
M.BuildConnectionsForLayer = function(connections, grid_height)
    local grid = {}
    local grid_cols = 0

    local function add_col_to_grid()
        grid_cols = grid_cols + 1
        for i = 1, grid_height do
            if grid[i] == nil then
                grid[i] = {}
            end

            grid[i][grid_cols] = " "
        end
    end

    local up_cons = {}
    local down_cons = {}
    local flat_cons = {}
    for _, con in pairs(connections) do
        if con.from < con.to then
            down_cons[#down_cons + 1] = con
        elseif con.from > con.to then
            up_cons[#up_cons + 1] = con
        else
            flat_cons[#flat_cons + 1] = con
        end
    end

    for _ = 1, math.max(#up_cons, #down_cons) + 2 do
        add_col_to_grid()
    end

    for _, con in pairs(flat_cons) do
        local col = 1
        while col <= grid_cols do
            grid[con.from][col] = edges.line.SIDE
            col = col + 1
        end
    end

    for i = #down_cons, 1, -1 do
        local con = down_cons[i]
        local row = con.from
        local col = 1
        local target = con.to

        local last_was_right = true
        while row ~= target or col ~= grid_cols + 1 do
            local new_is_right
            local new_row
            local new_col

            if row < target
                and grid[row + 1][col] == " "
            then
                new_row = row + 1
                new_col = col
                new_is_right = false
            else
                new_col = col + 1
                new_row = row
                new_is_right = true
            end

            local char
            if last_was_right and new_is_right then
                if grid[row][col] == edges.line.UP_DOWN then
                    char = edges.line.CROSS
                else
                    char = edges.line.SIDE
                end
            elseif last_was_right and (not new_is_right) then
                char = edges.line.TURN_DOWN
            elseif (not last_was_right) and new_is_right then
                char = edges.line.TURN_SIDE_FD
            else
                if grid[row][col] == edges.line.SIDE then
                    char = edges.line.CROSS
                else
                    char = edges.line.UP_DOWN
                end
            end

            grid[row][col] = char
            last_was_right = new_is_right
            row = new_row
            col = new_col
        end
    end

    for i = 1, #up_cons do
        local con = up_cons[i]
        local row = con.from
        local col = 1
        local target = con.to

        local last_was_right = true
        while row ~= target or col ~= grid_cols + 1 do
            local new_is_right
            local new_row
            local new_col


            if row > target
                and grid[row - 1][col] == " "
            then
                new_row = row - 1
                new_col = col
                new_is_right = false
            else
                new_col = col + 1
                new_row = row
                new_is_right = true
            end

            local char
            if last_was_right and new_is_right then
                if grid[row][col] == edges.line.UP_DOWN then
                    char = edges.line.CROSS
                else
                    char = edges.line.SIDE
                end
            elseif last_was_right and (not new_is_right) then
                char = edges.line.TURN_UP
            elseif (not last_was_right) and new_is_right then
                char = edges.line.TURN_SIDE_FU
            else
                if grid[row][col] == edges.line.SIDE then
                    char = edges.line.CROSS
                else
                    char = edges.line.UP_DOWN
                end
            end


            grid[row][col] = char
            last_was_right = new_is_right
            row = new_row
            col = new_col
        end
    end

    return grid
end

---Builds the connections for a text graph
---@param output_table table
---@return table
M.BuildConnections = function(output_table)
    local connections = {}

    local layer_grid_height = 0
    for _, layer in pairs(output_table) do
        layer_grid_height = math.max(layer_grid_height, layer.lines)
    end

    for layer_id, layer in pairs(output_table) do
        local layer_connections = {}
        for _, box in pairs(layer.boxes) do
            for _, connection in pairs(box.connections) do
                layer_connections[#layer_connections + 1] = connection
            end
        end

        connections[layer_id] = M.BuildConnectionsForLayer(layer_connections, layer_grid_height)
    end

    return connections
end

---Renders the json_obj to the editor buf
---@param json_obj table
---@param editor_buf integer
---@param key_set any[]
M.RenderGraph = function(json_obj, editor_buf, key_set)
    local text_output_table = {}
    local render_info = { line_callbacks = {}, shown_obj = json_obj, shown_key_set = key_set }
    M.TableObject(json_obj, text_output_table, 1, key_set, nil)
    local connections = M.BuildConnections(text_output_table)

    local output_lines = {}
    local line = 1
    local any = true

    while any do
        local lines = {}
        any = false
        for col_idx, col in pairs(text_output_table) do
            local text_line
            if line > col.lines then
                text_line = { string.rep(" ", col.width), {} }
            else
                any = true
                local b_line = line
                for _, box in pairs(col.boxes) do
                    if b_line - #box.text_lines <= 0 then
                        text_line = box.text_lines[b_line]

                        local left, fill, right = text_line[1], text_line[2], text_line[3]

                        local conjoined = left .. right
                        local utf8len_ = utils.utf8len(conjoined)

                        if text_line[4] then
                            local len = string.len(conjoined)
                            text_line[4].limit = len + (col.width - utf8len_) * string.len(fill)
                        end

                        text_line = {
                            left
                            .. string.rep(fill, col.width - utf8len_)
                            .. right, text_line[4]
                        }

                        break
                    end

                    b_line = b_line - #box.text_lines
                end
            end

            local col_connections = connections[col_idx]
            if col_connections ~= nil then
                local section_connection = col_connections[line]
                if section_connection ~= nil then
                    text_line[1] = text_line[1] .. table.concat(section_connection)
                    any = true
                end
            end

            lines[#lines + 1] = text_line
        end

        local set_render_info = render_info.col_idxs == nil

        if set_render_info then
            render_info.col_idxs = {}
        end

        local current_line_callbacks = {}
        local text_line = ""
        for _, section in pairs(lines) do
            local start = string.len(text_line)
            if current_line_callbacks[start] == nil then
                current_line_callbacks[start] = {}
            end

            if section[2] then
                local limit = section[2].limit
                for key, callback in pairs(section[2]) do
                    if key ~= "limit" then
                        callback.limit = limit
                        current_line_callbacks[start][#current_line_callbacks[start] + 1] = callback
                    end
                end
            end

            if set_render_info then
                render_info.col_idxs[#render_info.col_idxs + 1] = start
            end

            text_line = text_line .. section[1]
        end

        output_lines[line] = text_line
        render_info.line_callbacks[line] = current_line_callbacks
        line = line + 1
    end

    vim.api.nvim_buf_set_option(editor_buf, 'modifiable', true)
    vim.api.nvim_buf_set_lines(editor_buf, 1, -1, false, output_lines)
    M.ApplyHighlighting()

    vim.api.nvim_buf_set_option(editor_buf, 'modifiable', false)

    M.render_info[editor_buf] = render_info
end

---Creates a window split. Returns the buffer for the window
---and a callback to update the status line.
---@return integer
---@return function
M.SplitView = function()
    local win = vim.api.nvim_get_current_win()
    local total_width = vim.api.nvim_win_get_width(win)

    -- Save and override splitright
    local original_splitright = vim.opt.splitright
    vim.opt.splitright = true
    vim.cmd('vsplit')
    vim.opt.splitright = original_splitright

    local new_win = vim.api.nvim_get_current_win()
    local target_width = total_width - 20
    vim.api.nvim_win_set_width(new_win, target_width)

    local editor_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(new_win, editor_buf)
    vim.api.nvim_win_set_option(new_win, 'number', false)
    vim.api.nvim_win_set_option(new_win, 'relativenumber', false)
    vim.api.nvim_buf_set_option(editor_buf, "filetype", M.plugin_name)

    if M.config.disable_line_wrap then
        vim.api.nvim_buf_set_option(editor_buf, "wrap", false)
    end

    -- Define highlight group for the statusline
    vim.api.nvim_set_hl(0, "JsonViewStatusline", { bg = "#1e1e2e", fg = "#ffffff", bold = true })

    -- Floating statusline setup
    local status_buf = vim.api.nvim_create_buf(false, true)
    local function update_statusline(text)
        vim.api.nvim_buf_set_lines(status_buf, 0, -1, false, { text })
    end
    update_statusline("[JSON VIEW]")

    local status_win = vim.api.nvim_open_win(status_buf, false, {
        relative = "win",
        win = new_win,
        row = 0,
        col = 0,
        width = target_width,
        height = 1,
        anchor = "NW",
        style = "minimal",
        focusable = false,
        noautocmd = true,
        zindex = 50,
    })
    vim.api.nvim_win_set_option(status_win, "winhl", "Normal:JsonViewStatusline")

    -- Cleanup autocommands
    local augroup = vim.api.nvim_create_augroup("JsonViewStatus", { clear = false })

    vim.api.nvim_create_autocmd({ "WinClosed" }, {
        group = augroup,
        callback = function(args)
            local closed_win = tonumber(args.match)
            if closed_win == new_win and vim.api.nvim_win_is_valid(status_win) then
                vim.api.nvim_win_close(status_win, true)
            end
        end
    })

    vim.api.nvim_create_autocmd({ "BufWipeout", "BufHidden" }, {
        group = augroup,
        buffer = editor_buf,
        callback = function()
            if vim.api.nvim_win_is_valid(status_win) then
                vim.api.nvim_win_close(status_win, true)
            end
        end
    })

    vim.keymap.set(
        "n",
        M.config.keymaps.close_window,
        "<CMD>q<CR>",
        { buffer = true, noremap = true, silent = true }
    )


    return editor_buf, update_statusline
end

---Cursor moved autocommand
---@param editor_buf integer
---@param json_obj table
---@param file string
---@param file_buf integer
---@param update_statusline function
M.CursorMoved = function(editor_buf, json_obj, file, file_buf, update_statusline)
    local pos = vim.api.nvim_win_get_cursor(0)
    if pos[1] == 1 then
        vim.api.nvim_win_set_cursor(0, { 2, pos[2] })
        pos[1] = 2
    end

    for _, k in pairs(M.config.keymaps) do
        if k ~= M.config.keymaps.close_window then
            vim.keymap.set("n", k, function()
                vim.notify(k .. " is not valid at this location", "WARN")
            end, { buffer = true })
        end
    end

    local callback_keys = {}
    for start, callback_set in pairs(M.render_info[editor_buf].line_callbacks[pos[1] - 1]) do
        if pos[2] >= start then
            for _, callback in pairs(callback_set) do
                if pos[2] < start + callback.limit then
                    local fn = function()
                        callback[2]({
                            editor_buf = editor_buf,
                            json_obj = json_obj,
                            file = file,
                            file_buf = file_buf,
                            render_info = M.render_info[editor_buf],
                        })
                    end

                    callback_keys[callback[1]] = fn
                    vim.keymap.set("n", callback[1], fn, { buffer = true })
                end
            end
        end
    end

    local statusline_text = M.plugin_name .. " (" .. M.config.keymaps.close_window .. "=Close Window)"

    local enter_map
    for _, k in pairs({
        M.config.keymaps.expand,
        M.config.keymaps.link_backward,
        M.config.keymaps.link_forward,
        M.config.keymaps.set_as_root,
    }) do
        for k2, callback in pairs(callback_keys) do
            if k == k2 then
                enter_map = { k2, callback }
                goto after
            end
        end
    end
    ::after::

    if enter_map then
        vim.keymap.set("n", M.config.keymaps.quick_action, enter_map[2], { buffer = true })
        statusline_text = statusline_text .. " (" .. M.config.keymaps.quick_action .. "=" .. enter_map[1] .. ")"
    else
        vim.keymap.set("n", M.config.keymaps.quick_action, function()
            vim.notify(M.config.keymaps.quick_action .. " is not valid at this location", "WARN")
        end, { buffer = true })
    end

    for k, _ in pairs(callback_keys) do
        local help = ({
            [M.config.keymaps.expand] = "Expand/Collapse Section",
            [M.config.keymaps.link_forward] = "Jump to Linked Unit",
            [M.config.keymaps.link_backward] = "Jump to Parent Unit",
            [M.config.keymaps.set_as_root] = "Set Unit as Graph Root",
        })[k]

        statusline_text = statusline_text .. " (" .. k .. "=" .. help .. ")"
    end

    update_statusline(statusline_text)
end

---Moves the cursor to the first unit
M.CursorToRoot = function()
    vim.api.nvim_win_set_cursor(0, { 3, 3 })
end

---Shows the JsonGraphView window
---@param file_buf integer
---@param json_obj table
---@param file string
M.ShowJsonWindow = function(file_buf, json_obj, file)
    local editor_buf, update_statusline = M.SplitView();
    vim.api.nvim_win_set_buf(0, editor_buf)
    M.RenderGraph(json_obj, editor_buf, { editor_buf })
    M.CursorToRoot()

    vim.api.nvim_create_autocmd({ "CursorMoved" }, {
        buffer = editor_buf,
        callback = function() M.CursorMoved(editor_buf, json_obj, file, file_buf, update_statusline) end,
    })


    vim.notify(M.plugin_name .. " View Opened")
end

---Opens the JsonGraphView on the specified buffer
---@param bufn integer
M.OpenJsonViewOnBuf = function(bufn)
    local lines = vim.api.nvim_buf_get_lines(bufn, 0, -1, false)
    local json_text = table.concat(lines, "")

    local json_obj;
    local valid = pcall(function()
        json_obj = vim.json.decode(json_text)
    end)

    if valid then
        M.ShowJsonWindow(bufn, json_obj, vim.api.nvim_buf_get_name(0))
    else
        vim.notify("Json text is not valid", "ERROR")
    end
end

---Opens the JsonGraphView on the current buffer
M.OpenJsonView = function()
    if vim.bo.filetype == "json" or M.config.accept_all_files then
        local bufn = vim.api.nvim_buf_get_number(0)
        M.OpenJsonViewOnBuf(bufn)
    else
        vim.notify("Buffer does not have filetype json; could not open" .. M.plugin_name .. ".")
    end
end

vim.api.nvim_create_user_command(M.plugin_name, M.OpenJsonView, {})

---Set up the plugin
---@param opts table
M.setup = function(opts)
    utils.update_table(opts, M.config)

    if M.config.round_connections then
        edges.line = edges.ROUND_LINE
    else
        edges.line = edges.HARD_LINE
    end

    if M.config.round_units then
        edges.edge = edges.ROUND_EDGE
    else
        edges.edge = edges.HARD_EDGE
    end
end

return M
