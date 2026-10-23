---
title: 在 Linux 服务器上部署 QQ 群 AI 机器人：DSH + NapCat + qq-bridge
date: 2026-10-23 15:30:00
updated: 2026-10-23 15:30:00
tags:
  - QQ机器人
  - DSH
  - NapCat
  - Docker
  - Node.js
categories:
  - 折腾记录
description: 从 Windows 桌面端踩坑到 Linux 服务器落地，完整记录 DSH + NapCat + qq-bridge 的部署、systemd 托管、看门狗与排障。
---

> 目标：让一个 QQ 号在群里像群友一样聊天、能联网查资料、能按人设说话，7×24 跑在云服务器上。
>
> 技术栈：DeepSeek Harness（DSH）+ NapCat（OneBot v11 网关）+ qq-bridge（桥接层）。
>
> 本文按实际踩坑顺序整理，含失败方案与最终取舍。

<!-- more -->

## 1. 最终架构

```
QQ 群 / 私聊
   │
   ▼
NapCat（Docker 容器，无头 QQ + OneBot v11）
   │  HTTP 3000 / WebSocket 3001（127.0.0.1）
   ▼
qq-bridge（Node 进程）
   │  DSH Web API（127.0.0.1:3080）
   ▼
DSH（dsh web，agent 运行时 + 模型调用）
   │
   ▼
DeepSeek API（deepseek-chat / 你的模型）
```

三个进程都在同一台机器上，全部只监听回环地址，公网只开 SSH。

| 组件 | 作用 | 端口 |
|---|---|---|
| NapCat | 登录 QQ、提供 OneBot v11 接口 | 3000 / 3001 / 6099 |
| qq-bridge | 把 QQ 消息变成 agent 会话，把回复发回 QQ | 3100（控制台） |
| DSH | agent 运行时，创建会话、调模型、跑工具 | 3080 |

## 2. 选型：为什么最后没用 SnowLuma

一开始在 Windows 桌面端用的是 **SnowLuma**（注入本机 QQ 客户端），跑通后想搬到 Linux 服务器，结果卡住：

- SnowLuma 的 Linux 包里 `native/` 是 `snowluma-linux-x64.so` —— **仍然是注入库**；
- 服务器上没有 QQ 客户端进程，WebUI 的「进程注入」页永远显示“没有识别到进程”；
- 要在 Linux 上用它，得装 QQ for Linux + Xvfb 虚拟显示，2G 内存根本扛不住。

于是换成 **NapCat（Docker 版）**：容器内自带无头 QQ 和虚拟显示，对外就是标准 OneBot v11。qq-bridge 只依赖 OneBot 接口，一行代码都不用改。

> 结论：需要 Linux 无头部署时，选“自带 QQ 运行时”的 OneBot 网关（NapCat），不要选依赖本机 QQ 进程注入的方案。

## 3. 服务器与基础环境

### 3.1 配置建议

| 项目 | 最低 | 推荐 |
|---|---|---|
| CPU | 2 vCPU | 2–4 vCPU |
| 内存 | 2 GB（必须加 swap） | **4 GB** |
| 磁盘 | 20 GB | 40 GB SSD |
| 带宽 | 3 Mbps | 5 Mbps |

实测：DSH ≈ 350 MB、NapCat ≈ 400–600 MB、qq-bridge ≈ 150 MB。2G 机器一定要开 swap。

### 3.2 系统与依赖

```bash
# Ubuntu 22.04 / 24.04
apt update && apt install -y curl git unzip
curl -fsSL https://deb.nodesource.com/setup_24.x | bash -
apt install -y nodejs
node -v    # >= 24
```

### 3.3 swap（2G 机器必做）

```bash
fallocate -l 2G /swapfile && chmod 600 /swapfile
mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
sysctl vm.swappiness=10
```

### 3.4 独立用户

```bash
adduser --disabled-password --gecos "" qqbot
usermod -aG sudo qqbot      # 可选
```

> 注意：`--disabled-password` 的用户不能用 `sudo`（会要密码但没有），系统级操作回 root 做，应用级操作用 `su - qqbot`。

## 4. 安装 DSH（Web 模式）

### 4.1 全局安装

```bash
npm i -g @deepseek-ai/dsh@0.2.1-rc.2
dsh --version
```

### 4.2 首次启动并生成 profile

