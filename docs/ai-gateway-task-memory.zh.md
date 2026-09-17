# AI Gateway v1 任务记忆与交接记录

> 用途：保存本任务的关键决策、边界、配置契约和后续实施上下文，便于在新会话或其他仓库继续工作。
>
> 安全声明：本文不包含 API Key、OAuth token、JWT 私钥、session secret、数据库密码、CPA auth bundle 或任何 Vault secret value。

## 1. 当前状态

- 当前仓库：`ai-workspace-services/edge-gateway`。
- 当前分支：`fix/preserve-oauth-redirects`。
- 最近提交：`e0adb38 docs: add AI gateway Kong PostgreSQL plan`。
- 工作区：已清理，当前提交只包含 AI Gateway 规划文档。
- 已新增文档：`docs/ai-gateway-kong-postgresql-plan.zh.md`。
- 当前阶段：规划和公共边界定义完成，尚未在本仓库实现 Kong、Caddy、New API、LiteLLM 或 CPA 运行代码。
- 尚未执行：云资源创建、Vault 写入、OAuth 登录、UAT 部署、Prod 变更和远端推送。

## 2. 总体目标

建设一套面向个人/团队使用的 AI 聚合 Gateway：

```text
客户端 / Claude Code / Codex CLI / Android Studio / SDK / Web SaaS
                              │
                              ▼
                    Caddy HTTPS :443
                  TLS + IP 白名单
                              │
                              ▼
                   Kong Gateway
         JWT/Key Auth + Tenant ACL + Rate Limit
                     PostgreSQL 后端
                       无 etcd
                    │              │
              ai.<domain>      direct.ai.<domain>
                    │              │
                    ▼              ▼
                 New API          LiteLLM
             CPA Claude/GPT/Grok  官方 API 聚合
                    │              │
                    ▼              ▼
                   CPA       OpenAI/Anthropic/xAI
```

固定路由：

```text
ai.onwalk.net / ai.svc.plus
  → Caddy → Kong → New API → CPA

direct.ai.onwalk.net / direct.ai.svc.plus
  → Caddy → Kong → LiteLLM → 官方 OpenAI/Anthropic/xAI API
```

`direct.ai.*` 不得访问 CPA；CPA、New API、LiteLLM 和 Kong Admin API 不得直接暴露公网。

## 3. 关键技术决策

### Gateway 选型

v1 选择 Kong Gateway：

```yaml
gateway:
  adapter: kong
  mode: traditional
  runtime_config_backend: postgresql
  config_source: gitops-yaml-or-json
  sync: admin-api-or-deck
  etcd: false
```

原因：Kong Traditional 模式原生使用 PostgreSQL 保存 Routes、Services、Plugins、Consumers、ACL 和 Credentials 等运行时配置实体，适合多租户动态配置。

APISIX 和 Nginx 作为后续适配器：

- APISIX Standalone 可使用 YAML/JSON，但不等价于 Kong 的 PostgreSQL 动态配置后端；
- APISIX 后续需要定义全量配置发布、回滚、并发更新和动态 Consumer 管理方案；
- Nginx 只作为静态反向代理/入口适配器，不承担完整的动态租户控制面；
- 不将 APISIX Standalone 宣称为 Kong PostgreSQL 的等价替代。

### 配置模型

```text
GitOps YAML/JSON
       ↓
validate
       ↓
render
       ↓
Kong Admin API / decK sync
       ↓
Kong PostgreSQL
       ↓
Kong Runtime
```

YAML/JSON 是声明式配置源；PostgreSQL 是 Kong 运行时配置后端。禁止直接 SQL 修改 Kong 内部表。

### 认证模型

v1 同时支持：

- Key Auth：第三方客户端默认使用，兼容 OpenAI/Anthropic 风格配置；
- JWT：服务间调用或短期授权使用；
- Tenant ACL：隔离租户和允许的模型/路由；
- Rate Limit：按租户或 Consumer 限流；
- Audit Metadata：记录 tenant、client、route、request ID。

公共配置不保存客户端凭据明文。客户端凭据的创建、吊销、租户归属和使用记录由业务数据库/控制面管理，再通过安全流程同步到 Kong。

## 4. 组件职责

### Caddy

- 唯一公网 HTTPS 入口；
- TLS 证书和域名；
- IP 白名单；
- Host 路由；
- 管理路径额外保护；
- 配置 validate 成功后 reload；
- 不负责复杂的租户、模型和 CPA 选择。

