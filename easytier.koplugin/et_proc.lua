--[[--
EasyTier 组网插件 —— 进程与设备控制

只做三件事：找到 easytier-core / easytier-cli、把 easytier-core 拉起来或杀掉、
通过 easytier-cli 读状态。所有 shell 命令都经过 shquote 转义。
--]]

local DataStorage = require("datastorage")
-- ffi/util 里是进程内 nanosleep（Kindle 的 busybox sleep 不吃小数）。
-- 拿不到也不能让整个插件加载失败，所以用 pcall 兜一层。
local ok_ffiutil, ffiutil = pcall(require, "ffi/util")
if not ok_ffiutil or type(ffiutil) ~= "table" then ffiutil = nil end
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

local Config = require("et_config")

local Proc = {}

Proc.PID_FILE = "/tmp/easytier_koreader.pid"
Proc.MAX_LOG_BYTES = 256 * 1024

local cached_paths = {}

--==========================================================================
-- 等待与超时
--==========================================================================

--- 等待若干秒。
--- 注意：Kindle 的 busybox `sleep` 只认整数（`sleep 0.2` 会报 invalid number，
--- 等于完全不等待），所以优先用 KOReader 自带的 ffiutil.sleep（进程内 nanosleep）。
function Proc.sleep(seconds)
    seconds = tonumber(seconds) or 0
    if seconds <= 0 then return end
    local sleeper = type(ffiutil) == "table" and ffiutil.sleep or nil
    if type(sleeper) == "function" then
        sleeper(seconds)
        return
    end
    local n = math.floor(seconds)
    if n >= 1 then
        os.execute(string.format("sleep %d", n))
    end
    -- 不足 1 秒又拿不到 ffiutil.sleep 时就不等了：宁可快，也不要刷一屏报错
end

local function shell_ok(cmd)
    local r = os.execute(cmd)
    return r == 0 or r == true
end

--- 给命令套一层超时，避免某个外部命令卡住把界面线程冻住。
--- busybox 是 `timeout -t SECS CMD`，coreutils 是 `timeout SECS CMD`，都不支持就退化为不加。
local timeout_style = nil
function Proc.timeout_prefix(seconds)
    if not Proc.has("timeout") then return "" end
    if timeout_style == nil then
        if shell_ok("timeout -t 1 true >/dev/null 2>&1") then
            timeout_style = "busybox"
        elseif shell_ok("timeout 1 true >/dev/null 2>&1") then
            timeout_style = "coreutils"
        else
            timeout_style = "none"
        end
    end
    local n = math.max(1, math.floor(tonumber(seconds) or 8))
    if timeout_style == "busybox" then
        return string.format("timeout -t %d ", n)
    elseif timeout_style == "coreutils" then
        return string.format("timeout %d ", n)
    end
    return ""
end

--==========================================================================
-- 通用工具
--==========================================================================

--- 跑一条 shell 命令。给了 seconds 就套一层系统 timeout：
--- 外部命令卡住时界面线程不能被它拖住（诊断这类"串一堆命令"的地方必须带超时）。
function Proc.exec(cmd, seconds)
    logger.dbg("EasyTier exec:", cmd)
    if seconds then
        local prefix = Proc.timeout_prefix(seconds)
        if prefix ~= "" then cmd = prefix .. cmd end
    end
    local h = io.popen(cmd .. " 2>&1")
    if not h then return false, "" end
    local out = h:read("*a") or ""
    local ok = h:close()
    return ok and true or false, out
end

--- 参数名/开关本身不需要引号，配置里的值一律单引号包起来
local function quote_arg(a)
    a = tostring(a)
    if a:match("^%-%-?[%w][%w%-]*$") then return a end
    return Config.shquote(a)
end

