--[[--
EasyTier 组网插件 —— 界面小工具

把 InfoMessage / ConfirmBox / InputDialog / TextViewer 包一层，让 main.lua 读起来干净些。

这里的原则：**任何一次绘制失败都不许把 KOReader 拖崩**。
所以长文本页面全部走 pcall：内容生成失败、控件创建失败、显示失败，都会退化成
一个 InfoMessage（并把错误写进 logger，也就是 crash.log）。
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")
local TextViewer = require("ui/widget/textviewer")
local logger = require("logger")
local _ = require("gettext")

local Config = require("et_config")

local UI = {}

function UI.info(text, timeout)
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = timeout or 4,
    })
end

function UI.busy(text)
    local msg = InfoMessage:new{ text = text or _("处理中…") }
    UIManager:show(msg)
    UIManager:forceRePaint()
    return msg
end

--- 需要用户确认的操作
function UI.confirm(text, on_ok, ok_text)
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = ok_text or _("确定"),
        cancel_text = _("取消"),
        ok_callback = on_ok,
    })
end

--- 多个选项（比 ConfirmBox 更适合「TUN 还是代理」这类选择）
function UI.choose(title, options)
    local dialog
    local buttons = {}
    for _, opt in ipairs(options) do
        buttons[#buttons + 1] = { {
            text = opt.text,
            callback = function()
                UIManager:close(dialog)
                opt.callback()
            end,
        } }
    end
    buttons[#buttons + 1] = { {
        text = _("取消"),
        callback = function() UIManager:close(dialog) end,
    } }
    dialog = ButtonDialog:new{
        title = title,
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

--- 单行输入框。opts: title/value/hint/description/number/on_save(value)
function UI.input_text(opts)
    local dialog
    local input_value = opts.value
    if type(input_value) ~= "string" then input_value = tostring(input_value or "") end

    dialog = InputDialog:new{
        title = opts.title,
        input = input_value,
        input_hint = opts.hint,
        input_type = opts.number and "number" or nil,
        description = opts.description,
        allow_newline = false,
        buttons = {
            {
                {
                    text = _("取消"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("保存"),
                    is_enter_default = true,
                    callback = function()
                        local text = dialog:getInputText() or ""
                        UIManager:close(dialog)
                        opts.on_save(text)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- 只读长文本页（状态 / 日志 / 诊断这类）。
--- opts: title, text 或 build=function() -> string, monospace=false 可用非等宽字体
function UI.show_text(opts)
    local title = opts.title or _("信息")
    logger.info(string.format("EasyTier: 打开页面「%s」", tostring(title)))

    -- 1) 生成内容：出错也只是弹提示
    local ok, text = pcall(opts.build or function() return opts.text end)
    if not ok then
        logger.err("EasyTier: 生成页面内容失败（" .. tostring(title) .. "）：" .. tostring(text))
        UI.info(_("生成页面内容时出错：\n") .. tostring(text)
            .. _("\n\n（详情已写入 KOReader 的 crash.log）"), 20)
        return
    end

    -- 2) 控制体积：超长行截断、超大文本截断
    local clipped = Config.clip_text(text)
    logger.info(string.format("EasyTier: 页面「%s」内容就绪，%d 字节", tostring(title), #clipped))

    -- 3) 创建控件：只在 pcall 里创建，失败就退化成纯文本提示
    local viewer_ok, viewer = pcall(TextViewer.new, TextViewer, {
        title = title,
        text = clipped,
        text_type = opts.monospace == false and "general" or "code",
        add_default_buttons = true,
    })
    if not viewer_ok or not viewer then
        logger.err("EasyTier: 页面控件创建失败（" .. tostring(title) .. "）：" .. tostring(viewer))
        UI.info(_("打不开页面控件，先按纯文本显示：\n\n") .. tostring(viewer) .. "\n\n"
            .. clipped:sub(1, 900), 30)
        return
    end

    -- 4) 显示：同样保护一层
    local show_ok, err = pcall(UIManager.show, UIManager, viewer)
    if not show_ok then
        logger.err("EasyTier: 页面显示失败（" .. tostring(title) .. "）：" .. tostring(err))
        UI.info(_("页面显示失败：\n") .. tostring(err) .. "\n\n" .. clipped:sub(1, 900), 30)
    end
end

return UI