```bash
su - qqbot
dsh web --port 3080 --no-open
# 看到 dsh web: http://127.0.0.1:3080/?token=... 后 Ctrl+C（或用另一窗口 pkill）
```

### 4.3 配置模型凭据（关键）

服务器上没有浏览器做 DeepSeek 账号登录，**必须用 API Key**：

```bash
mkdir -p ~/.dsh
printf 'DEEPSEEK_API_KEY=sk-你的key\n' > ~/.dsh/dsh.env
chmod 600 ~/.dsh/dsh.env
```

验证 key：

```bash
set -a; . ~/.dsh/dsh.env; set +a
curl -s -o /dev/null -w "%{http_code}\n" \
  https://api.deepseek.com/user/balance \
  -H "Authorization: Bearer $DEEPSEEK_API_KEY"
# 200 = 有效
```

### 4.4 切换默认 provider

默认是 `deepseek-account`（浏览器登录态），服务器用不了。编辑 `~/.dsh/profiles/web/cordis.patch.yml`，加入：

```yaml
- id: agent-default-model
  name: "@deepseek-ai/dsh-agent-default-model"
  config:
    provider: deepseek-official
    model: deepseek-flash
    reasoningEffort: high
```

> 文件原本只有注释和 `[]` 时，先把 `[]` 删掉再追加，否则 YAML 不合法。

### 4.5 后台启动并验证

```bash
cd ~
set -a; . ~/.dsh/dsh.env; set +a
nohup dsh web --port 3080 --no-open > ~/dsh.log 2>&1 &
sleep 25
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:3080/
# 401 是正常的：DSH 的信任栅栏，说明服务活着
```

## 5. 部署 NapCat

### 5.1 安装 Docker（国内先配镜像加速）

```bash
apt install -y docker.io
systemctl enable --now docker
usermod -aG docker qqbot      # 重新登录生效
```

Docker Hub 在国内经常超时，配镜像：

```bash
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "registry-mirrors": [
    "https://docker.m.daocloud.io",
    "https://docker.1ms.run",
    "https://docker.xuanyuan.me"
  ]
}
EOF
systemctl restart docker
docker info | grep -A4 "Registry Mirrors"
```

### 5.2 启动容器

```bash
su - qqbot
mkdir -p ~/napcat/config ~/napcat/qq

docker run -d --name napcat --restart unless-stopped \
  -p 127.0.0.1:3000:3000 \
  -p 127.0.0.1:3001:3001 \
  -p 127.0.0.1:6099:6099 \
  -v ~/napcat/config:/app/napcat/config \
  -v ~/napcat/qq:/app/.config/QQ \
  -e NAPCAT_UID=$(id -u) -e NAPCAT_GID=$(id -g) \
  mlikiowa/napcat-docker:latest
```

### 5.3 登录 QQ

拿 WebUI token：

```bash
docker logs napcat 2>&1 | grep -iE "token|webui" | tail
cat ~/napcat/config/webui.json
```

本地开隧道（Windows 命令行）：

```bash
ssh -N -L 6099:127.0.0.1:6099 root@你的服务器IP
```

浏览器打开 `http://127.0.0.1:6099/webui`，用 token 登录 → 手机 QQ 扫码。

> 扫码用的是手机 QQ；扫哪个号，服务器上就登哪个号。**同一账号不要同时在别的 PC/协议端登录**，否则会互相踢下线（`KickedOffLine`）。

### 5.4 开启 OneBot 接口

正规做法是在 WebUI 的「网络配置」里新增：

- HTTP Server：`0.0.0.0:3000`，token 自定义
- WebSocket Server：`0.0.0.0:3001`，token 与上面相同

如果 UI 保存后 `onebot11_<QQ号>.json` 里还是空数组（实测会这样），直接改配置文件更可靠：

```bash
cd ~/napcat/config
cp onebot11_*.json onebot11.bak.json
python3 - <<'PY'
import glob, json
f = sorted(glob.glob('/home/qqbot/napcat/config/onebot11_*.json'))[0]
d = json.load(open(f, encoding='utf-8'))
d['network']['httpServers'] = [{
    "name": "http", "enable": True, "host": "0.0.0.0", "port": 3000,
    "token": "你的OneBotToken", "messagePostFormat": "array",
    "enableForcePushEvent": True, "reportSelfMessage": False,
    "debug": False, "heartInterval": 30000
}]
d['network']['websocketServers'] = [{
    "name": "ws", "enable": True, "host": "0.0.0.0", "port": 3001,
    "token": "你的OneBotToken", "messagePostFormat": "array",
    "reportSelfMessage": False, "debug": False, "heartInterval": 30000
}]
json.dump(d, open(f, 'w', encoding='utf-8'), ensure_ascii=False, indent=2)
print("updated", f)
PY

docker restart napcat
sleep 10
```