### Kong

- JWT/Key Auth；
- Tenant ACL；
- Rate Limit；
- Host/Path Route；
- Audit Metadata；
- Kong PostgreSQL 运行时配置；
- 不负责 AI 模型别名、CPA channel 或官方 Provider retry。

### New API

- CPA Claude/GPT/Grok 聚合；
- 模型别名；
- CPA channel；
- CPA 账号健康状态；
- OpenAI Chat/Responses；
- Claude Messages；
- streaming 和工具调用。

### LiteLLM

- 官方 OpenAI、Anthropic、xAI API 聚合；
- Retry、timeout、usage、cost；
- 直接 API 路由；
- 不作为 New API → CPA 的前置代理。

### CPA

- 一实例绑定一个账号；
- Codex CLI / Claude Code / Grok CLI；
- 使用 `ai_desktop` role 部署节点；
- 本地加密 OAuth auth；
- 独立 Unix 用户和 systemd unit；
- 仅私网监听；
- 不读取 Vault 中的 OAuth bundle。

## 5. CPA 矩阵

实例声明属于 GitOps 非敏感配置，认证材料不进入 Git、文档、Terraform state、CI artifact 或日志。

```text
cpa-codex-01  → OpenAI / Codex CLI
cpa-codex-02  → OpenAI / Codex CLI
cpa-claude-01 → Anthropic / Claude Code
cpa-grok-01   → xAI / Grok CLI
```

每个实例必须声明：

- `id`；
- `node`；
- `provider`；
- `cli`；
- 非认证账号标识；
- 私网 endpoint 引用；
- 监听端口；
- 本地 auth 目录；
- New API channel 引用；
- enabled/lifecycle 状态。

CPA 本地认证目录：

```text
/var/lib/ai-aggregator/cpa/<instance-id>/auth/
```

要求目录权限 `0700`，节点级加密；UAT Spot 销毁后认证文件随节点销毁，Prod 持久节点重启后保留。

## 6. Vault 最小路径

逻辑路径：

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

Vault API 实际 KV v2 路径使用：

```text
/v1/kv/data/<env>/ai-aggregator/...
```

建议字段类别：

- `database/new-api`：New API DSN；
- `database/litellm`：LiteLLM DSN；
- `gateway/kong`：Kong PostgreSQL DSN、内部 Admin 凭据；
- `gateway/caddy`：管理认证 hash；
- `gateway/new-api`：session/crypto/JWT signing secret；
- `gateway/litellm`：master key、proxy secret；
- `litellm/providers/*`：endpoint、API key。

废弃路径：

```text
accounts/*
instances/*
clients/*
cpa/*
database/backup
```

CPA OAuth 不集中写入 Vault；客户端动态状态写入业务数据库或 Kong 运行时数据库，但 OAuth token 不以明文保存。

## 7. 仓库交接边界

### `ai-workspace-services/gateway`

公共组件职责：

- `contracts/gateway.yaml`；
- JSON Schema；
- `adapters/caddy`；
- `adapters/kong`；
- 后续 `adapters/apisix`、`adapters/nginx`；
- New API/LiteLLM/CPA profiles；
- `validate`/`render` CLI；
- adapter capability tests。

### `ai-workspace-infra/gitops`

环境声明职责：

- UAT/Prod 域名；
- 节点、区域、规格；
- AWS/GCP/VPS provider 选择；
- Spot/persistent 生命周期；
- 租户和 CPA 矩阵；
- adapter 选择；
- 非敏感 Vault `secret_ref`。

### `ai-workspace-infra/playbooks`

部署职责：

- Caddy/Kong/New API/LiteLLM/CPA systemd；
- Kong PostgreSQL migrations；
- Vault runtime injection；
- Kong Admin API/decK sync；
- `ai_desktop` role；
- CPA 本地 auth 目录；
- validate、reload、rollback。

### `platform-ops-toolkit`

流水线职责：

- contract/schema 校验；
- Vault path 校验；
- Terraform validate/plan；
- Ansible syntax-check；
- Caddy/Kong 静态校验；
- gitleaks；
- UAT `stage → OAuth → validate → activate`；
- Prod approval 和回滚。

### 当前 `edge-gateway`

继续维护现有 Cloudflare Worker：

