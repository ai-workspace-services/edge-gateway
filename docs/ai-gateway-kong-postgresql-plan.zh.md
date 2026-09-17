# AI Gateway v1：YAML/JSON 声明源与 Kong PostgreSQL 配置后端规划

> 状态：规划文档
>
> 适用范围：`ai-workspace-services/gateway` 公共 Gateway 组件、`ai-workspace-infra/gitops`、`playbooks` 和 `platform-ops-toolkit`
>
> 本文不改变当前 `edge-gateway` Cloudflare Worker 的运行链路。

## 1. 目标

建立一个面向个人和团队 AI 聚合服务的公共 Gateway 组件，使用 YAML/JSON 作为声明式配置源，并使用 Kong Gateway + PostgreSQL 作为 v1 的运行时配置后端。

v1 需要支持：

- Caddy TLS 终止和公网 IP 白名单；
- Kong JWT/Key Auth、租户 ACL、限流和审计元数据；
- `ai.*` 路由到 New API；
- `direct.ai.*` 路由到 LiteLLM；
- New API 继续聚合 CPA Claude、GPT、Grok 实例；
- LiteLLM 继续聚合官方 OpenAI、Anthropic、xAI API；
- Claude Code、Codex CLI、Android Studio、SDK 和 Web SaaS 通过标准 OpenAI/Anthropic 兼容接口接入；
- Kong 不使用 etcd，使用 PostgreSQL 保存运行时配置实体。

本项目只定义可复用的契约、适配器、渲染和验证能力。环境、节点、租户实例和部署生命周期仍由 GitOps 与基础设施流水线管理。

## 2. 当前 `edge-gateway` 的边界

当前仓库是 Cloudflare Worker 项目，负责既有应用的 `/api/*` 边界，包括：

- Edge JWT 验签；
- CORS 和 OPTIONS 快速响应；
- `auth`、`admin`、`core` Worker boundary；
- selfhost/serverless/hybrid 上游选择；
- VPS 到 Cloud Run 的故障转移；
- 既有 `vault.svc.plus` 的 Worker Secret 注入。

这些能力继续保持不变。AI Gateway v1 不将 `/v1/*` AI API 路由加入当前 Worker，也不把 Kong、New API、LiteLLM 或 CPA 打包进 Cloudflare Worker。

公共 AI Gateway 组件采用独立项目边界：

```text
/Users/shenlan/workspaces/ai-workspace-service/gateway
└── 独立仓库 ai-workspace-services/gateway
```

`edge-gateway` 只保留既有 Cloudflare 运行链路；两个项目可以共享组织级契约规范，但不共享运行时进程和部署入口。

## 3. 目标架构

```text
Claude Code / Codex CLI / Android Studio / SDK / Web SaaS
                              │
                              ▼
                    Caddy :443 公网入口
              TLS + IP 白名单 + Host 路由
                              │
                              ▼
                  Kong Gateway :8000
            PostgreSQL 配置后端，无 etcd
             JWT/Key Auth + Tenant ACL
                 Rate Limit + Audit
                    │              │
        ai.onwalk.net / ai.svc.plus  direct.ai.*
                    │              │
                    ▼              ▼
                 New API          LiteLLM
           CPA Channel/模型别名   官方 API 聚合
                    │              │
                    ▼              ▼
          CPA Claude/GPT/Grok   OpenAI/Anthropic/xAI
          一实例绑定一个账号
          本地加密 OAuth auth
```

请求边界固定为：

```text
ai.<domain>/v1/*
  → Caddy → Kong → New API → CPA

direct.ai.<domain>/v1/*
  → Caddy → Kong → LiteLLM → 官方 API
```

`direct.ai.*` 不得访问 CPA；CPA 节点不得直接暴露公网；Kong Admin API、New API、LiteLLM 和 CPA 仅监听 loopback 或私网地址。

## 4. 配置模型：声明源与运行时后端

### 4.1 配置流转

```text
GitOps YAML/JSON
       │
       ▼
gatewayctl validate
       │
       ▼
gatewayctl render --adapter kong
       │
       ▼
Kong Admin API 或 decK sync
       │
       ▼
Kong PostgreSQL
       │
       ▼
Kong Gateway Runtime
```

YAML/JSON 是声明式 Source of Truth；PostgreSQL 是 Kong 的运行时配置数据库。不得通过直接 SQL 修改 Kong 的内部表，所有路由、服务、插件、Consumer、ACL 和 Credential 变更必须经过 Kong Admin API 或 decK 的幂等同步。

Kong Traditional 模式会将 Routes、Services、Plugins、Consumers、Credentials 等配置实体保存在 PostgreSQL 中，并由 Kong 节点加载和缓存。PostgreSQL 只承担 Kong 配置和运行状态，不与 New API、LiteLLM 业务数据库混用。

### 4.2 公共契约不保存的内容

公共契约禁止包含：

- API Key；
- JWT signing key；
- OAuth token 或 CPA auth bundle；
- 数据库密码；
- New API session secret；
- LiteLLM master key；
- 运行时健康状态；
- 客户端凭据明文。

