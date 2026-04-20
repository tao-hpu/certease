# certease

> English version: [README.en.md](README.en.md)
>
> 一个 bash 写的 ACME 编排工具，包装 `acme.sh` + `certbot` + `nginx`，
> 让异构 Linux 服务器上的 SSL 证书轮换真正自动化、可见、可恢复。
> 不替代任何 ACME 客户端，只修复它们周围那层**在生产环境里真正把证书搞挂**的运维工程。

```
sudo ./install.sh
certease install      # 给每个域名接上 cron + logging + deploy hook
certease status       # 一屏对齐的证书表；退出码 0/1/2，cron 友好
certease doctor       # ~15 项健康检查；逐行 [OK]/[WARN]/[FAIL]
certease renew        # 续签到期域名；限流自动切 fallback CA
```

运行时依赖只有一台标准 nginx 主机已经具备的东西：`bash 4+`、`openssl`、
`awk`、`sed`、`crontab`、`find`、`date`。不装 Python、不装 Node、不装 Docker。

---

## 为什么存在（起源故事）

2026-04-20，我花了一整天 debug 四台异构服务器的 SSL 证书轮换：

- 一台裸 `nginx`（std flavor，`/etc/nginx` 标准布局）
- 一台 LNMP 一键包（`/usr/local/nginx` 非标路径）
- 两台宝塔面板（BT flavor，`/www/server/panel/vhost/…` 自成一派）
- 一台海外 AWS 节点（纯 certbot + systemd-timer）

**每台机器都有自己独特的坑**：

- **裸 nginx 那台**：跟 Let's Encrypt API 之间的出站网络偶发瞬态错误
- **宝塔那两台**：BT 面板把 cert 目录命名为 vhost 里 `server_name` 的**第一个 token**，
  而不是 acme.sh 的 `Le_Domain`；以及 nginx 的 `location ^~` 在有 regex location 时的优先级坑
- **LNMP 那台**：`nginx` 二进制不在 `$PATH` 里，cron 跑起来 deploy hook 直接 `command not found`
- **AWS 那台**：入口 `server` 块里写了 `return 301 https://...`，在 rewrite phase 先于
  `location /.well-known/acme-challenge/` 执行，把 HTTP-01 challenge 全 301 掉了

用 AI 每次 ad-hoc 修很爽，但每次都在**重新推理同样的事**。核心问题是：
**AI 第一次发现问题、探索解法 = 高价值；第二次、第三次遇到同样问题还让 AI 从头推
= 浪费时间 + 大约 20% 概率推偏**。每个模型都有它"薛定谔的知识状态"——它今天答对了，
不代表明天同一个 prompt 还会答对。

所以这一天结束的时候，我做了一个决定：**把所有踩过的坑沉淀为一个可克隆的项目**。
下次接手新服务器的时候，`git clone && bash install.sh`，所有预防措施一次到位。
这就是 `certease`。

它不是一个炫技项目。它是一份"AI 这一年帮我搞懂的东西，我不想再让 AI 重新搞一遍"
的**知识物化**。

---

## 什么场景适合用

**适合**：

- 混合了宝塔 / LNMP / 裸 nginx 的**异构服务器运维**
- 代运维团队：接手不是自己搭的老服务器
- 中小公司自有机房 + 少量云机的混合 fleet
- 任何一个"SSL 证书是每年续签的定时炸弹"的场景

**不适合**：

- 纯 Docker / K8s 工作负载（用 cert-manager）
- 纯云上 ACM / Cloudflare 证书（用云厂商原生方案）
- 单机博客一两个域名（直接 certbot 就够了，这里是 over-engineering）

---

## 它做什么（具体）

- **`install.sh`**：一键装 certease 本体；**不负责**装 `acme.sh` —— 上游已经装好才能用
- **`certease install`**：给每个 acme.sh 域名批量配好 `--reloadcmd` → 我们的 hook，
  修正 cron 的 `>/dev/null`、补上 `LOG_FILE=`、自动识别 nginx flavor 并把证书路径
  映射到该 flavor 的规范位置
