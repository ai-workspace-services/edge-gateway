# Edge Gateway (`edge-gateway.svc.plus`)

> **Cloudflare Worker 智能边缘网关与流量调度器**  
> 统一域名接入 · 边缘 JWT 验签 · GTM 实时故障转移 · CORS 跨域秒回 · 统一密钥拉取自 `vault.svc.plus`

---

## 📌 项目架构 (Architecture)

```mermaid
graph TD
    User[客户端 / 浏览器] -->|HTTPS 请求| Edge[Cloudflare API boundary Workers]

    subgraph 边缘层 (Cloudflare Edge - 0ms 冷启动)
        Edge --> C1[1. API auth / admin / core boundary]
        C1 --> C2[2. OPTIONS 预检秒级响应 204]
        C2 --> C3[3. 边缘原生 Web Crypto JWT 验签]
        C3 --> C4[4. 租户 ID / User ID 请求头注入]
        C4 --> C5{5. 智能上游探测与熔断}
    end

    subgraph 双轨计算后端
    C5 -->|正常状态: 主路由 (99% 流量)| VPS[主节点: VPS (Docker Compose)<br/>• accounts / billing-service]
    C5 -->|VPS 超时/5xx: 备用路由| CloudRun[备用节点: GCP Cloud Run<br/>• 缩容至 0 实例，毫秒级拉起]
    end

    VPS --> Supa[(Supabase Cloud PostgreSQL)]
    CloudRun --> Supa
```

---

## 🔐 密钥管理规范 (Secrets Management)

本项目**严禁**在代码库中提交任何明文密钥。所有生产与测试凭据统一托管在 **HashiCorp Vault (`https://vault.svc.plus`)**。

### Vault 路径结构：`secret/data/edge-gateway`

| 键名 (Key) | 说明 | 示例 |
| :--- | :--- | :--- |
| `JWT_SECRET` | 与 Go 后端 `accounts` 相同的 JWT 验签密钥 | `s3cr3t_256bit_key...` |
| `PRIMARY_UPSTREAM` | 主节点 VPS API 地址 | `https://vps-api.svc.plus` |
| `FALLBACK_UPSTREAM` | 备用节点 GCP Cloud Run 地址 | `https://accounts-service-uc.a.run.app` |
| `CLOUDFLARE_API_TOKEN` | 用于部署 Worker 的 Cloudflare Token | `cf_pat_xxxx` |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare 账户 ID | `a1b2c3d4...` |

---

## 🚀 本地开发与快速上手 (Quick Start)

### 1. 安装依赖
```bash
npm install
```

### 2. 从 `vault.svc.plus` 自动同步本地环境变量
```bash
export VAULT_TOKEN="s.your_vault_token"
./scripts/fetch_secrets.sh .env.local
```

### 3. 本地启动开发服务器
```bash
npm run dev
```

### 4. 运行单元测试与类型检查
```bash
npm test
npm run typecheck
```

---

## 🚢 CI/CD 自动化部署

推送至 `main` 分支时，GitHub Actions 会自动执行 [`.github/scripts/deploy.sh`](file:///.github/scripts/deploy.sh)：
1. 连接 `https://vault.svc.plus` 动态读取最新 `JWT_SECRET`；
2. 注入 Cloudflare Worker Secrets；
3. 独立发布 `frontend-api-auth-uat`、`frontend-api-admin-uat`、`frontend-api-core-uat` 三个 Worker。

## UAT API 边界

| Worker | Route | 责任 |
|---|---|---|
| `frontend-api-auth-uat` | `console-uat.onwalk.net/api/auth/*`、`/api/v1/auth/*` | 登录、注册、刷新、OAuth 等公开认证入口 |
| `frontend-api-admin-uat` | `console-uat.onwalk.net/api/admin/*` | 管理 API，默认要求 Bearer JWT |
| `frontend-api-core-uat` | `console-uat.onwalk.net/api/*` | 其余 API 兜底，拒绝 auth/admin 保留边界 |

三个入口共享原生 `fetch`、Web Crypto 和故障转移逻辑，不引入重型依赖；每个入口独立打包和部署。

---

## 📄 路由规则与行为

* **公开路由白名单 (Bypass Auth)**:
  * `/api/v1/auth/login`
  * `/api/v1/auth/register`
  * `/api/v1/auth/verify-code`
  * `/api/v1/billing/stripe/webhook`
  * `/healthz`
* **受保护路由 (Protected API)**:
  * 自动拦截非法/过期 Bearer Token 并返回 `HTTP 401`，减轻后端计算负担。
* **响应头标记**:
  * `X-Upstream-Route: vps-primary`（由主 VPS 节点响应）
  * `X-Upstream-Route: cloud-run-fallback`（主节点故障时由 Cloud Run 响应）