这些信息分别由 Vault、CPA 节点本地加密目录或业务数据库管理。

## 5. 公共 Gateway 契约

规划仓库结构：

```text
gateway/
├── contracts/
│   ├── gateway.yaml
│   └── gateway.schema.json
├── adapters/
│   ├── caddy/
│   ├── kong/
│   ├── nginx/
│   └── apisix/
├── profiles/
│   └── ai-gateway-v1/
│       ├── new-api.yaml
│       ├── litellm.yaml
│       └── cpa-matrix.yaml
├── cli/
├── docs/
└── tests/
```

公共契约的核心声明包括：

- `schema_version`；
- `adapter`；
- `environment`；
- `tenants`；
- `routes`；
- `upstreams`；
- `auth`；
- `rate_limits`；
- `audit`；
- `capabilities`。

租户声明只包含租户 ID、启用状态、允许模型、路由引用和限流策略。路由声明包含 Host、Path、目标逻辑服务、协议和租户引用。

示例：

```yaml
schema_version: v1

gateway:
  adapter: kong
  mode: traditional
  runtime_config_backend: postgresql
  etcd: false

tenants:
  - id: personal
    enabled: true
    allowed_models:
      - claude
      - gpt
      - grok
    rate_limit_ref: personal-default

routes:
  - id: ai-new-api
    hosts:
      - ai.onwalk.net
      - ai.svc.plus
    paths:
      - /v1
    upstream: new-api
    auth:
      mode: key-auth
    tenant_ref: personal

  - id: ai-litellm
    hosts:
      - direct.ai.onwalk.net
      - direct.ai.svc.plus
    paths:
      - /v1
    upstream: litellm
    auth:
      mode: key-auth
    tenant_ref: personal
```

建议 v1 同时支持 `key-auth` 和 `jwt`：

- 第三方客户端默认使用 Key Auth，兼容 OpenAI/Anthropic 风格的 Bearer 配置；
- 服务间调用可以使用短期 JWT；
- JWT/API Key 的创建、吊销、租户归属和使用记录不写入公共契约；
- Kong 只消费经过安全同步的运行时凭据。

## 6. Kong v1 适配器

### 6.1 Kong 部署模式

```yaml
gateway:
  adapter: kong
  mode: traditional
  config_source: gitops
  runtime_config_backend: postgresql
  sync: admin-api-or-deck
  etcd: false
```

部署要求：

- 独立 `kong` PostgreSQL 数据库或 schema；
- 独立数据库用户；
- 首次部署执行 Kong migrations；
- Kong Admin API 仅监听 loopback/私网；
- 路由和插件通过 Admin API 或 decK 幂等同步；
- 同步失败时保留旧配置；
- 不直接修改 Kong 内部表；
- Caddy 仅在 Kong 配置校验成功后 reload。

### 6.2 Kong 插件能力

v1 只纳入必要能力：

- JWT Auth；
- Key Auth；
- ACL；
- Rate Limiting；
- Request/Correlation ID；
- Audit Metadata；
- Host/Path Route；
- 上游健康检查和超时。

不在 v1 引入自定义 AI 推理插件。AI 模型别名、CPA channel 和 Provider 选择分别由 New API 与 LiteLLM 管理，避免 Kong 与后端路由职责重叠。

## 7. APISIX 和 Nginx 后续适配器

APISIX 和 Nginx 不是 v1 主运行链路。

APISIX Standalone 可通过 YAML/JSON 文件加载配置，但不等价于 Kong 的 PostgreSQL 动态配置后端。若使用 APISIX，需要由渲染器重新生成完整配置并发布，租户变更、回滚和并发更新均需要额外控制。

后续 APISIX 适配器必须明确：

- 使用 Standalone file-driven 还是 API-driven；
- 配置发布是否全量替换；
- 是否支持动态 Consumer/Credential；
- 是否支持相同的 ACL、Rate Limit 和审计字段；
- 配置回滚和并发更新机制；
- 与 Kong PostgreSQL 模式的能力差异。

Nginx 适配器只作为静态入口和反向代理实现，不承担完整的动态租户控制面。它需要通过外部认证服务或生成配置后 reload，不能假设与 Kong 的动态 Consumer 管理等价。

## 8. Vault 与数据库边界

Vault 只保存必要敏感信息：

```text
kv/<env>/ai-aggregator/database/new-api
kv/<env>/ai-aggregator/database/litellm

kv/<env>/ai-aggregator/gateway/caddy
kv/<env>/ai-aggregator/gateway/kong
kv/<env>/ai-aggregator/gateway/new-api
kv/<env>/ai-aggregator/gateway/litellm

kv/<env>/ai-aggregator/litellm/providers/openai
kv/<env>/ai-aggregator/litellm/providers/anthropic
kv/<env>/ai-aggregator/litellm/providers/xai
```

`gateway/kong` 至少需要保存 Kong PostgreSQL DSN 和内部 Admin API 凭据。客户端 API Key 不写入公共 GitOps 配置；其生命周期由业务数据库/控制面管理，并通过安全流程同步到 Kong。