- **`certease doctor`**：15+ 项健康检查一屏输出。cron 是否有 acme.sh 行？`LOG_FILE` 是否
  设置了？每个域名的 `Le_ReloadCmd` 是否写了？`.cer` 文件的 mtime 是否超过 90 天？
  每个 `ssl_certificate` 路径是否真在盘上存在？`nginx -t` 是否通过？...
- **`certease status`**：所有证书一张对齐表，按过期天数排，`WARN_DAYS`/`CRITICAL_DAYS`
  阈值触发退出码 1/2，可以直接 `certease status || notify.sh` 接告警
- **`certease renew [-d DOMAIN] [--force]`**：手动续签；rate-limit 自动切 fallback CA

---

## 它不是什么（避免误解）

- **不是 ACME 客户端的替代品**。它调用 `acme.sh` / `certbot`，不自己走 ACME 协议
- **不做 DNS-01**。想用 DNS-01 请用 `acme.sh` 原生的 dnsapi 插件，certease 会在下次
  run 的时候自动接管那些域名
- **不管证书内容本身**。SAN / 续签策略 / CA 选择都交给上游客户端
- **不装 acme.sh / certbot**。如果它们不在系统上，certease 会报错退出；安装 ACME 客户端
  本身不是 certease 的职责

---

## 差异化卖点

| 特性 | 别的工具 | certease |
|---|---|---|
| 自动识别 nginx flavor | 多半要手工配 | `std` / `lnmp` / `bt` 自动检测，路径自动映射 |
| 宝塔（BT）面板兼容 | 几乎没有 | 解析 vhost `server_name` 推导 BT 子目录名 |
| Fallback CA | 通常要自己写脚本 | ZeroSSL 限流 → 自动换 LE 重试一次 |
| Observability | 多半只有一行日志 | `doctor` 命令 + `hook.log` + `renew-<domain>-<ts>.log` |
| 依赖 | Python / Node / Go | 纯 bash，零运行时依赖 |

---

## 快速开始

```sh
# 克隆到任意位置；/opt/certease 是惯例但不强制
git clone <repo> /opt/certease
cd /opt/certease && sudo ./install.sh   # 把 bin/certease 软链到 /usr/local/bin

# 先 dry-run 看计划，不写任何东西
sudo certease install --dry-run

# 真跑
sudo certease install

# 看世界现在的状态
certease status
certease doctor
```

首次 `install` 之后也会生成 `/etc/certease.conf`，里面所有 key 都可选，
默认值对大多数主机是对的。

---

## 子命令

### `certease install [--dry-run]`

幂等启动。每次运行：

1. 检测 `acme.sh` home、`certbot` 是否存在、nginx flavor
2. 确保有 `acme.sh --cron` 的 cron 条目，且输出被重定向到 `$LOG_DIR/certease-cron.log`（**不是** `/dev/null`）
3. `account.conf` 里启用 `LOG_FILE` 和 `LOG_LEVEL=1`
4. 给每个 acme.sh 域名跑 `acme.sh --install-cert`，`--reloadcmd` 指向 `hooks/reload-cert.sh`，`--fullchain-file` / `--key-file` 指到当前 flavor 的规范 SSL 目录
5. 从 example 安装 `/etc/certease.conf`（**不会覆盖**已有文件）
6. 如果设置了 `ACCOUNT_EMAIL`，同步到 acme.sh + certbot 两边
7. 打一份"这次做了什么、什么本来就是对的"的 summary

退出码：`0` 正常，`2` 致命错误（如 acme.sh 找不到）。

### `certease status`

一张对齐的表格，覆盖 acme.sh 和 certbot 两边：

```
TOOL     DOMAIN                           CA                 NOT_AFTER     DAYS  STATUS
acme.sh  example.com                      LE E7              2026-05-12    22    WARN
acme.sh  api.example.com                  LE E7              2026-06-19    60    OK
certbot  www.example.org                  LE E8              2026-06-06    47    OK
```

对 cron 友好的退出码：

| 退出码 | 含义 |
|------|------|
| `0` | 所有证书都 ≥ `WARN_DAYS` 外 |
| `1` | 至少一张证书进入 `WARN_DAYS` |
| `2` | 至少一张证书进入 `CRITICAL_DAYS` |

