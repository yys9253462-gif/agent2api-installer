# agent2api 一键安装器

给 [agent2api](https://github.com/aimod-cc/agent2api)（多提供商本地网关 + 管理面板）用的交互式部署脚本。
一条命令完成：拉镜像 → 起容器 → 可选绑域名并**自动申请 Let's Encrypt 证书** → 接好反向代理。

- **单文件**：`install-agent2api.sh`，除 docker 外无依赖
- **版本**：v1.1.0
- **配套回归套件**：`test-install-agent2api.sh`（29 个用例，一条命令跑完）
- **测试状态**：已在 Debian 12 + Docker 29.8.1 上端到端实测通过（含真实域名签证书、SSE 流式、升级回滚、卸载）

> ⚠️ **免责声明**：本仓库是**非官方**的第三方部署脚本，与 agent2api 上游项目及作者无任何关联，
> 也未获其背书。上游项目迭代很快，脚本按当前版本的接口行为编写，上游若改动接口可能需要相应调整。
> 使用前请自行评估。本仓库**未附许可证**，默认保留全部权利。

---

## 下载

```bash
# 安装脚本
curl -fsSLO https://raw.githubusercontent.com/yys9253462-gif/agent2api-installer/main/install-agent2api.sh

# 回归套件（可选，改脚本后用来自测）
curl -fsSLO https://raw.githubusercontent.com/yys9253462-gif/agent2api-installer/main/test-install-agent2api.sh
```

国内访问 GitHub 不稳，也可以走网盘（永久取件码 **20818**）：<https://pan.ailxw.com/pickup/20818>

图文教程（含逐项参数、实测记录与踩坑）：<https://isoziyuan.com/p/100171/>

---

## 功能总览（v1.1.0）

| 分类 | 能力 |
| --- | --- |
| **安装** | 交互式 / `--yes` 全自动；`--dry-run` 预演；镜像 tag 默认自动查最新；内存上限、时区可配 |
| **端口** | 自动避开宿主监听 + docker 已发布端口；**绑定失败自动换端口重试**（最多 3 次） |
| **反代** | 自动识别 **4 种形态**：宿主 Caddy / 容器 Caddy / **裸机自建 Caddy** / 不绑；`--caddy-mode` 可强制 |
| **域名与证书** | DNS 校验 → 备份 → 追加站点块 → validate → **热重载** → 等证书签发 → 验 HTTPS 与 `/v1`；**任一步失败自动回滚** |
| **注册开关** | **默认不封**（浏览器直接注册）；`--lock-register` 可封成 403；装完会检测「管理员注册了没」并提醒 |
| **幂等** | 标记块式管理，重跑不叠加；**状态文件当默认值**（命令行显式项优先）；`--no-domain` 显式移除 |
| **运维** | `--status`（健康/证书到期/日志）、`--check-update`、**`--upgrade`（健康门禁 + 失败自动回滚）** |
| **卸载** | 停容器 + 按标记摘除站点块 + 可选删目录；从未安装时也不报错 |
| **健壮性** | 非法输入全部拦下；中断保护（SIGTERM 还原配置）；失败原因**分型如实回显**而非猜测 |
| **集成** | `--with-manager` 登记为 workbuddy-manager 上游，网关 Key **自动从本机库读取**（免粘贴） |
| **Nginx 用户** | 不自动改 Nginx，但打印**可直接粘贴**的 server 块 + certbot 命令（含 `proxy_buffering off`） |

**自动化回归套件**：`test-install-agent2api.sh`，**29 个用例**，一条命令跑完。

---

## 一句话

把 agent2api（多提供商 OpenAI 兼容网关 + 管理面板）装到本机，**自动挑空闲端口**、**可选绑域名并自动申请 SSL**、**自动识别已有的 Caddy** 并接好反代，全程交互式。

---

## 快速开始

**在 VPS 上执行**（不是在你自己的电脑上 —— 脚本是装服务的，要在目标服务器上跑）。

一条命令，不用先在本地下载再上传。

**如果你的提示符是 `#`（登录就是 root，多数 VPS 默认如此）**：

```bash
curl -fsSL "https://pan.ailxw.com/api/pickup-download?code=20818" -o ~/a2a.sh && bash ~/a2a.sh
```

**如果你的提示符是 `$`（普通用户）**，把最后的 `bash` 换成 `sudo bash`：

```bash
curl -fsSL "https://pan.ailxw.com/api/pickup-download?code=20818" -o ~/a2a.sh && sudo bash ~/a2a.sh
```

带参数就接在后面：

```bash
curl -fsSL "https://pan.ailxw.com/api/pickup-download?code=20818" -o ~/a2a.sh \
  && bash ~/a2a.sh --domain a2a.example.com --expose both
```

> ⚠️ **别习惯性地加 `sudo`**。很多精简镜像（尤其登录就是 root 的）**根本没装 sudo**，
> 加了会直接报 `sudo: command not found`，后面还会跟一个 `curl: (23) Failed writing body`
> —— 看着像网络问题，其实是 sudo 不存在。**先看提示符是 `#` 还是 `$`。**

**为什么写成 `-o 文件 && bash 文件` 而不是 `curl … | bash`**（两种都踩过）：

- **管道会把 stdin 占掉**。安装器默认是交互式的，`curl | bash` 时它读不到你的键盘，
  会**静默全部采用默认值**往下装 —— 你以为在交互，其实一个都没问。
- **管道失败是无声的**。`curl -fsSL | bash` 里如果源不通，curl 不输出任何东西、
  bash 收到空输入，**屏幕上什么都不会出现**。国内访问 `cdn.jsdelivr.net` 经常不通，
  症状就是"粘上去没反应"。

写成上面那样：出错会打印原因、`&&` 会拦住后续、stdin 还是你的终端，交互正常。

> **粘上去没反应？** 那就是网盘这个源也不通。换下面任一条试试（脚本内容相同）：
> ```bash
> # jsDelivr CDN
> curl -fsSL "https://cdn.jsdelivr.net/gh/yys9253462-gif/agent2api-installer@main/install-agent2api.sh" -o ~/a2a.sh && sudo bash ~/a2a.sh
> # GitHub 直连
> curl -fsSL "https://raw.githubusercontent.com/yys9253462-gif/agent2api-installer/main/install-agent2api.sh" -o ~/a2a.sh && sudo bash ~/a2a.sh
> ```
> 也可以直接用引导脚本，它会**自动在三个源之间回退**：
> ```bash
> curl -fsSL https://cdn.jsdelivr.net/gh/yys9253462-gif/agent2api-installer@main/deploy.sh | sudo bash
> ```

## 交互流程（默认只问 2 个问题）

```
【第 1 步】要不要绑域名？
      绑  → 自动申请 HTTPS 证书，客户端用 https://你的域名/v1（推荐）
      不绑 → 只能走 SSH 隧道，客户端用 http://127.0.0.1:<网关端口>/v1
域名（没有就直接回车） []:

【第 2 步】高级选项：安装目录 / 容器名 / 端口 / 内存 / 时区 / 镜像版本
    这些默认值都挑好了，一般不用改
需要改吗？ [n]:
```

不绑域名就直接回车，高级选项也直接回车 —— 两个回车装完。
端口是**自动挑空闲的**，不用你操心。（如果你在命令行上给过 `--dir`/`--mem` 这类参数，
脚本会认为你是老手，第 2 步不再问，但仍会把你没给的那几项问一遍。）

> 如果**不是**在终端里跑（比如管道、CI），脚本会明确告诉你「当前不是交互终端：所有问题将自动采用默认值」——
> 不会像以前那样静默地全用默认值让你以为脚本坏了。

---

## 不绑域名怎么用（SSH 隧道）

装完脚本会把这条命令**按你的实际端口和 IP 打印出来**，直接复制即可：

```bash
ssh -N -L 3066:127.0.0.1:3066 -L 3065:127.0.0.1:3065 root@<你的服务器IP>
```

- **两个端口都要转**：`3066` 是面板，`3065` 是网关。只转面板的话，面板能打开、
  但客户端连不上网关 —— 而网关才是这东西的用途。
- 这条命令**要一直开着**（另开一个终端窗口跑）。它不输出任何东西、看着像卡住 ——
  那是在转发，正常。要停就 `Ctrl+C`。
- 隧道只对**你自己这台电脑**有效，别人访问不到（这也是它比直接把端口暴露到公网安全的地方）。
- 然后：面板 → 浏览器开 `http://127.0.0.1:3066`；客户端 `base_url` → `http://127.0.0.1:3065/v1`。

**嫌麻烦就绑个域名**：带 `--domain 你的域名` 重跑，自动签 HTTPS 证书，之后就不用隧道了。

### 隧道每次都要输密码？配一次免密（30 秒）

在**你自己的电脑**上做（Windows 的 CMD / PowerShell / Git Bash 都行）：

```bat
:: 1) 生成一把专用于这台服务器的密钥（一路回车，不用设密码短语）
ssh-keygen -t ed25519 -f %USERPROFILE%\.ssh\a2a-vps -C a2a-vps

:: 2) 把公钥装到服务器上 —— 这一步要输一次密码，之后就再也不用输了
type %USERPROFILE%\.ssh\a2a-vps.pub | ssh root@你的服务器IP "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

:: 3) 验证：这条应该不再问密码
ssh -i %USERPROFILE%\.ssh\a2a-vps root@你的服务器IP echo ok
```

（Linux/macOS 上用 `ssh-copy-id -i ~/.ssh/a2a-vps.pub root@你的服务器IP` 代替第 2 步。）

**更省事：把隧道写进 SSH 配置，以后一条命令搞定。** 编辑 `%USERPROFILE%\.ssh\config`，加：

```
Host a2a
    HostName 你的服务器IP
    User root
    IdentityFile ~/.ssh/a2a-vps
    LocalForward 3066 127.0.0.1:3066
    LocalForward 3065 127.0.0.1:3065
    ExitOnForwardFailure yes
```

以后只要：

```bat
ssh -N a2a
```

两个端口就都转好了，不问密码。（`-N` = 只转发不开 shell。这条命令要一直开着，`Ctrl+C` 停。）

> ⚠️ **关于密码**：不要让别人（包括 AI）把服务器密码打印到聊天记录或终端里 ——
> 那会同时留在聊天历史、命令历史和对方上下文里。用密钥才是正解：
> 私钥只在你本机，服务器上只放公钥，泄了也偷不走。**

---

## 常见报错（都是真实遇到过的）

| 你看到的 | 真正的原因 | 怎么办 |
| --- | --- | --- |
| `sudo: command not found` 后面跟 `curl: (23) Failed writing body` | 你**登录就是 root**，而这台机器**没装 sudo** | 去掉 `sudo`，直接 `bash ~/a2a.sh`。先看提示符是 `#`（root）还是 `$`（普通用户） |
| 粘上去**一点输出都没有**，光标直接回来 | 下载源不通（`curl -fsSL … \| bash` 的失败是**无声的**） | 换源（见上面三个源），或改用 `-o 文件 && bash 文件` 的写法 |
| `docker: command not found` | 机器上还没装 Docker | 先装：`curl -fsSL https://get.docker.com \| sh`（或按发行版官方文档） |
| `需要 root 权限运行…` | 你是普通用户 | 按提示把 `bash` 换成 `sudo bash` |
| `80/443 被 xxx 占用` | 机器上已有反代（Nginx 等）在跑 | 脚本会打印可直接粘贴的 Nginx 片段；或腾出 80/443 后用 `--caddy-mode self` |

**如果脚本已经在机器上**，直接跑：

```bash
# 全交互（推荐第一次）
sudo bash install-agent2api.sh

# 只看看它打算做什么，不动手
sudo bash install-agent2api.sh --dry-run

# 全自动（CI / 批量部署）
sudo bash install-agent2api.sh --yes --domain a2a.example.com --expose both

# 装完带域名，走 Cloudflare 橙云
sudo bash install-agent2api.sh --yes --domain a2a.example.com --cf=y

# 卸载
sudo bash install-agent2api.sh --uninstall
```

常用参数（完整列表见 `--help`）：

| 参数 | 说明 |
| --- | --- |
| `--dir <路径>` | 安装目录，默认 `/opt/agent2api` |
| `--tag <版本\|latest>` | 镜像 tag（默认自动查 Docker Hub 最新版） |
| `--domain <域名>` | 绑域名 + 自动签 SSL；**不带则沿用上次的**（从未装过则不绑） |
| `--no-domain` | 明确不要域名：移除上次写入的反代站点块 |
| `--expose both\|panel\|gateway` | 域名下暴露面板 / 网关 / 两者（默认 both，`/v1*` 走网关，其余走面板） |
| `--panel-port` / `--gateway-port` | 手动指定端口；默认从 3066 / 3065 起自动找空闲 |
| `--mem <大小>` | 容器内存上限，默认 `384m` |
| `--cf [y\|n]` | 域名是否走 Cloudflare 代理（会自动加真实 IP 还原） |
| `--caddy-mode <形态>` | 强制反代形态：`docker` / `host` / `self`（自建 Caddy）。默认自动探测 |
| `--status` | 查看运行状态（容器/端口/域名/证书到期/最近日志） |
| `--check-update` | 查询 Docker Hub 上是否有新版本 |
| `--upgrade` | 升级到最新版（可配 `--tag` 指定版本）；健康复检不过**自动回滚** |
| `--lock-register` / `--open-register` | 是否封掉公网自助注册（**默认不封**） |
| `--with-manager` / `--no-manager` | 是否登记为已有 workbuddy-manager 的上游 |
| `--skip-dns-check` | 跳过「域名是否解析到本机」校验（走 CDN 回源时用） |
| `--dry-run` / `-y` / `--uninstall` | 预演 / 全默认不交互 / 卸载 |

---

## 它做了什么（6 步）

1. **探测环境**：docker 是否可用、80/443 上是谁（**同时识别容器里的 Caddy 与宿主的 Caddy/systemd**）、Caddyfile 在哪。
2. **收集配置**：逐项询问，直接回车用默认值。
3. **端口避让**：同时统计**宿主监听端口**与**docker 已发布端口**，从 3066/3065 起挑两个空闲的；不信默认值的话它会在起容器后**复核**，仍冲突就自动换端口重试（最多 3 次）。
4. **生成并启动**：写出 `docker-compose.yml`，拉镜像，起容器，等待 healthy，并从**容器内部**验证两个端口真的在服务。
5. **域名与证书**（可选）：校验 DNS → **备份** Caddyfile → 追加带标记的站点块 → `validate` → `reload` → 等证书签发 → 验 HTTPS 与 `/v1`。**任一步失败自动回滚**。
6. **可选集成**：把本服务登记为已有 workbuddy-manager 的上游（自动登录它的接口，账号目录留空 = 纯密钥转发）。

---

## 它会改动机器上的什么

| 位置 | 内容 | 撤销方式 |
| --- | --- | --- |
| `$INSTALL_DIR`（默认 `/opt/agent2api`） | `docker-compose.yml`、`data/`（含上游凭证）、`install.conf` | `--uninstall` 可选删目录 |
| Docker | 一个容器（默认名 `agent2api`）、一个 compose 网络、一个镜像 | `--uninstall` |
| Caddyfile（仅当你给了 `--domain`） | 追加一段**带起止标记**的站点块 | `--uninstall` 按标记摘除 |
| `<Caddyfile>.bak-<时间戳>-preAgent2API` | 改动前的备份，**保留** | 手动 |

**幂等**：重复运行会先摘掉自己上次写的托管块再重写，不会叠加；`install.conf` 记着上次的选择。

**重跑的语义（重要）**：`install.conf` 里的值会作为**本次的默认值**，命令行显式给出的项优先。
所以「升级镜像 / 改端口」时说清楚要改哪一项即可，其余（含域名）自动沿用 ——
不会出现「重跑一次域名就丢了、而反代里还留着指旧端口的死配置」这种事。
确实想去掉域名就显式给 `--no-domain`，它会把站点块一起摘掉。

---

## 反代形态（4 种，自动识别 + 可强制）

| 形态 | 触发条件 | 反代后端 | 说明 |
| --- | --- | --- | --- |
| `host` | 宿主上有 Caddy 进程/systemd | `127.0.0.1:<端口>` | 往宿主 Caddyfile 追加站点块 |
| `docker` | 80/443 上是个 Caddy **容器** | `<容器名>:<端口>` | 加入该容器所在网络，按容器名反代 |
| `self` | **80/443 上没有反代（裸机）** | `<容器名>:<端口>` | **由本脚本自建一个 Caddy 容器**，证书落在 `$INSTALL_DIR/caddy-data` |
| `none` | 不绑域名时 | — | 只用 SSH 隧道访问（**面板 + 网关两个端口一起转发**，见下） |

用 `--caddy-mode host|docker|self` 可强制指定（自动探测不准时用）。
检测到 **Nginx** 或其他程序占用 80/443 时会明确告知需手动反代，不会乱改别人的配置。

---

## 日常运维

```bash
sudo bash install-agent2api.sh --status --dir /opt/agent2api        # 看状态
sudo bash install-agent2api.sh --check-update --dir /opt/agent2api  # 查有没有新版本
sudo bash install-agent2api.sh --upgrade --dir /opt/agent2api       # 升到最新
sudo bash install-agent2api.sh --upgrade --tag 2.8.0 --dir /opt/... # 升/降到指定版本
```

升级是**带健康门禁**的：改 compose 镜像 → 拉取 → 重建 → 等 healthy → **从容器内部复核两个端口**；
任何一步不过就**自动回滚到原版本**并重启旧容器，状态文件也不会被写坏。
（agent2api 迭代很快——本项目观测到 6 天 10 个版本，所以升级通道值得单独做好。）

**网关 Key 免粘贴**：`--with-manager` 登记上游时，脚本会先尝试从
`$INSTALL_DIR/data/agent2api.db` 直接读已启用的网关 Key（明文不显示、不落日志），
读不到才提示你手工粘贴。

---

## 域名与证书的前置条件

1. 域名 A 记录**已指向本机公网 IP**（脚本会自己比对并提示；不一致会拦下来）。
   用 Cloudflare 橙云 + CDN 回源时加 `--skip-dns-check`。
2. 本机 **80 / 443 可用**：
   - 已有 Caddy（宿主或容器）→ 脚本只往它里面**加站点块**，不抢端口、不重启反代；
   - **完全没有反代 → 脚本自建一个 Caddy 容器**（`self` 形态），需要 80/443 空闲；
   - 被 Nginx 等占用 → 脚本会告诉你自行反代，不会乱动。
3. 云安全组 / 防火墙放通 80、443（Let's Encrypt 的 HTTP-01 需要从公网访问）。

---

## 注册与安全（重要）

agent2api 的规则是「**第一个打开面板的人注册成管理员**」。域名签了证书后，主机名会进
**Certificate Transparency 日志被公开索引** —— 所以在「面板刚上线、管理员还没注册」的那段时间里，
谁先打开谁就是管理员。

**脚本默认不封注册**（`/api/panel/setup` 正常可用）—— 大多数人就是想在浏览器里直接注册完事。
但脚本装完会**检测管理员注册了没**，没注册就醒目提醒：

```
× 管理员还没注册 —— 现在任何人打开面板都能抢注成管理员，请立刻去注册！
    立刻打开：https://你的域名/
```

**想更稳妥就封掉**：重跑时加 `--lock-register`，注册端点返回 403，注册改走 **SSH 隧道**
（隧道直连容器、不经过 Caddy，不受该规则影响）。注意**两个端口都要转发** ——
只转面板的话，面板能开、但客户端连不上网关：

```bash
ssh -N -L 3066:127.0.0.1:3066 -L 3065:127.0.0.1:3065 root@<服务器IP>
# 端口改成你自己的（脚本装完会把这条命令按实际端口打印出来，可直接复制）
# 这条命令要一直开着；它不输出任何东西、看着像卡住 —— 那是在转发，正常
```

然后：面板开 `http://127.0.0.1:3066`，客户端 `base_url` 填 `http://127.0.0.1:3065/v1`。
想再开回来：重跑加 `--open-register`。

| 你的情况 | 建议 |
| --- | --- |
| 想直接在浏览器里注册（大多数人） | 默认就行（不封），**装完马上去注册** |
| 域名会被扫到、且你不急着注册 | 加 `--lock-register`，注册走隧道 |

注册完就能用域名正常登录。确实想开公网注册就加 `--open-register`（不推荐）。

---

## 实测记录

**第一轮**（2026-09-28，Debian 12 + Docker 29.8.1，宿主 systemd Caddy）

| 用例 | 结果 |
| --- | --- |
| 无域名安装（自动挑 3065/3066） | 容器 healthy，面板/网关均 200 |
| **端口被占**（3065/3066 已占用） | 自动挑到 **3067/3068** |
| **指定被占端口**（`--panel-port 3065`） | 起容器失败 → **自动换端口重试** → 成功 |
| **域名 + 自动签证书** | Caddyfile 备份 → 校验 → 热重载 → **Let's Encrypt 签发成功** |
| 域名下 `/` / `/v1/models` | 200 / 200 |
| 域名下 `POST /api/panel/setup` | **403**（注册已封） |
| 无 Key 调 `/v1/chat/completions` | 503（fail-closed） |
| **重复运行**（幂等） | 托管块仍只有一对标记，不叠加 |
| **卸载** | 容器删除 + 站点块移除 + 重载，**原有生产站点仍 200** |

**第二轮（压力测试，专门找死路）**

| 用例 | 结果 |
| --- | --- |
| 端口 `abc` / `99999` / `0` | 明确报错并中止，**不做任何改动** |
| `--expose foo` | 明确报错（此前会**静默生成一个空 route**，域名整体不通） |
| 域名带大写与 `https://` 前缀 | 归一化为 `z3.example.com` |
| 相对路径 `--dir relative/path` | 归一化为绝对路径 |
| `--mem 384mb` / `--container -bad` | 格式校验拦下 |
| 非 root 运行 | 明确提示需要 root |
| **域名已在 Caddyfile 里被别的块占用** | **起容器之前**就失败退出，零改动 |
| **不带任何参数重跑 `--yes`** | 正确读回上次的域名/端口/暴露模式，服务照常 |
| `--no-domain` | 站点块被摘除、Caddy 校验通过、容器不受影响 |
| **目录已删但容器还在**时 `--uninstall` | 仍能把容器清掉 |
| **安装过程中被 SIGTERM 打断** | 自动还原 Caddyfile（退出码 130），配置仍 valid、生产站 200 |
| 最终回归：全新装 → 验收 → 卸载 | 全绿，无残留，Caddyfile valid |

---

**第三轮（裸机自建 Caddy + 回归套件，2026-09-28）**

| 用例 | 结果 |
| --- | --- |
| **裸机（80/443 无任何反代）自动判定 `self` 形态** | 自动起 `caddy:2-alpine`，**Let's Encrypt 签发成功**，证书落在 `caddy-data/` |
| 自建形态下 `/` 200、`/v1/models` 200、`setup` 403 | 全绿 |
| 自建形态卸载 | 两个容器（agent2api + caddy）都移除，**80/443 释放** |
| 强制 `--caddy-mode self` 但 80/443 被占 | fail-fast，明确告知三种处置方案，零改动 |
| `--caddy-mode self` 但没给域名 | 提示「没有站点要服务」并退回不用反代 |
| **回归套件（无域名）** | **18 通过 / 0 失败** |
| **回归套件（带域名）** | **23 通过 / 0 失败 / 0 跳过** |
| 套件自身清理 | 无残留容器/目录/配置块；生产站 rdwb.example.net 全程 200 |

**回归套件** `test-install-agent2api.sh` 把这 29 个用例固化成一条命令，改完脚本直接跑。

---

**第四轮（版本管理 + 流式验证，2026-09-28）**

| 用例 | 结果 |
| --- | --- |
| `--status` | 正确报告容器/端口/健康/域名/证书到期/日志尾部 |
| `--check-update` | 正确给出当前与最新版本（实测镜像已自动跟到 **2.8.0**） |
| `--upgrade` 同版本 | 提示「无需升级」，不做任何改动 |
| `--upgrade --tag 9.9.9-nonexistent` | 拉取失败 → **回滚到 2.8.0**，服务仍 healthy，**状态文件未被污染** |
| 真实降级 2.8.0 → 2.7.10 → 升回 2.8.0 | 两次都 healthy，状态文件同步更新 |
| **SSE 流式（此前从未测过）** | 经 `wb.example.com`：首字节 **0.58s** vs 总耗时 **3.28s**，**37 个 data 帧 + 1 个 `[DONE]`** |
| 同上，直连 `a2a.example.com` | 首字节 **0.08s** vs 总耗时 **2.15s**，35 帧 → **两条路都没有被整段缓冲** |
| Nginx 占用 80/443 时 | 打印可直接粘贴的 server 块 + certbot 命令（含 `proxy_buffering off` 提醒） |
| **回归套件（含域名 + 流式）** | **28 通过 / 0 失败 / 0 跳过** |

---

## 踩过的坑（都已在脚本里规避）

1. **`docker-proxy` 会造成「端口校验假通过」** —— 宿主端口被 docker 绑上了，但容器里根本没有进程在监听。
   只查宿主 `ss` 会通过校验、实际一访问就 502。**必须从容器内部验证**（脚本已这么做）。
2. **自定义端口要同时传给容器内部** —— 只改宿主映射没用：agent2api 内部监听端口由
   `AGENT2API_PANEL_PORT` / **`AGENT2API_PROXY_PORT`** 决定，不改就会出现「面板通、`/v1` 502」。
3. **交互函数把菜单打到 stdout，会被 `$( )` 一起捕获** —— 于是 `choose` 的返回值里混进菜单文本，
   `case` 永远匹配不上，**用户的选择从来没生效过**，且没有任何报错。
   交互函数的提示与菜单**必须写 stderr**，stdout 只留结果。
4. **Caddy 的 `respond` 会被重排到 `handle` 之后而永不生效** —— 站点块内指令按全局顺序排列，
   `handle` 是终结性的。拦截规则**必须写在 `route {}` 里**。
5. **失败原因别猜** —— 原稿把 `compose up` 失败一律说成「端口被占用」，实际可能是容器名冲突。
   现在回显 docker 原始输出并分型（端口 / 容器名 / 健康检查 / 其他），且**只对端口类做重试**。
6. **函数里别直接 `die`** —— 会让上层的重试/兜底逻辑永远走不到；要重试就必须 `return 1`。
7. **改共享配置要有中断保护** —— Ctrl-C 打断在「已追加、未 reload」之间会留下半截配置，
   当下不发作、下次 reload 才炸。脚本注册了信号处理，收到即还原。
8. **校验要fail-fast** —— 域名冲突这种「还没动手就该知道」的事，放在起容器之前查，
   别等容器都拉起来了才失败。
9. **SSH 传中文做 `grep`/`sed` 模式会编码失配**（`grep '中文'` 必然匹配不到），
   排查时改用 ASCII 关键字。
10. **测试中断要发 SIGTERM 不是 SIGINT** —— 非交互 shell 的后台进程按 POSIX 规则忽略 SIGINT，
    发 SIGINT 会「测了个寂寞」（脚本其实没被打断）。
11. **bind mount 一个不存在的文件，docker 会创建同名「目录」** ——
    自建 Caddy 时若先把 compose 起起来再写 Caddyfile，`./Caddyfile:/etc/caddy/Caddyfile` 会变成目录，
    Caddy 起不来且原因极难看出。**必须在 `compose up` 之前先把文件落盘**。
12. **写测试脚本时，颜色变量别和业务变量共用名字** —— 我用了 `$D` 表示「暗色」，
    结果被用例里的安装目录变量 `$D` 覆盖，输出直接错乱。颜色变量一律加前缀（`FG_*`）。
13. **`grep "$1"` 遇到以 `-` 开头的模式会把它当选项** —— 校验 `--help` 输出里是否有 `--domain` 时，
    `grep -qF "$1"` 会报「没有模式」而静默失败。要用 `grep -qF -e "$1"`。
14. **本地 `bash -n` 失败也要真的看结果** —— 我把它接在 `&&` 链里、又用 `;` 续了后续命令，
    语法错误没拦住，照样把坏文件传上去了。自检要么 `if bash -n ...; then` 显式断言，要么失败即退出。
15. **`pkill -f <pattern>` 会匹配到你自己的命令行** —— 我用 `pkill -f "s.bind"` 清理一个后台占位进程，
    结果把正在执行这条命令的 shell 自己也杀了，导致后面「恢复 Caddy」那一步没执行、
    **测试机上的生产站点直接下线**（已立刻恢复）。要清后台进程就**记下 PID 再 `kill $PID`**，
    或让 pattern 不可能匹配到自身。
16. **网关的流式（SSE）必须确认反代没有整段缓冲** —— 判据不是「能返回内容」，而是
    **首字节时间明显小于总耗时**（实测 0.58s vs 3.28s）。Caddy 默认即透传；
    **Nginx 必须显式 `proxy_buffering off`**（脚本给出的片段里已带上），否则首字延迟会等于整段生成时间。
17. **断言失败时的提示要带「原始响应」** —— 流式用例最初只报「帧数=0」，看不出是密钥错还是被缓冲。
    改成回显响应体前 120 字后，一眼就看到 `invalid_api_key`（我把 manager 的 `wbk_` 密钥打到了
    agent2api 直连端点）。**只报现象不报证据的断言，会把排查时间翻倍。**

---

## 已知限制

- 只写 **Caddy** 配置；Nginx 用户需自行反代（脚本会把后端地址告诉你）。
- workbuddy-manager 集成需要该容器里存在 `WB_ADMIN_PASSWORD`（否则提示你手动在面板加）。
- 镜像 tag 默认取 Docker Hub 最新版；网络不通时回落到内置的已知可用版本。
- `self` 形态使用 `caddy:2-alpine`；离线环境需提前把该镜像拉好。

---

## 自动化回归套件

改完脚本**别再手工点**，跑这个：

```bash
bash test-install-agent2api.sh                                    # 29 个用例（带域名与流式时全跑）
TEST_DOMAIN=a2a.example.com bash test-install-agent2api.sh        # 加 5 个域名/TLS 用例
EXISTING_DOMAINS="你的站1 你的站2" bash test-install-agent2api.sh # 附带回检生产站未被影响
# 流式用例要指向「已有真实账号」的端点（可与被测机器不是同一台）：
TEST_STREAM_URL="https://你的网关/v1" TEST_API_KEY="wbk_xxx" TEST_MODEL="模型名" \
  bash test-install-agent2api.sh
KEEP=1 bash test-install-agent2api.sh                             # 失败时保留现场
```

- 退出码 = 失败用例数；`INSTALLER=` 可指定被测脚本路径。
- 覆盖：参数校验 10 项、默认值路径与幂等 3 项、**状态与版本管理 4 项**、端口与容器名冲突 2 项、
  域名与 TLS 6 项（含**注册开关**，需 `TEST_DOMAIN`）、**流式 SSE 1 项**（需 `TEST_STREAM_URL`+密钥+模型）、
  卸载 2 项、生产站回检 1 项。
- **它会真的起容器、真的改反代配置**，跑完自动清理；域名用例要求 `TEST_DOMAIN` 已解析到本机。
- 最近一次完整结果：**28 通过 / 0 失败 / 0 跳过**（2026-09-28，Debian 12 测试机）。

### ⚠️ 自动化**未覆盖**、仅手工验证过的部分

诚实列出，避免误以为「套件全绿 = 一切都验过了」：

| 能力 | 状态 | 为什么没进套件 |
| --- | --- | --- |
| **`self` 自建 Caddy 形态**（裸机签证书） | 手工完整验证过（含签发/卸载/释放 80/443） | 需要 80/443 空闲；在有反代的机器上跑会打断现有服务 |
| **中断保护**（SIGTERM 还原 Caddyfile） | 手工用「注入 sleep 造确定性窗口」验证过 | 需要可控的中断时机，套件里不稳定 |
| **`--with-manager` 免粘贴取 Key** | 逻辑与库读取命令手工验证过，**未做端到端** | 会改动生产 manager 的上游列表，不适合放进自动回归 |
| **`--caddy-mode` 强制指定** | 仅验证了 fail-fast 分支 | 正常分支需改动 80/443 归属 |
| **Nginx 提示输出** | 手工验证输出正确 | 需要腾出 80/443 并放非 Caddy 监听 |

> 为什么要这个套件：先前出现过「所有测试都显式传了 `--expose`，于是交互分支的 bug 长期没被发现」。
> 用例必须覆盖**默认值路径**与**异常路径**，不能只测「正确用法」。