验证：

```bash
curl -s -H "Authorization: Bearer 你的OneBotToken" \
  http://127.0.0.1:3000/get_login_info
# {"status":"ok","retcode":0,"data":{"user_id":...,"nickname":"..."}}
```

> 注意：`ss -lntp | grep 3000` 看到监听不代表接口可用 —— Docker 端口映射在容器运行时就会占用，必须用 curl 验证。

## 6. 安装 qq-bridge

```bash
cd ~
git clone --depth 1 https://github.com/Derpyu520/qq-bridge.git
cd qq-bridge
```

### 6.1 必打补丁：DSH 0.2.1 不再支持 cwd 提示词变量

qq-bridge 的 preset 是为 DSH 0.2.0 写的，persona 的 suffix 里引用了工作目录变量：

```yaml
suffix: Your working directory is <cwd>.
```

DSH 0.2.1 的提示词渲染器只认已注册变量（model 有、cwd 没有），命中未知变量会直接抛错，表现为每条 QQ 消息都回「agent 处理出错：unknown prompt variable」。

修复（源文件为准，setup 会从源重新生成 patch）：

```bash
sed -i "s#suffix: Your working directory is .*#suffix: ''#" \
  dsh/agent-presets/qq-chat/agent.cordis.yml \
  dsh/agent-presets/qq-chat-v2/agent.cordis.yml
```

### 6.2 安装依赖并写入 DSH 配置

```bash
npm config set registry https://registry.npmmirror.com
npm install --no-audit --no-fund
node scripts/setup-dsh.mjs web
```

`setup-dsh.mjs` 会做三件事：装两个 agent preset、往 profile 里插三个 MCP server（snowluma / snowluma-host / web-search-safe）、注册 qq-mode 控制台。

验证：

```bash
dsh --profile web --dump-config | grep -iE "mcp-snowluma|mcp-web-search|qq-agent-presets"
```

> 一定要用 `qqbot` 用户执行，或者显式 `DSH_HOME=/home/qqbot/.dsh`；用 root 查会读到 `/root/.dsh`，看起来“什么都没装”。

### 6.3 写 config.json

```json
{
  "dsh": {
    "baseUrl": "http://127.0.0.1:3080",
    "provider": "deepseek-official",
    "model": "deepseek-flash",
    "reasoningEffort": "high"
  },
  "snowluma": {
    "wsUrl": "ws://127.0.0.1:3001",
    "httpUrl": "http://127.0.0.1:3000",
    "accessToken": "你的OneBotToken",
    "followDiscoveredEndpoint": false,
    "homeDir": ""
  },
  "ownerQQ": 你的QQ号,
  "agentPreset": "qq-chat",
  "allow": { "private": ["你的QQ号"], "groups": ["你的群号"] },
  "deny": { "private": [], "groups": [] },
  "allowAllWhenEmpty": false,
  "consolePort": 3100
}
```

说明：

- `snowluma.*` 是历史命名，实际指向 NapCat 的 OneBot 端口；
- `followDiscoveredEndpoint: false` 必须关 —— 桥接原本会去读 SnowLuma 的配置文件自愈 WS token，NapCat 没有那个文件；
- `allowAllWhenEmpty: false` + 空白名单 = 谁都不理（fail-closed），先填好群号/QQ 号。

### 6.4 启动并验证

```bash
nohup node src/bridge.js > ~/bridge.log 2>&1 &
sleep 10
tail -n 20 ~/bridge.log
```

正常日志：

```
SnowLuma 已连接：ws://127.0.0.1:3001
机器人昵称: 你的机器人昵称
DSH 已就绪（模式: reserved2）
桥接模式已确定为 reserved2
```

## 7. systemd 化

三个服务都要开机自启、崩溃自拉起。

`/etc/systemd/system/dsh.service`：