```sh
certease status || /etc/certease/notify.sh
```

### `certease doctor`

一批不变量检查，逐行 `[OK]` / `[WARN]` / `[FAIL]`：

- acme.sh 的 cron 条目存在，且未被重定向到 `/dev/null`
- acme.sh 的 `LOG_FILE` 在 `account.conf` 里真的设了
- 每个域名的 `Le_ReloadCmd` 非空
- 每个域名的 `Le_NextRenewTime` 没跑到过去
- `.cer` 文件 mtime 没超过 90 天
- 每条 nginx `ssl_certificate` 指向的路径真的存在于盘上
- `nginx -t` 通过
- 没有"孤儿" acme.sh 目录（没有 `.cer`）
- `certbot.timer` 激活
- 每个 `/etc/letsencrypt/renewal/*.conf` 有对应的 live cert
- certbot 账号注册了邮箱

退出码约定和 `status` 相同。

### `certease renew [--force] [-d DOMAIN]`

遍历 acme.sh 域名。只续签 `Le_NextRenewTime` 已过的（或用 `--force` 强制全部）。
每次 run 的日志放到 `$LOG_DIR/renew-<domain>-<timestamp>.log`。
不碰 certbot —— 它有自己的 systemd timer。

```sh
sudo certease renew                    # 只续到期的
sudo certease renew --force            # 全部强制续
sudo certease renew -d example.com     # 只续这一个
```

---

## Fallback CA（自动切 CA 续签）

续签失败有时候换一个 CA 就能过。典型情况：

- ZeroSSL 限流 `retryafter=86400`（等 24 小时）
- Let's Encrypt ACME 端点瞬态 5xx
- Buypass `serverInternal`

`certease renew` 识别这些错误，**自动换一个 CA 重试一次**：

```sh
# /etc/certease.conf
FALLBACK_CA="letsencrypt"     # 默认
# FALLBACK_CA=""              # 关闭自动 fallback
```

接受的值就是 `acme.sh --server <value>` 认识的 —— `letsencrypt`、`zerossl`、
`buypass`、`google`。

**fallback 不能修的**：DNS-01 配错、HTTP-01 webroot 返回 404、域名没解析到本机、
deploy 之后 `nginx -t` 挂 —— 这些是配置问题，换 CA 只会用同样的错更慢地失败一次。
`certease renew` 会识别并快速失败。

---

## Nginx flavor 矩阵

| Flavor | 检测依据 | Cert deploy 目录 | 单域名路径 | 注意 |
|---|---|---|---|---|
| `std` | `/etc/nginx` 存在 | `/etc/nginx/ssl` | `/etc/nginx/ssl/<domain>.crt` + `.key` | 无 |
| `lnmp` | `/usr/local/nginx/conf/vhost` 存在 | `/usr/local/nginx/conf/ssl` | `/usr/local/nginx/conf/ssl/<domain>.crt` + `.key` | `nginx` 二进制不在 cron 的 PATH 里 |
| `bt` | `/www/server/panel/vhost/nginx` 存在 | `/www/server/panel/vhost/cert` | `.../cert/<NAME>/fullchain.pem` + `privkey.pem` | `<NAME>` = vhost 里 `server_name` 的第一个 token |

检测按上面的顺序**第一命中**。同时装了 BT 和 `/etc/nginx` 的机器按 `bt` 处理。
`SSL_DEPLOY_DIR` 在 `/etc/certease.conf` 里可以硬覆盖。

### 宝塔（BT）面板的那个坑

在 BT 主机上，`/www/server/panel/vhost/cert/<子目录>/` 的子目录名 = 对应
nginx vhost 里 `server_name` 的**第一个 token**，不一定是 acme.sh 里注册的
`Le_Domain`。实际例子：

```
acme.sh 域名:     example.com
vhost 文件:       /www/server/panel/vhost/nginx/www.example.com.conf
vhost 指令:       server_name www.example.com example.com;
BT 证书目录:      /www/server/panel/vhost/cert/www.example.com/
                                              ^^^^^^^^^^^^^^^ 不是 "example.com"
```

