return {
  "folke/snacks.nvim",
  priority = 1000,
  lazy = false,
  opts = {
    image = {
      enabled = true,
      convert = {
        magick = {
          -- upstream omits `-background none`: transparent svgs render on white
          vector = { "-background", "none", "-density", 192, "{src}[{page}]" },
        },
      },
    },
  },
  config = function(_, opts)
    require("snacks").setup(opts)

    -- patched copies of upstream placement fns (stuck "loading …" spinner, stale
    -- hidden state, E37 on :q); see snacks.nvim#2634/#2793 — drop when fixed
    local Placement = require("snacks.image.placement")
    local img_ns = vim.api.nvim_create_namespace("snacks.image")
    function Placement:progress()
      if self.opts.inline or self:ready() then
        return
      end
      local timer = assert(vim.uv.new_timer())
      local eid ---@type number?
      timer:start(
        0,
        80,
        vim.schedule_wrap(function()
          if
            self.closed
            or self:ready()
            or self.img:failed()
            or not vim.api.nvim_buf_is_valid(self.buf)
          then
            timer:stop()
            if not timer:is_closing() then
              timer:close()
            end
            if vim.api.nvim_buf_is_valid(self.buf) then
              if eid then
                pcall(vim.api.nvim_buf_del_extmark, self.buf, img_ns, eid)
              end
              if self.closed then
                vim.api.nvim_buf_clear_namespace(self.buf, img_ns, 0, -1)
              end
            end
            return
          end
          vim.api.nvim_buf_clear_namespace(self.buf, img_ns, 0, -1)
          eid = vim.api.nvim_buf_set_extmark(self.buf, img_ns, 0, 0, {
            id = eid,
            virt_text = {
              { Snacks.util.spinner(), "SnacksImageSpinner" },
              { " " },
              { self.img._convert:current().name .. " loading …", "SnacksImageLoading" },
            },
          })
        end)
      )
    end
    local placement_update = Placement.update
    function Placement:update()
      if self.hidden and #self:wins() > 0 then
        self.hidden = false
      end
      return placement_update(self)
    end

    -- toggle rendering the current file as an image in place (<leader>i / q)
    local image_view ---@type {win: number, buf: number, prev: number, placement: snacks.image.Placement}?
    local function image_render_toggle(path)
      if image_view then
        local v = image_view
        image_view = nil
        v.placement:close()
        if vim.api.nvim_win_is_valid(v.win) and vim.api.nvim_win_get_buf(v.win) == v.buf then
          vim.api.nvim_win_set_buf(v.win, v.prev)
        end
        if vim.api.nvim_buf_is_valid(v.buf) then
          vim.api.nvim_buf_delete(v.buf, { force = true })
        end
        return
      end
      local file = path and path ~= "" and vim.fn.fnamemodify(path, ":p")
        or vim.api.nvim_buf_get_name(0)
      if file == "" or not vim.uv.fs_stat(file) then
        return vim.notify("ImageRender: no file to render", vim.log.levels.WARN)
      end
      local win = vim.api.nvim_get_current_win()
      local prev = vim.api.nvim_win_get_buf(win)
      local buf = vim.api.nvim_create_buf(false, true)
      Snacks.util.bo(buf, { filetype = "image", modifiable = false, swapfile = false })
      vim.api.nvim_win_set_buf(win, buf)
      local placement =
        Snacks.image.placement.new(buf, file, { conceal = true, auto_resize = true })
      image_view = { win = win, buf = buf, prev = prev, placement = placement }
      vim.keymap.set("n", "q", image_render_toggle, { buffer = buf, desc = "Close image render" })
    end
    vim.api.nvim_create_user_command("ImageRender", function(cmd)
      image_render_toggle(cmd.args)
    end, { nargs = "?", complete = "file" })
    vim.keymap.set("n", "<leader>i", image_render_toggle, { desc = "Toggle image render" })
  end,
}