--- 运行一个可执行文件（参数自动转义）。
--- 给了 timeout_seconds 就套一层系统 timeout：外部命令卡住时不能让界面线程跟着冻住。
function Proc.run(bin, argv, timeout_seconds)
    local parts = {}
    if timeout_seconds then
        local prefix = Proc.timeout_prefix(timeout_seconds)
        if prefix ~= "" then parts[#parts + 1] = prefix end
    end
    parts[#parts + 1] = Config.shquote(bin)
    for _i, a in ipairs(argv or {}) do
        parts[#parts + 1] = quote_arg(a)
    end
    return Proc.exec(table.concat(parts, " "))
end

--- 某条命令是否存在（结果会缓存）
function Proc.has(cmd)
    if cached_paths[cmd] ~= nil then return cached_paths[cmd] end
    local res, out = Proc.exec("command -v " .. cmd)
    local found = out ~= nil and out:gsub("%s", "") ~= ""
    cached_paths[cmd] = found
    return found
end

--- 清掉命令/超时探测的缓存（测试用）
function Proc.reset_caches()
    cached_paths = {}
    timeout_style = nil
end

function Proc.data_dir()
    local dir = DataStorage:getFullDataDir() .. "/easytier"
    if not util.pathExists(dir) then
        os.execute("mkdir -p " .. Config.shquote(dir))
    end
    return dir
end

function Proc.log_path()
    return Proc.data_dir() .. "/easytier.log"
end

function Proc.log_file_size()
    local attr = lfs.attributes(Proc.log_path())
    return attr and attr.size or 0
end

function Proc.clear_log()
    local f = io.open(Proc.log_path(), "w")
    if f then
        f:write("")
        f:close()
    end
end

--==========================================================================
-- 可执行文件定位
--==========================================================================

--- 搜索目录顺序：用户指定目录 → 各默认目录 → 各目录的一级子目录（官方 zip 解压后是 easytier-linux-armv7/ 结构）
function Proc.search_dirs(cfg)
    local dirs = {}
    if cfg and cfg.custom_bin_dir and cfg.custom_bin_dir ~= "" then
        table.insert(dirs, cfg.custom_bin_dir)
    end
    for _i, d in ipairs(Config.BIN_SEARCH_DIRS) do
        table.insert(dirs, d)
    end
    return dirs
end

local function is_dir(path)
    local attr = lfs.attributes(path)
    return attr ~= nil and attr.mode == "directory"
end

function Proc.find(name, cfg)
    local dirs = Proc.search_dirs(cfg)
    for _i, d in ipairs(dirs) do
        local p = d .. "/" .. name
        if util.pathExists(p) then return p end
    end
    for _i, d in ipairs(dirs) do
        if is_dir(d) then
            for entry in lfs.dir(d) do
                if entry ~= "." and entry ~= ".." then
                    local sub = d .. "/" .. entry
                    if is_dir(sub) then
                        local p = sub .. "/" .. name
                        if util.pathExists(p) then return p end
                    end
                end
            end
        end
    end
    -- 最后再退到 PATH
    if Proc.has(name) then
        local res, out = Proc.exec("command -v " .. name)
        if out and out:gsub("%s", "") ~= "" then
            return out:match("^(%S+)")
        end
    end
    return nil
end

--- 给「安装说明 / 诊断」用的搜索报告
function Proc.search_report(cfg)
    local lines = {}
    for _i, d in ipairs(Proc.search_dirs(cfg)) do
        lines[#lines + 1] = string.format("  %s %s", util.pathExists(d .. "/" .. Config.CORE_NAME) and "✓" or "✗", d)
    end
    return table.concat(lines, "\n")
end

--- 读 ELF 头，判断架构 / 浮点 ABI / 是否静态链接
function Proc.elf_info(path)
    local f = io.open(path, "rb")
    if not f then return nil, _("无法打开文件") end
    local head = f:read(4096) or ""
    f:close()
    if #head < 40 or head:sub(1, 4) ~= "\127ELF" then
        return nil, _("不是 ELF 可执行文件")
    end
    local function u8(i) return head:byte(i) end
    local function u16le(i) return u8(i) + u8(i + 1) * 256 end
    local function u32le(i)
        return u8(i) + u8(i + 1) * 256 + u8(i + 2) * 65536 + u8(i + 3) * 16777216
    end
    local class = u8(5) == 1 and _("32 位") or _("64 位")
    local machine = u16le(19)
    local arch = ({ [40] = "ARM", [183] = "AArch64", [3] = "x86", [62] = "x86_64", [8] = "MIPS" })[machine]
        or ("machine=" .. tostring(machine))
    local flags = u32le(37)
    local abi = ""
    if machine == 40 then
        abi = (flags % 0x800 >= 0x400) and _("硬浮点 ABI") or _("软浮点 ABI")
    end
    local dynamic = head:find("ld-linux", 1, true) ~= nil or head:find("ld-musl", 1, true) ~= nil
    local parts = { class, arch }
    if abi ~= "" then parts[#parts + 1] = abi end
    parts[#parts + 1] = dynamic and _("动态链接") or _("静态链接")
    return table.concat(parts, " / ")
end

--- 从路径里猜版本号，**不执行二进制**。
--- 官方发布包解出来的目录带版本（easytier-linux-armv7-v2.6.4）；自己摆的目录一般猜不到。
function Proc.version_hint(path)
    local v = tostring(path or ""):match("[vV](%d+%.%d+%.%d+[%w%+%-~]*)")
    return v and ("v" .. v) or nil
end

--- 实测版本：会真的执行一次二进制（自解压包在阅读器上要几秒），所以只在用户明确要求时调用；
--- 两次尝试都带超时，卡住也不会把界面线程拖死。
function Proc.version(path)
    local ok, out = Proc.run(path, { "--version" }, 5)
    if ok and out and out:gsub("%s", "") ~= "" then
        return out:match("^%s*(.-)%s*$")
    end
    ok, out = Proc.run(path, { "--help" }, 5)
    if ok and out and out:gsub("%s", "") ~= "" then
        return out:match("^%s*([^\n]+)")
    end
    return nil
end

--==========================================================================
-- 进程控制
--==========================================================================

function Proc.read_pid()
    local f = io.open(Proc.PID_FILE, "r")
    if not f then return nil end
    local s = f:read("*l")
    f:close()
    local pid = s and tonumber(s:match("%d+"))
    return pid
end

local function pid_alive(pid)
    return pid ~= nil and util.pathExists("/proc/" .. pid)
end

--- 确认 PID 真的是我们的 core（避免 PID 复用误杀）
local function pid_is_core(pid)
    if not pid_alive(pid) then return false end
    local f = io.open("/proc/" .. pid .. "/cmdline", "r")
    if not f then return false end
    local cmdline = f:read("*a") or ""
    f:close()
    return cmdline:find(Config.CORE_NAME, 1, true) ~= nil
end

--- 当前运行的 easytier-core 进程（pidfile 优先，其次扫 /proc）
function Proc.pid(cfg)
    local pid = Proc.read_pid()
    if pid_is_core(pid) then return pid end
    if pid then
        -- PID 文件指向的进程已经不在（或 PID 被复用）：别留着误导后面的判断
        os.remove(Proc.PID_FILE)
    end
    local found = Proc.find_pids()
    return found[1]
end

function Proc.find_pids()
    local pids = {}
    local ok, iter, dir = pcall(lfs.dir, "/proc")
    if not ok or type(iter) ~= "function" then return pids end
    for entry in iter, dir do
        local pid = tonumber(entry)
        if pid and pid_is_core(pid) then
            table.insert(pids, pid)
        end
    end
    return pids
end

function Proc.is_running(cfg)
    return Proc.pid(cfg) ~= nil
end

--==========================================================================
-- 日志体积
--==========================================================================

--- 日志上限：长跑的设备上 /mnt/us 空间有限，easytier-core 在 info 级别下几小时就能写几十 MB。
--- 超过上限就只保留最近若干行（前面的丢掉，并留一行说明）。
Proc.LOG_MAX_BYTES = 1024 * 1024
Proc.LOG_KEEP_LINES = 1500

--- 人类可读的大小
function Proc.human_size(bytes)
    bytes = tonumber(bytes) or 0
    if bytes >= 1024 * 1024 then
        return string.format("%.1f MB", bytes / (1024 * 1024))
    end
    return string.format("%.0f KB", bytes / 1024)
end

--- 日志超限就瘦身。返回 trimmed（布尔）, 处理前的字节数
function Proc.trim_log(max_bytes, keep_lines)
    local path = Proc.log_path()
    local size = Proc.log_file_size()
    max_bytes = max_bytes or Proc.LOG_MAX_BYTES
    if size <= max_bytes then return false, size end

    keep_lines = keep_lines or Proc.LOG_KEEP_LINES
    local tail = Proc.tail_file(path, keep_lines, 256 * 1024)
    local f = io.open(path, "w")
    if not f then return false, size end
    f:write(string.format(_("（日志超过 %s 上限，只保留最近 %d 行）\n"),
        Proc.human_size(max_bytes), keep_lines))
    f:write(tail)
    f:close()
    logger.info(string.format("EasyTier: 日志瘦身 %d -> %d 字节", size, Proc.log_file_size()))
    return true, size
end

--==========================================================================
-- 进程控制
--==========================================================================

--- 启动 core。返回 ok, pid 或错误信息
function Proc.start(cfg)
    local core = Proc.find(Config.CORE_NAME, cfg)
    if not core then
        return false, _("找不到 easytier-core。请先按「安装说明」把二进制放到设备上。")
    end
    local dir, base = core:match("^(.*)/([^/]+)$")
    dir = dir or "."
    local log = Proc.log_path()
    Proc.data_dir()
    -- 上一轮的日志可能已经很大了：启动前瘦身，别让日志把用户分区吃掉
    Proc.trim_log()

    -- vfat 上不一定有执行位，顺手 chmod 一下（没权限时失败也无所谓）
    os.execute("chmod +x " .. Config.shquote(core))

    local argv = Config.build_argv(cfg)
    local parts = {}
    for _i, a in ipairs(argv) do
        parts[#parts + 1] = quote_arg(a)
    end

    local binary = Config.shquote("./" .. base) -- 必须走 ./，否则 sh 会去 PATH 里找
    -- 用 { } 把「后台启动」和「写 PID 文件」放进同一个 shell：
    -- 这样 $! 拿到的是 nohup（随后 exec 成 easytier-core）的 PID，
    -- 而不是 `cd ... && cmd &` 那种写法里外层子 shell 的 PID。
    local cmd = string.format("cd %s && { %s%s %s >> %s 2>&1 </dev/null & echo $! > %s; }",
        Config.shquote(dir),
        Proc.has("nohup") and "nohup " or "",
        binary,
        table.concat(parts, " "),
        Config.shquote(log),
        Config.shquote(Proc.PID_FILE))

    logger.info("EasyTier start:", cmd)
    os.execute(cmd)

    -- 等进程起来（最多 ~4 秒）
    local pid
    for _ = 1, 20 do
        pid = Proc.read_pid()
        if pid_is_core(pid) then break end
        pid = nil
        Proc.sleep(0.2)
    end

    if not pid then
        local tail = Proc.tail_log(15)
        return false, _("easytier-core 启动失败。日志末尾：\n\n") .. (tail ~= "" and tail or _("(日志为空)"))
    end

    if cfg.mode == "tun" and cfg.fix_firewall then
        Proc.firewall_add(cfg.dev_name)
    end

    return true, pid
end

--- 停止 core。force=true 时超时直接 SIGKILL
function Proc.stop(cfg, force)
    local pid = Proc.pid(cfg)
    if not pid then
        os.remove(Proc.PID_FILE)
        return true
    end

    os.execute(string.format("kill -TERM %d", pid))
    for _i = 1, 25 do
        if not pid_is_core(pid) then break end
        Proc.sleep(0.2)
    end
    if pid_is_core(pid) then
        os.execute(string.format("kill -KILL %d", pid))
        for _i = 1, 10 do
            if not pid_is_core(pid) then break end
            Proc.sleep(0.2)
        end
    end

    if cfg and cfg.mode == "tun" then
        Proc.firewall_del(cfg.dev_name)
    end

    os.remove(Proc.PID_FILE)
    -- 存活判定必须和 find_pids / kill_all 用同一个：只看 /proc/<pid> 在不在会踩两个坑——
    -- 被杀成僵尸的进程 /proc 目录还在（cmdline 却是空的），PID 被复用也会被误判成「还在跑」。
    -- 结果就是「停止说没停掉、清理又说 0 个进程」这种自相矛盾。
    if pid_is_core(pid) then
        return false, _("进程没有退出，PID ") .. tostring(pid)
    end
    return true
end

--- 清理所有残留的 easytier-core（包括不是本插件启动的）
function Proc.kill_all(force)
    local pids = Proc.find_pids()
    -- /proc 扫描有可能扫不到（例如 lfs 打不开 /proc）：pidfile 里那个确认还活着就一起处理，
    -- 免得出现「停止说没停掉、清理又说 0 个进程」这种自相矛盾
    local from_file = Proc.read_pid()
    if from_file and pid_is_core(from_file) then
        local dup = false
        for _i, pid in ipairs(pids) do
            if pid == from_file then
                dup = true
                break
            end
        end
        if not dup then table.insert(pids, from_file) end
    end
    for _i, pid in ipairs(pids) do
        os.execute(string.format("kill -%s %d", force and "KILL" or "TERM", pid))
    end
    os.remove(Proc.PID_FILE)
    return #pids
end

--==========================================================================
-- easytier-cli
--==========================================================================

function Proc.cli(cfg, args)
    local cli = Proc.find(Config.CLI_NAME, cfg)
    if not cli then
        return false, _("找不到 easytier-cli，无法读取状态。")
    end
    local argv = { "--rpc-portal", cfg.rpc_portal or "127.0.0.1:15888", "--no-trunc" }
    for _i, a in ipairs(args or {}) do
        argv[#argv + 1] = a
    end
    -- 必须带超时：easytier-cli 连不上 RPC 时可能一直等，而它是在界面线程里同步跑的
    return Proc.run(cli, argv, 6)
end

--- RPC 是否真的应答（单次探测）
function Proc.rpc_ok(cfg)
    local ok, out = Proc.cli(cfg, { "node", "info" })
    out = tostring(out or "")
    if not ok or out == "" then return false end
    if out:find("rror") or out:find("refused") or out:find("失败")
        or out:find("timeout") or out:find("timed out") then
        return false
    end
    return true
end

--- 判断 core 的 RPC 是否已经可用
function Proc.wait_ready(cfg, seconds)
    local attempts = (seconds or 6) * 5
    for _ = 1, attempts do
        if Proc.rpc_ok(cfg) then return true end
        Proc.sleep(0.2)
    end
    return false
end

--- 启动后确认：进程要一直活着，最好 RPC 也能应答。
--- 返回 ok, reason("rpc" | "no_cli" | "no_rpc"), detail（失败时的日志尾部）
function Proc.verify_started(cfg, seconds)
    local has_cli = Proc.find(Config.CLI_NAME, cfg) ~= nil
    local attempts = (seconds or 8) * 5
    local rpc_ok = false

    for _ = 1, attempts do
        if not Proc.is_running(cfg) then
            return false, "died", Proc.tail_log(20)
        end
        if has_cli and Proc.rpc_ok(cfg) then
            rpc_ok = true
            break
        end
        Proc.sleep(0.2)
    end

    if not Proc.is_running(cfg) then
        return false, "died", Proc.tail_log(20)
    end
    if rpc_ok then return true, "rpc", "" end
    if not has_cli then return true, "no_cli", "" end
    return true, "no_rpc", Proc.tail_log(10)
end

--==========================================================================
-- 日志
--==========================================================================

--- KOReader 的崩溃日志路径（crash.log 在数据目录根下）
function Proc.crash_log_path()
    return DataStorage:getFullDataDir() .. "/crash.log"
end

--- 通用：读文件末尾若干行（大文件只读尾部）
function Proc.tail_file(path, max_lines, max_bytes)
    max_bytes = max_bytes or Proc.MAX_LOG_BYTES
    if not util.pathExists(path) then return "" end
    local size = 0
    local attr = lfs.attributes(path)
    size = attr and attr.size or 0
    local f = io.open(path, "r")
    if not f then return "" end
    if size > max_bytes then
        f:seek("set", size - max_bytes)
        f:read("*l") -- 丢掉半行
    end
    local text = f:read("*a") or ""
    f:close()
    local lines = {}
    for line in text:gmatch("[^\n]+") do
        lines[#lines + 1] = line
    end
    local n = max_lines or 200
    if #lines > n then
        local tail = {}
        for i = #lines - n + 1, #lines do
            tail[#tail + 1] = lines[i]
        end
        lines = tail
    end
    return table.concat(lines, "\n")
end

function Proc.tail_log(max_lines)
    return Proc.tail_file(Proc.log_path(), max_lines or 200)
end

--==========================================================================
-- 权限 / TUN / 防火墙
--==========================================================================

function Proc.is_root(seconds)
    local res, out = Proc.exec("id -u", seconds)
    return (out or ""):match("^%s*0") ~= nil
end

function Proc.uname(seconds)
    local res, out = Proc.exec("uname -m", seconds)
    return (out or ""):gsub("%s+$", "")
end

--- 系统主机名（EasyTier 没给 --hostname 时用的就是它，对端节点列表里显示的就是这个名字）
function Proc.sys_hostname()
    local f = io.open("/proc/sys/kernel/hostname", "r")
    if not f then return nil end
    local s = f:read("*l")
    f:close()
    if s and s ~= "" then return s end
    return nil
end

--- /dev/net/tun 是否可用：ok（本来就有）/ created（刚 mknod 出来）/ missing
function Proc.tun_state()
    if util.pathExists("/dev/net/tun") then return "ok" end
    os.execute("mkdir -p /dev/net 2>/dev/null; mknod /dev/net/tun c 10 200 2>/dev/null")
    if util.pathExists("/dev/net/tun") then return "created" end
    return "missing"
end

--- 内核是否编了 TUN（zcat /proc/config.gz）
function Proc.kernel_tun(seconds)
    local res, out = Proc.exec("(zcat /proc/config.gz 2>/dev/null || gunzip -c /proc/config.gz 2>/dev/null) | grep -E '^CONFIG_TUN'", seconds)
    out = (out or ""):gsub("%s+$", "")
    if out == "" then return _("未知（读不到 /proc/config.gz）") end
    if out:find("CONFIG_TUN=y") or out:find("CONFIG_TUN=m") then
        return _("支持") .. " （" .. out:gsub("[^%w=]", " ") .. "）"
    end
    return _("不支持（内核关闭了 TUN）：") .. out
end

function Proc.firewall_add(iface)
    if not iface or iface == "" then return false end
    if not Proc.has("iptables") then return false end
    local q = Config.shquote(iface)
    local ok = Proc.exec(string.format("iptables -C INPUT -i %s -j ACCEPT", q))
    if ok then return true end
    Proc.exec(string.format("iptables -I INPUT 1 -i %s -j ACCEPT", q))
    return true
end

function Proc.firewall_del(iface)
    if not iface or iface == "" then return false end
    if not Proc.has("iptables") then return false end
    local q = Config.shquote(iface)
    for _ = 1, 3 do
        local ok = Proc.exec(string.format("iptables -D INPUT -i %s -j ACCEPT", q))
        if not ok then break end
    end
    return true
end

function Proc.firewall_rule_present(iface)
    if not iface or iface == "" or not Proc.has("iptables") then return false end
    -- 不用管道 grep：直接在 Lua 里判断，避免管道让 timeout 只管到前一个命令
    local res, out = Proc.exec("iptables -S INPUT 2>/dev/null", 3)
    for line in tostring(out or ""):gmatch("[^\n]+") do
        if line:find("-i " .. iface, 1, true) then return true end
    end
    return false
end

--==========================================================================
-- 诊断报告
--==========================================================================

function Proc.diagnostics(cfg)
    logger.info("EasyTier: 开始收集诊断信息")
    local L = {}
    local function line(fmt, ...) L[#L + 1] = string.format(fmt, ...) end

    line("== 设备 ==")
    local res, uname = Proc.exec("uname -a", 3)
    line("%s", (uname or ""):gsub("%s+$", ""))
    line("CPU 架构（uname -m）：%s", Proc.uname(3))
    line("运行用户 uid：%s", Proc.is_root(3) and "0 (root)" or "非 root —— 需要一个能执行 iptables/mknod 的环境")
    local attr = lfs.attributes("/lib/libc.so.6")
    if attr then
        local res, v = Proc.exec("grep -a -o 'GNU C Library[^\\\\]*' /lib/libc.so.6 | head -1", 3)
        line("系统 libc：%s", (v or ""):gsub("%s+$", ""))
    end

    line("")
    line("== 内核 TUN ==")
    line("CONFIG_TUN：%s", Proc.kernel_tun(3))
    line("/dev/net/tun：%s", util.pathExists("/dev/net/tun") and "存在" or "不存在")

    line("")
    line("== 二进制 ==")
    for _i, name in ipairs({ Config.CORE_NAME, Config.CLI_NAME }) do
        local path = Proc.find(name, cfg)
        if path then
            local elf = Proc.elf_info(path)
            line("%s -> %s", name, path)
            line("   %s", elf or "?")
            if name == Config.CORE_NAME then
                -- 这里故意不执行二进制去问版本：自解压包在阅读器上要几秒，
                -- 会把界面线程占住。要实测版本请用「工具 → 查看 core 版本」。
                line("   版本：%s", Proc.version_hint(path) or "未实测（工具 → 查看 core 版本）")
            end
        else
            line("%s -> 未找到", name)
        end
    end
    line("搜索过的目录：")
    L[#L + 1] = Proc.search_report(cfg)

    line("")
    line("== 运行状态 ==")
    local pid = Proc.pid(cfg)
    if pid then
        line("PID：%d", pid)
        line("防火墙规则（-i %s）：%s", cfg.dev_name, Proc.firewall_rule_present(cfg.dev_name) and "已放行" or "无")
    else
        line("未运行")
    end

    logger.info("EasyTier: 诊断信息收集完成")

    return table.concat(L, "\n")
end

return Proc