把证书写到 `.../cert/example.com/` 会**静默无效**。certease 通过
`lib/nginx_flavors.sh` 里的 `bt_resolve_cert_dir()` 自动解决 —— 扫 vhost 文件，
找 `ssl_certificate` 指向 BT tree 的那条、其 `server_name` 列表又包含目标域名的
vhost，用那个 BT 子目录名。

---

## Troubleshooting

### "续签成功了，但 nginx 还是在发老证"

几乎一定是以下之一：

- **`Le_ReloadCmd` 空的**。`certease doctor` 会标出来，`certease install` 修掉
- **BT 主机上，证书写到了 `.../cert/<Le_Domain>/`，但 nginx 读 `.../cert/<first_server_name>/`**。
  见上面的 BT 坑。升级到当前版本 —— `bt_resolve_cert_dir()` 已处理
- **进程根本没 reload**。看 `$LOG_DIR/hook.log` 找 `nginx reload failed:`

诊断：

```sh
# 1. nginx 到底从哪读证书？
nginx -T 2>/dev/null | grep -E 'ssl_certificate\s' | sort -u

# 2. acme.sh 最后把证书写到哪了？
openssl x509 -in /path/from/step/1 -noout -dates
stat ~/.acme.sh/<domain>_ecc/fullchain.cer

# 如果 mtime 差了，deploy hook 没拷对地方。
```

### "续签报 404 on /.well-known/acme-challenge/"

可能原因：

- vhost 里有 regex `location ~ \.well-known` 截胡了。regex location 优先级高于 prefix。
  改成 `location ^~ /.well-known/acme-challenge/` 强制 prefix 优先
- HTTP 被整体 301 到 HTTPS，在 challenge path 匹配之前就重定向了。把
  `/.well-known/acme-challenge/` 从 301 里豁免出来
- **入口 server 块里有 `return 301`**：`return` 在 nginx 的 rewrite phase 执行，
  **早于** location matching。即使你写了 `location ^~ /.well-known/...`
  也会被 `return 301` 先 301 掉。解决：把 `return 301` 包进 `location / { ... }`
  里，降级到 location 匹配之后
- BT 主机：HTTP-01 webroot 往往是 `/www/wwwroot/java_node_ssl`（BT 的 Lua handler 服务的），
  不是每个 vhost 自己的 webroot

### "acme.sh 说 'Domain is not in issued list'"

通常是 `--home` 不一致：

```sh
# 错：用了调用者的 $HOME
acme.sh --renew -d example.com

# 对：明确指定当初签发时的 home
/root/.acme.sh/acme.sh --home /root/.acme.sh --renew -d example.com
```

`certease` 内部一律显式传 `--home`。在 certease 之外踩这个坑的话，
先确认 `~/.acme.sh/<domain>/<domain>.conf` 真的存在再续签。

### "ZeroSSL 限流，retry-after 24h"

`/etc/certease.conf` 设 `FALLBACK_CA="letsencrypt"`（默认就是），
然后 `certease renew`，这一次用 LE，主 CA 配置不动。详见上面 Fallback CA 段。

### "Wildcard 证书续签失败"

HTTP-01 **不能**验泛域名 —— LE 规定泛域名必须 DNS-01。选项：

- **切 DNS-01**：`acme.sh --issue -d '*.example.com' --dns dns_cf` 这一类。
  certease 之后会像普通域名一样接管续签
- **拆成每个实际 hostname 一张证**。HTTP-01 能用，`certease install` 给每个都接好 hook

### "`--issue --force` 跑完 nginx 还在用旧证"

`acme.sh --issue --force` **不会**调用你在 `--install-cert` 时设置的 `--reloadcmd`，
也不会拷贝到 deploy 目录。需要再显式跑一次：

```sh
acme.sh --home /root/.acme.sh --install-cert -d example.com --ecc \
  --fullchain-file /etc/nginx/ssl/example.com.crt \
  --key-file       /etc/nginx/ssl/example.com.key \
  --reloadcmd      /opt/certease/hooks/reload-cert.sh
```

或者直接 `certease renew -d example.com` —— certease 的续签路径永远走 hook。

---

## 配置

