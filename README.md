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

    subgraph 三种运行模式
    C5 -->|selfhost: DNS 直达| VPS[主节点: VPS Full Stack]
    C5 -->|serverless| CloudRun[Cloud Run<br/>• accounts / content-service / billing-service]
    C5 -->|hybrid: selfhost 超时/5xx| CloudRun
    end

    VPS --> VPSDB[(自建 PostgreSQL)]
    CloudRun --> Supa[(Supabase Cloud DB)]
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
| `CONTENT_SERVICE_TOKEN` | Git-backed content-service 的服务间令牌 | 由 Vault 注入 |
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

平台编排器通过 GitHub OIDC → Vault 执行 [`.github/scripts/deploy.sh`](file:///.github/scripts/deploy.sh)：
1. 连接 `https://vault.svc.plus` 动态读取最新 `JWT_SECRET` 与 Git-backed content-service 令牌；
2. 注入 Cloudflare Worker Secrets；
3. 从 GitOps 渲染的 `EdgeRoutingConfig` 读取 Worker 名称、API 主机、路径和上游变量，独立发布三个 Worker。

## UAT API 边界

| Worker | Route | 责任 |
|---|---|---|
| `edge-gateway-auth-uat` | `accounts-cloudflare-uat.onwalk.net/api/auth/*` | 登录、注册、刷新、OAuth 等公开认证入口 |
| `edge-gateway-admin-uat` | `accounts-cloudflare-uat.onwalk.net/api/admin/*` | 管理 API，默认要求 Bearer JWT |
| `edge-gateway-core-uat` | `accounts-cloudflare-uat.onwalk.net/api/*` | 其余 API 兜底，拒绝 auth/admin 保留边界 |

三个入口共享原生 `fetch`、Web Crypto 和故障转移逻辑，不引入重型依赖；每个入口独立打包和部署。

部署不会把域名和 Worker 名称写进运行时代码。`EDGE_GATEWAY_CONFIG_FILE` 必须指向由
`ai-workspace-infra/gitops` 渲染的环境配置；运行模式由 `spec.runtime.mode` 注入，支持
`selfhost`、`serverless` 和 `hybrid`。UAT 的三个 canonical 声明分别位于：

* `resources/svc.plus/uat/cloudflare/selfhost/edge-routing.yaml`
* `resources/svc.plus/uat/cloudflare/serverless/edge-routing.yaml`
* `resources/svc.plus/uat/cloudflare/hybrid/edge-routing.yaml`

`selfhost` 由 DNS 直接指向 VPS Full Stack，因此不部署 edge-gateway Worker；只有
`serverless` 与 `hybrid` 部署三个 API boundary Workers。每次部署只能消费与
`spec.runtime.mode` 一致的声明。

---

## 📄 路由规则与行为

* **公开路由白名单 (Bypass Auth)**:
  * `/api/v1/auth/login`
  * `/api/v1/auth/register`
  * `/api/v1/auth/verify-code`
  * `/api/v1/billing/stripe/webhook`
  * `/api/v1/billing/plans`
  * Git-backed content read APIs (`/api/v1/docs/*`, `/api/v1/blogs/*`, `/api/v1/products/*` 等)
  * `/healthz`
* **受保护路由 (Protected API)**:
  * 自动拦截非法/过期 Bearer Token 并返回 `HTTP 401`，减轻后端计算负担。
* **Git-backed CMS 路由**:
  * `/api/v1/docs/*`、`/api/v1/blogs/*`、`/api/v1/products/*`、`/api/v1/website/*` 和
    `/api/v1/home/*` 通过 `CONTENT_UPSTREAM` 访问 Git-backed `content-service`。
  * Worker 使用 Vault 注入的 `CONTENT_SERVICE_TOKEN` 设置 `X-Service-Token`；浏览器不会
    直接接触该凭据。
* **Serverless service routing**:
  * Accounts API 使用 `FALLBACK_UPSTREAM`，内容 API 使用 `CONTENT_UPSTREAM`，计费 API
    使用 `BILLING_UPSTREAM`。
* **响应头标记**:
  * `X-Upstream-Route: selfhost-primary`（Selfhost 或 hybrid 的主节点响应）
  * `X-Upstream-Route: cloud-run-serverless`（serverless 模式直达 Cloud Run）
  * `X-Upstream-Route: cloud-run-fallback`（hybrid 模式 selfhost 故障时由 Cloud Run 响应）
