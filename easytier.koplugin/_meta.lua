local _ = require("gettext")

return {
    fullname = _("EasyTier 异地组网"),
    description = _([[
在阅读器上控制独立运行的 EasyTier（easytier-core）节点：启停、配置、查看节点与路由。

需要自行提供 easytier-core / easytier-cli 可执行文件（官方 Linux armv7 静态包）。]]),
    version = "0.1.0",
    author = "koreader-easytier",
}