CPA OAuth 只保存在实例本地：

```text
/var/lib/ai-aggregator/cpa/<instance-id>/auth/
```

要求：独立 Unix 用户、目录权限 `0700`、节点级加密、禁止进入 Git、Vault、Terraform state、CI artifact 和日志。

## 9. 跨仓库职责

### `gateway`

- 公共 YAML/JSON 契约；
- JSON Schema；
- `validate` 和 `render` CLI；
- Caddy/Kong 适配器；
- APISIX/Nginx 后续适配器；
- 能力差异测试。

### `gitops`

- UAT/Prod 域名；
- 节点和资源规格；
- 租户和 CPA 矩阵；
- AWS/GCP/VPS provider 选择；
- Spot/persistent 生命周期；
- 适配器选择；
- 非敏感 Vault `secret_ref`。

### `playbooks`

- Caddy、Kong、New API、LiteLLM、CPA 安装；
- PostgreSQL 连接和 Kong migrations；
- Vault 运行时注入；
- Kong sync；
- systemd 启动顺序；
- CPA 本地 auth 目录；
- 健康检查和回滚。

### `platform-ops-toolkit`

- GitOps/schema 校验；
- `gatewayctl validate/render` 调用；
- Terraform validate/plan；
- Ansible syntax-check；
- Caddy/Kong 静态校验；
- gitleaks；
- UAT `stage → OAuth → validate → activate`；
- Prod approval 和回滚。

### `edge-gateway`

- 继续维护 Cloudflare Worker；
- 不加入 AI `/v1/*` 路由；
- 不依赖 Kong PostgreSQL；
- 不承载 New API、LiteLLM 或 CPA。

## 10. 分阶段实施计划

### 阶段一：公共契约

1. 建立独立 `gateway` 项目；
2. 定义 `gateway.yaml` 和 JSON Schema；
3. 固定租户、路由、认证、限流和审计字段；
4. 增加敏感字段禁止规则；
5. 增加 UAT/Prod 示例 manifest；
6. 增加契约兼容性测试。

完成标准：同一份声明可以被校验，并能表达 New API 和 LiteLLM 两条路由，但不包含任何凭据。

### 阶段二：Caddy + Kong v1

1. 实现 Caddy renderer；
2. 实现 Kong entity renderer；
3. 增加 Kong PostgreSQL 初始化与 migration playbook；
4. 增加 Admin API/decK 幂等同步；
5. 接入 JWT、Key Auth、ACL 和 Rate Limit；
6. 接入 New API、LiteLLM 和 CPA profile；
7. 使用 `ai_desktop` role 部署 CPA/CodeAgent 节点；
8. 完成 UAT 端到端验证；
9. 通过人工 CPA OAuth 后执行 activate。

### 阶段三：APISIX/Nginx

1. 复用公共契约；
2. 实现 APISIX Standalone 配置渲染；
3. 实现 Nginx 静态入口渲染；
4. 增加能力差异报告；
5. 增加全量发布、回滚和并发更新测试；
6. 不替换 Kong v1 默认实现。

## 11. 验证标准

### 配置与安全

- YAML/JSON Schema 校验通过；
- Git 中不存在 API Key、OAuth token、JWT 私钥和数据库密码；
- 旧 `accounts/*`、`instances/*`、`clients/*`、`cpa/*` Vault 路径不再被引用；
- Kong、New API、LiteLLM、CPA 无公网监听；
- Kong Admin API 不能从公网访问。

### 路由与租户

- `ai.*` 只能访问 New API；
- `direct.ai.*` 只能访问 LiteLLM；
- `direct.ai.*` 不能访问 CPA；
- 未通过 IP 白名单的请求被拒绝；
- 无效 JWT/API Key 被拒绝；
- 租户 ACL 和限流隔离生效；
- 审计信息包含 tenant、client、route 和 request ID。

### 协议与客户端

- OpenAI Chat 成功；
- OpenAI Responses 成功；
- Claude Messages 成功；
- streaming 成功；
- tool calling 成功；
- Claude Code、Codex CLI、Android Studio、SDK 和 Web SaaS 可以使用聚合后的 Gateway URL。

### 数据与故障

- Kong migrations 成功；
- Kong PostgreSQL、New API、LiteLLM 数据库隔离；
- YAML/JSON 重复同步不产生重复实体；
- Kong reload/sync 失败时旧配置继续运行；
- 单个 CPA 停止不影响其他 CPA；
- New API 与 LiteLLM 故障相互隔离；
- UAT Spot 销毁后不残留 CPA OAuth 文件。

## 12. 最终 v1 决策

```yaml
gateway:
  adapter: kong
  mode: traditional
  runtime_config_backend: postgresql
  config_source: gitops-yaml-or-json
  sync: admin-api-or-deck
  etcd: false
```

Kong 是 v1 的主 Gateway；APISIX 和 Nginx 是后续适配器。YAML/JSON 负责声明，Kong PostgreSQL 负责运行时配置，Vault 负责敏感信息，GitOps 负责环境选择，Playbooks 负责部署，platform-ops-toolkit 负责校验和流水线。