```ini
[Unit]
Description=DeepSeek Harness Web
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=qqbot
WorkingDirectory=/home/qqbot
EnvironmentFile=-/home/qqbot/.dsh/dsh.env
ExecStart=/usr/bin/dsh web --port 3080 --no-open
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

`/etc/systemd/system/qq-bridge.service`：

```ini
[Unit]
Description=QQ bridge for DSH
After=network-online.target dsh.service
Wants=network-online.target dsh.service

[Service]
Type=simple
User=qqbot
WorkingDirectory=/home/qqbot/qq-bridge
ExecStart=/usr/bin/node src/bridge.js
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

NapCat 由 Docker 托管，`--restart unless-stopped` 已经够用，不需要额外 unit。

```bash
systemctl daemon-reload
systemctl enable --now dsh qq-bridge
systemctl status dsh qq-bridge --no-pager
```

> 顺序很重要：NapCat 先起（有 QQ 登录态），DSH 其次，桥接最后。桥接 WS 不会自己无限重试，**OneBot 端口晚于桥接起来时，需要重启一次桥接**。

## 8. 看门狗：掉线自动恢复

新号 + 机房 IP 很容易被风控踢下线（日志 `KickedOffLine`）。写一个每分钟自检的脚本：

`/home/qqbot/qq-watchdog.sh`：

```bash
#!/usr/bin/env bash
set -u

TOKEN="${NAPCAT_TOKEN:-你的OneBotToken}"
LOG="/home/qqbot/qq-watchdog.log"
INTERVAL=60
RESTART_GAP=600
NOTIFY_URL="${NOTIFY_URL:-}"

log() { echo "$(date '+%F %T') $*" >> "$LOG"; }
notify() {
  [ -z "$NOTIFY_URL" ] && return 0
  curl -fsS -m 5 -X POST -H 'Content-Type: application/json' \
    --data "{\"text\":\"$1\"}" "$NOTIFY_URL" >/dev/null 2>&1 || true
}
qq_online() {
  local body
  body=$(curl -fsS -m 6 -H "Authorization: Bearer $TOKEN" \
    http://127.0.0.1:3000/get_login_info 2>/dev/null) || return 1
  printf '%s' "$body" | grep -q '"retcode":0' && printf '%s' "$body" | grep -q '"user_id"'
}
bridge_ok() {
  local t
  t=$(cat /home/qqbot/qq-bridge/state/console-token 2>/dev/null) || return 1
  curl -fsS -m 6 "http://127.0.0.1:3100/api/status?token=$t" 2>/dev/null \
    | grep -qE '"accountOnline":[[:space:]]*true'
}

last=0
while true; do
  if qq_online; then
    log "OK QQ 在线"
  else
    now=$(date +%s)
    if [ $((now - last)) -ge "$RESTART_GAP" ]; then
      last=$now
      log "WARN QQ 离线，重启 napcat"
      docker restart napcat >/dev/null 2>&1
      sleep 25
      if qq_online; then
        log "INFO 重启后恢复在线"; notify "QQ 掉线，已自动恢复"
      else
        log "ALERT 仍离线，需要扫码"; notify "QQ 掉线，需要扫码"
      fi
    fi
  fi

  if qq_online && ! bridge_ok; then
    log "WARN 桥接未连接，重启桥接"
    pkill -f "src/bridge.js" >/dev/null 2>&1 || true
    sleep 2
    ( cd /home/qqbot/qq-bridge && nohup node src/bridge.js > /home/qqbot/bridge.log 2>&1 & )
  fi

  sleep "$INTERVAL"
done
```

`/etc/systemd/system/qq-watchdog.service`：

```ini
[Unit]
Description=QQ stack watchdog
After=docker.service network-online.target

[Service]
Type=simple
User=qqbot
Environment=NAPCAT_TOKEN=你的OneBotToken
ExecStart=/home/qqbot/qq-watchdog.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload && systemctl enable --now qq-watchdog
```

**能做的**：容器挂了拉起、掉线重启 NapCat（10 分钟最多一次）、桥接断连重启、webhook 通知。
**不能做的**：代替你扫码。`KickedOffLine` 之后必须人工在 6099 重新登录。

## 9. 人设配置

qq-bridge 的提示词分两层：

| 层 | 位置 | 生效 |
|---|---|---|
| 角色层（性格/语气） | `~/qq-bridge/roles/*.md` | 保存即生效，无需重启 |
| 预设层（安全规则） | `dsh/agent-presets/qq-chat-v2/agent.cordis.yml` | 需重启 DSH |

角色文件示例：