- `/api/*` 应用边界；
- Edge JWT；
- CORS；
- selfhost/serverless/hybrid；
- VPS/Cloud Run failover。

不加入 AI `/v1/*` 路由，不引入 Kong/New API/LiteLLM/CPA 运行时依赖。

## 8. 环境规划

### UAT

```text
New API + LiteLLM + Kong + Caddy
域名：ai.onwalk.net
直连 API：direct.ai.onwalk.net
```

CPA 节点可使用 AWS Spot、GCP Spot 或 VPS，由 GitOps 选择，不在流水线中写死。默认使用 `ai_desktop` role，节点规格按 2C2G 或 2C4G 起步。

UAT 生命周期：

```text
validate → plan → stage → deploy → 人工 OAuth
→ runtime validate → smoke test → activate → 自动清理
```

### Prod

```text
New API + LiteLLM + Kong + Caddy
域名：ai.svc.plus
直连 API：direct.ai.svc.plus
```

Prod 复用现有持久节点，不执行 Terraform destroy/replace；使用受保护环境、人工审批和可回滚部署。

## 9. 实施阶段

### 阶段一：公共契约

1. 建立独立 `gateway` 项目；
2. 定义 YAML/JSON contract 和 JSON Schema；
3. 定义 tenant、route、auth、rate limit、audit 字段；
4. 增加敏感字段禁止规则；
5. 增加 UAT/Prod 示例；
6. 增加 contract compatibility tests。

### 阶段二：Kong v1

1. 实现 Caddy renderer；
2. 实现 Kong entity renderer；
3. 初始化 Kong PostgreSQL 和 migrations；
4. 通过 Admin API/decK 幂等同步；
5. 接入 JWT、Key Auth、ACL、Rate Limit；
6. 接入 New API、LiteLLM、CPA profiles；
7. 使用 `deploy_ai_desktop.yml` 部署 CPA/CodeAgent 节点；
8. 完成 UAT smoke test；
9. 人工完成四个 CPA OAuth 后执行 activate。

### 阶段三：替代适配器

1. APISIX Standalone YAML/JSON renderer；
2. Nginx renderer；
3. capability matrix；
4. 全量发布和回滚测试；
5. 明确 APISIX/Nginx 与 Kong PostgreSQL 的差异；
6. 不替换 Kong v1 默认实现。

## 10. 验收标准

- 公网仅暴露 443，管理接口不公网暴露；
- `ai.*` 只到 New API，`direct.ai.*` 只到 LiteLLM；
- 租户 ACL 和限流隔离有效；
- OpenAI Chat/Responses、Claude Messages、streaming、tool calling 可用；
- Claude Code、Codex CLI、Android Studio、SDK、Web SaaS 可配置统一 Gateway URL；
- 单个 CPA 停止不影响其他 CPA；
- New API 与 LiteLLM 故障相互隔离；
- Kong 配置同步失败时保留旧配置；
- Git、Terraform state、CI artifact 和日志无敏感信息；
- Kong、New API、LiteLLM 使用独立数据库/用户；
- UAT Spot 销毁后不残留 OAuth 文件；
- Prod 不发生未经审批的销毁或替换。

## 11. 下一步入口

下一次继续任务时，建议按以下顺序执行：

1. 审计 `ai-workspace-infra/gitops` 当前 UAT/Prod AI Aggregator manifest；
2. 审计 `playbooks` 的 `ai_aggregator_v1` 和 `deploy_ai_desktop.yml`；
3. 在独立 `ai-workspace-services/gateway` 项目建立 contract/schema 骨架；
4. 将 GitOps manifest 接入 `gatewayctl validate`；
5. 只在 UAT 执行 Kong PostgreSQL、Caddy、New API、LiteLLM 和 CPA stage；
6. 人工完成 CPA OAuth；
7. 通过 smoke test 后 activate；
8. 最后再规划 Prod promotion 和 APISIX/Nginx adapter。

继续实施前必须人工确认：

- Vault GitHub OIDC role 和最小路径权限；
- Kong PostgreSQL DSN 可用性；
- UAT AWS/GCP/VPS provider；
- CPA 节点私网 endpoint；
- 四个 CPA 实例的人工 OAuth 登录窗口；
- Caddy IP 白名单来源；
- UAT 自动清理时间和 Prod approval 责任人。