`/etc/certease.conf`，以 bash 源文件方式 source。所有 key 都可选；
见 `config/certease.conf.example` 的完整注释模板：

```sh
SSL_DEPLOY_DIR=""          # 覆盖 nginx flavor 检测
NGINX_RELOAD_CMD=""        # 覆盖 systemctl-vs-binary reload 选择
LOG_DIR="/var/log/certease"
WARN_DAYS=30
CRITICAL_DAYS=14
ALERT_WEBHOOK=""           # hook 失败时 POST JSON
ACCOUNT_EMAIL=""           # install 时同步到 acme.sh + certbot
FALLBACK_CA="letsencrypt"  # "" 关闭自动 fallback
```

---

## Design

### 为什么只用 bash

每台 nginx 机器都已经有 bash、openssl、crontab。加 Python 或 Node 会把
支持矩阵乘一个数量级：一台 CentOS 7 + Python 3.6，一台 Debian 12 + Python 3.11，
一台只有 `python` (2.7) 在 PATH 里的老祖宗。Bash 在这些机器上行为一致。

### 为什么包装 acme.sh 而不是重写

`acme.sh` 是一个成熟、久经考验的 ACME 实现，支持几十家 DNS provider，
跟各大 CA 的各种奇怪毛病都磨合过。重写是多年工程、零用户收益。
真正的痛点是**运维工程层** —— 默认配置不好、容易忘掉的初始化步骤、缺少可见性。
`certease` 修这一层，把 ACME 协议本身留给已经做得很好的代码。

### 为什么是 `/etc/certease.conf`

声明式的 per-host override，能跨 certease 升级存活。文件被每个子命令 source，
所以改完下一次调用就生效，不用碰 certease 安装目录。Ansible / Puppet / cloud-init
可以直接投递这个文件，`certease install` 下次跑会自动 pick up。

### AI 沉淀哲学

这个项目就是一次"**让 AI 辅助的知识从一次性 chat 落盘为可克隆的工具**"的试验。
AI 第一次帮你发现 BT 面板的 cert subdir 坑、发现 `return 301` 吃 acme-challenge
的坑 —— 这非常值。但如果你下个季度换台机器又让 AI 现场重新推一遍，那是在反复
为同一份知识付费，而且每次还有出错概率。**沉淀是 AI 辅助工程的必修课**。

---

## Development

- 每个文件 `bash -n` 通过
- 目标 `bash 4+`；不用 bash 5 独有的特性
- 全局 `set -euo pipefail`
- 脚本里**不**用 `sudo`；要 root 直接以 root 跑
- 所有面向用户的文案用英文（代码注释 & README 中文版除外）

Smoke test（非 root 也能跑）：

```sh
bash -c '. lib/common.sh; . lib/detect.sh; detect_acme_home; detect_nginx_flavor'
./bin/certease --help
./bin/certease install --dry-run
```

项目布局：

```
bin/certease           — CLI 入口
lib/
  common.sh            — logging / 配置加载 / 日期助手
  detect.sh            — acme.sh / certbot / nginx 检测
  nginx_flavors.sh     — flavor-aware 路径 + bt_resolve_cert_dir()
  install_cron.sh      — cron + logging + email 确保
  install_hook.sh      — 所有域名的 deploy-hook 接线
  status.sh            — `status` 子命令
hooks/reload-cert.sh   — acme.sh deploy hook（续签时调用）
config/certease.conf.example
docs/machines.md       — 示例部署场景（flavor 对照）
docs/postmortem-deploy-20260420.md  — 首次部署复盘（5 个工具 bug + 3 个基础设施问题）
```

---

## Contributing

欢迎 PR。基本规则：

- 保持 bash 纯度。不要引入 Python / Node / Go
- 新文件开头必须 `set -euo pipefail`，用 `lib/common.sh` 里的 logging 助手
- `doctor` 新加的检查必须是**无状态 + 幂等**
- 用户可见的改动要在 `CHANGELOG.md` 加一行
- `bash -n` 必须过；`shellcheck` 应该干净（实在不能就逐行写豁免注释说明原因）

Bug 报告附上 `certease doctor` 输出的回复最快。

---

## License

MIT — 见 `LICENSE`。