```markdown
# 角色：你的机器人昵称

你是群里的一只普通网友，不是客服、不是助手。

## 性格
- 沙雕：爱接梗、爱起哄，但读得懂空气
- 一点点毒舌：只损熟人玩笑，点到为止
- 懒：能一句说完绝不说三句

## 说话方式
- 一次 1~2 句，最多 3 句
- 不用 Markdown、不用列表、不用敬语
- 会用“草”“？”“行吧”“6”这类口语

## 禁止
- 不自称 AI，不提模型名
- 不汇报“已发送”“收到指令”
- 不写小作文，不暴露本地路径
```

切换角色：改 `~/qq-bridge/state/current-role.json`，或在 `3100` 控制台「人设与角色」里选。

## 10. 联网搜索

`setup-dsh` 已经装了 `mcp-web-search-safe`，提供 `web_search` / `web_fetch`，凭据读 `DEEPSEEK_API_KEY`（DSH 启动时注入，子进程继承）。

触发方式：问题里明确说「联网查 / 搜一下 / 去 B 站搜」成功率最高。实测 agent 会打开搜索结果再抓正文。

想要更稳：

```json
"webSearch": { "provider": "auto", "maxResults": 12 }
```

游戏攻略这类内容，建议在提问时指定站点（小黑盒 / B站 / 米游社 / NGA），否则容易抓到广告站。

## 11. 踩坑清单

| 坑 | 现象 | 解决 |
|---|---|---|
| SnowLuma Linux 仍需注入 | 「进程注入」页找不到进程 | 换 NapCat Docker |
| DSH 桌面端端口随机 | 桥接 baseUrl 失效 | 服务器固定 `--port 3080`；桌面端用端口发现脚本 |
| cwd 变量被移除 | 每条消息回「agent 处理出错」 | 改 preset 的 suffix |
| 把 Tracking ID 当 API Key | `api key invalid` | 在平台「创建 API key」，取 `sk-` 开头 32 位 |
| 用 root 查 `dsh --dump-config` | 看不到 qq 相关配置 | 切 qqbot 或设 `DSH_HOME` |
| NapCat UI 保存不写盘 | `onebot11_*.json` 仍为空 | 直接改 JSON 再 restart |
| Docker 端口映射迷惑 | `ss` 有监听但 curl 不通 | 以 curl `get_login_info` 为准 |
| 同账号多端登录 | `KickedOffLine` | 关掉其他端，重新扫码 |
| 新号 + 机房 IP | 频繁掉线 | 换老号 / 养号 / 接受扫码 |
| 桥接晚于 OneBot 启动 | 一直 `Received network error` | OneBot 就绪后重启桥接 |
| 编码乱码 | 回复是 `锟斤拷` 之类 | 统一 UTF-8，`tail` 时确认终端编码 |

## 12. 风险与成本

- **QQ 风控**：第三方协议登录有被踢、被限制、甚至封号的风险，建议用小号，不要用主号。
- **机房 IP**：数据中心 IP 比家宽更容易触发设备验证。
- **登录态**：掉线后需要扫码，无法完全自动化。
- **成本**：2C4G 轻量云服务器约 ¥30–80/月；模型费用另算。
- **合规**：遵守 QQ 用户协议与相关平台规则，本文仅记录技术实现。

## 13. 常用排障命令

```bash
# 容器
docker ps
docker logs napcat --tail 50
docker restart napcat

# QQ 在线
curl -s -H "Authorization: Bearer 你的OneBotToken" \
  http://127.0.0.1:3000/get_login_info

# 桥接状态
curl -s "http://127.0.0.1:3100/api/status?token=$(cat ~/qq-bridge/state/console-token)"

# 日志
tail -f /home/qqbot/bridge.log
tail -f /home/qqbot/qq-watchdog.log

# 内存
free -h
journalctl -k | grep -iE "oom|killed process"
```

## 14. 小结

这套方案的三个关键点：

1. **网关选型**：Linux 无头环境要用自带 QQ 运行时的 OneBot 网关（NapCat），不要选依赖本机 QQ 注入的方案；
2. **版本适配**：DSH 升级会改提示词变量、端口策略，桥接这类第三方插件要跟着打补丁；
3. **运维兜底**：systemd + 看门狗 + 掉线告警，比追求“永不掉线”更现实。

如果你也在做类似的事，欢迎交流踩坑经验。

