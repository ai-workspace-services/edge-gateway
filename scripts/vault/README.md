# Edge Gateway runtime Vault contract

Bootstrap these declarative policies/roles once through the platform identity administrator. Each role reads only `secret/data/edge-gateway/<environment>` and binds the exact Edge Gateway repository, protected GitHub environment, reviewed main/release ref, and deployment workflow. No Service Account key or local personal GCP session is used for Worker releases.

The environment KV must contain `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, and the backend-aligned `JWT_SECRET`. Use `INTERNAL_SERVICE_TOKEN` and `CONTENT_SERVICE_TOKEN` only from their reviewed service contracts. Credentials are resolved at runtime; do not place values in Git, workflow inputs, release artifacts, or chat. Bootstrap must compare credential hashes with the environment's Accounts/Billing contract without printing values.

Before a PROD dispatch, configure required reviewers for the repository's `production` environment. Deployment checks that protection and that its commit is already merged into main before reading Vault. Main/tag pushes run CI only; publication is an explicit reviewed dispatch.

These files are declarations, not evidence that live Vault roles, policies, environment secrets, or protected environments have been applied. Full business cutover receipt production is still a separate pending data-owner integration.
