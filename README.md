# koreader-easytier

在 Kindle / Kobo 等阅读器上，用 [KOReader](https://github.com/koreader/koreader) 插件控制独立运行的
[EasyTier](https://github.com/EasyTier/EasyTier) 异地组网节点：启停、配置、查看对端与路由。

插件**不内嵌** EasyTier —— 它只负责启动/停止 `easytier-core` 进程、把设置翻译成命令行、把节点状态显示出来。
TUN、权限、架构这些事都留在 EasyTier 那边，插件本体相当于一个遥控器。

## 功能

* 菜单一键**启动 / 停止**，勾选状态反映进程真实状态，并显示 PID
* **配置**：网络名称 / 密钥、初始节点、DHCP 或固定 IP、共享子网、监听地址、端口转发、RPC 端口、
  主机名 / 实例名、TUN 接口名、MTU、默认协议、日志级别、附加参数、程序目录
* **四个页面**：连接状态（`node info` / `peer` / `route`）、运行日志、环境诊断、KOReader 崩溃日志
* **自动化**：随 KOReader 启动、连上 Wi-Fi 后启动、进程意外退出后自动拉起（看门狗）
* **手势与 Profiles**：注册了开关 / 启动 / 停止 / 状态 4 个动作
* **Kindle 适配**：启动时自动放行 TUN 接口的入向包（Kindle 防火墙会拦），停止时撤掉

## 要求

* 越狱的 Kindle、Kobo 或 PocketBook，已安装 KOReader（Kindle 上 KOReader 以 root 运行，这是建 TUN、改路由的前提）
* 另一台机器上跑着同网络名 / 同密钥的 EasyTier 节点，或使用公共共享节点
* 自行准备 EasyTier 二进制（不随插件分发）：官方 release 里的 `easytier-linux-armv7-*.zip` 解出
  `easytier-core` 与 `easytier-cli`，放到 `/mnt/us/easytier/bin/`

## 安装

1. 下载 [最新 Release](https://github.com/WanderSu/koreader-easytier/releases/latest) 里的 `easytier.koplugin.zip` 并解压
2. 把 `easytier.koplugin/` 拷进 KOReader 的 `plugins/` 目录（Kindle：`/mnt/us/koreader/plugins/`）
3. 按上面的要求放好 `easytier-core` 与 `easytier-cli`；在电脑上也可以直接用
   `tools/prepare-device.sh` 一键下载并整理好这两个目录
4. 重启 KOReader

## 使用

菜单 **网络 → EasyTier 异地组网**：

1. **配置 → 网络名称 / 网络密钥**：同一个网络里所有节点必须填完全一样的值
2. **初始节点**：启动时要连的地址，多个用逗号分隔。可以填自己的节点，也可以填公共共享节点，
   例如 `tcp://public.easytier.top:11010`
3. **节点 IP**：留着「DHCP 自动分配 IP」最省事；关掉就要自己填一个 `10.144.144.x`
4. 回到菜单点 **启动 EasyTier**，然后看 **连接状态** 里的 `peer` / `route`

两台以上设备要用同一个网络名 / 密钥，并且**填相同的初始节点列表**。

### 两种运行模式

| 模式 | 说明 | 适用 |
| --- | --- | --- |
| **TUN**（默认） | 创建虚拟网卡，整个设备按虚拟网 IP 走路由 | 有 `/dev/net/tun` 的设备，KOReader 的 OPDS、Calibre、同步都能直接用虚拟网 IP |
| **代理** | `--no-tun` + SOCKS5，不创建虚拟网卡 | 内核没有 TUN 驱动的设备；需要把程序自己的 SOCKS5 代理指向 `127.0.0.1:<端口>` |

另外「端口转发」在两种模式下都能用，且不需要任何代理支持：把虚拟网络里的服务映射到本机端口后，
用 `127.0.0.1:<本地端口>` 访问即可，适合让 KOReader 连局域网里的 Calibre / OPDS。

### 常见问题

| 现象 | 处理 |
| --- | --- |
| 提示找不到 `easytier-core` | 跟着菜单 **工具 → 安装说明** 里的目录列表放好二进制，或用 **进阶 → 程序目录** 手动指定 |
| 启动不起来 | **工具 → 查看日志** 看末尾几行；**工具 → 运行诊断** 会把环境、架构、二进制、内核 TUN 一次性列出来 |
| 起来了但访问不通 | ① 连接状态里 `peer` / `route` 有没有对端；② 看防火墙放行是否为「是」；③ 访问对方局域网还需要对方开了共享子网 |
| `/dev/net/tun` 不存在 | 切「代理」模式，或用「端口转发」把需要的服务映射出来 |
| 对端列表里显示的名字不对 | 对端看到的是**主机名**（`--hostname`），不是实例名；两者都不允许空格 |
| 退出 KOReader 后它还在跑 | 这是设计如此：core 是独立进程，KOReader 退出不会杀掉它。想停就在菜单里点「停止 EasyTier」 |
| 不想让它自动跑 | 关掉 **自动化 → 随 KOReader 启动时自动组网**；这个开关是唯一决定 KOReader 启动时是否拉起进程的开关 |

## 兼容性

| 设备 | 状态 |
| --- | --- |
| Kindle Paperwhite 6（armv7l，固件 5.19） | 已实测：组网、状态页、日志、诊断正常 |
| 其他 Kindle / Kobo / PocketBook | 未实机验证。要求是能跑 KOReader 的 Linux 设备，且有 `/dev/net/tun` |
| 无 TUN 的设备 | 用「代理」模式或「端口转发」 |

EasyTier 官方 Linux armv7 包是静态链接的 32 位 ARM 二进制，没有额外的库依赖，可直接放在设备用户分区运行。

## 许可与致谢

* 本插件以 **AGPL-3.0** 发布，见 `LICENSE`。
* [EasyTier](https://github.com/EasyTier/EasyTier) 是独立的 LGPL-3.0 项目，本插件不包含也不修改其代码，
  只调用你自己准备的 `easytier-core` / `easytier-cli`。
* 插件接口与若干写法参考了 KOReader 自带的 SSH / KeepAlive 插件。

## 开发

```bash
tests/run-all.sh [easytier-core 路径]        # 单元测试，不需要 KOReader
```

* 命令行参数只发长选项，并与 EasyTier **v2.6.4** 源码逐个核对；升级 EasyTier 时先核对再改
