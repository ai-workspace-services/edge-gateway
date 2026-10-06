# Edge Gateway (`edge-gateway.svc.plus`)

> **Cloudflare Worker 智能边缘网关与流量调度器**  
> 统一域名接入 · 边缘 JWT 验签 · GTM 实时故障转移 · CORS 跨域秒回 · 统一密钥拉取自 `vault.svc.plus`

Edge Gateway 是一个超轻量级的专属应用网关：核心 handler 基于标准 Fetch API 和 Web Crypto，可运行在 Cloudflare Worker，也可嵌入 Node.js 20+ 或 Deno 1.37+；每个 Worker 压缩后 bundle 严格小于 `1 MiB`。完整的架构、运行时兼容性、Git-backed CMS、环境变量和部署说明见 [`docs/edge-gateway.md`](docs/edge-gateway.md)。

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
    C5 -->|selfhost: Worker 选择主机| VPS[主节点: VPS Full Stack]
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
| Edge Gateway Router Core<br>`edge-gateway-core-uat` | `accounts-cloudflare-uat.onwalk.net` Custom Domain owner；`/api/*` | Accounts 入口 owner 和其余 API 兜底，拒绝 auth/admin 保留边界 |

三个入口共享原生 `fetch`、Web Crypto 和故障转移逻辑，不引入重型依赖；每个入口独立打包和部署。

部署不会把域名和 Worker 名称写进运行时代码。`EDGE_GATEWAY_CONFIG_FILE` 必须指向由
`ai-workspace-infra/gitops` 渲染的环境配置；运行模式由 `spec.runtime.mode` 注入，支持
`selfhost`、`serverless` 和 `hybrid`。UAT 的三个 canonical 声明分别位于：

* `topology/uat/selfhost/runtime-topology.yaml`
* `topology/uat/serverless/runtime-topology.yaml`
* `topology/uat/hybrid/runtime-topology.yaml`

三种模式都保留 API boundary Workers；`selfhost` 只访问主机，`serverless` 只访问 Cloud Run，
`hybrid` 优先访问主机，超时或 5xx 时仅允许 GET/HEAD/OPTIONS 回退。POST/PUT/PATCH/DELETE
不会跨数据库重试。Accounts 和 Billing 使用同一个运行模式及各自上游。

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

## 发布时覆盖与生产入口

手动触发 `deploy.yml`，`deploy=false` 生成不读取凭据的路由计划；`deploy=true` 发布并验证入口。

| 输入 | 用途 |
|---|---|
| `environment` | `prod` / `uat` |
| `runtime_mode` | `gitops` / `serverless` / `selfhost` / `hybrid` |
| `primary_upstream`, `fallback_upstream` | Accounts 两个独立 HTTPS origin |
| `billing_primary_upstream`, `billing_fallback_upstream` | Billing 两个独立 HTTPS origin |
| `timeout_ms` | 默认 2500；覆盖范围 100–10000 |
| `gitops_ref` | 已审查 GitOps commit SHA；Worker 名称、入口和路由取自声明 |
| `cutover_run_id` | 改变数据库写入入口时必须提供完整业务核对回执 |

切换回执由 Toolkit 成功的数据操作流水线产生，绑定环境、准确上游、52 个业务表行数和
按 email 对齐的摘要、用户数量、PROD Proxy UUID、最新原生 schema 及单写者隔离窗口。
身份域单独导入或只有来源侧摘要不会放行。审批后再次检查回执时效。
当前回执生产器尚未注册，改变数据库写入入口会被拒绝；不改变上游的 Serverless 部署可验证路由。
发布前还读取实际 Worker 绑定；从 Selfhost 返回 Serverless 同样需要完整业务回执。
PROD 只允许本仓库受保护的手动发布入口修改 Worker；部署脚本要求同一 run、
同一 commit、同一路由计划的限时 live writer 授权。旧 Serverless/Hybrid 调用不能绕过门槛覆盖生产路由。
单向 Supabase → Selfhost 复制不能持续保证旧库跟随 Selfhost 新写入，PROD 的 Accounts/Billing
读回退默认禁用；注册并验收持续副本合同后才能启用。UAT 和独立 Content 读回退保留安全方法限制。

PROD 的稳定入口由 GitOps 声明：`accounts.svc.plus`、`billing.svc.plus` 用 CNAME 选择
`*-serverless-prod.svc.plus` / `*-selfhost-prod.svc.plus`，同时保留明确的 Worker Routes。
CNAME 的原始 Host 需要自己的 Worker Route，不能靠目标域名继承 Worker 绑定。
DNS / Worker domain 资源由 IaC owner 执行，网关发布只改变代码和上游配置。

`xworktech.com` 保持品牌审核主页，`console.svc.plus` 保持控制台主页。Pages 静态资源直接
由 CDN 服务；Edge Gateway 只承担 API 路由，不把品牌页面或静态资源纳入 Accounts/Billing 切换。
Cloudflare Free 的 100,000 次/日是账户 Workers/Functions 共享配额，静态 Pages 请求不调用
Functions 时不计入该配额（[官方说明](https://developers.cloudflare.com/pages/functions/pricing/)）。

密钥按环境存放在 `secret/data/edge-gateway/{prod,uat}`，通过 GitHub OIDC 和各环境独立
Vault role 读取。上游参数禁止密码、查询参数和网关自身域名，避免凭据落入输入或递归调用。
发布后检查 Accounts 公开计划接口、认证入口、Billing readiness，以及路由、模式和 commit 响应头。
