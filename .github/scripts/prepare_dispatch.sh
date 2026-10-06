#!/usr/bin/env bash
set -euo pipefail

: "${EDGE_GATEWAY_CONFIG_FILE:?rendered config output required}"
: "${GITOPS_DIR:?GitOps checkout required}"
: "${DEPLOY_ENV:?explicit environment required}"
[[ "${GITOPS_REF:-}" =~ ^[0-9a-f]{40}$ ]] || { echo 'gitops_ref must be an immutable commit SHA' >&2; exit 2; }
[[ "$(git -C "${GITOPS_DIR}" rev-parse HEAD)" == "${GITOPS_REF}" ]] || exit 2

# Keep the existing Worker names, hosts and routes for every runtime mode.
# A mode override changes upstream selection; DNS is reconciled by IaC.
ruby -ryaml -rjson -ruri <<'RUBY'
def require_value(condition, message)
  abort(message) unless condition
end
environment = ENV.fetch('DEPLOY_ENV')
require_value(%w[uat prod].include?(environment), 'environment must be uat or prod')
input = File.join(ENV.fetch('GITOPS_DIR'), 'topology', environment, 'serverless', 'runtime-topology.yaml')
config = YAML.safe_load(File.read(input), permitted_classes: [], aliases: false)
require_value(config['kind'] == 'EdgeRoutingConfig' && config.dig('metadata', 'environment') == environment,
              'GitOps environment mismatch')
spec = config.fetch('spec')
serverless = spec.fetch('serverless')
if serverless['billing_serverless_host']
  canonical_billing = serverless.fetch('billing_host')
  serverless['billing_host'] = serverless.fetch('billing_serverless_host')
  serverless['billing_aliases'] = [canonical_billing]
end
defaults = serverless.fetch('edge_gateway').fetch('defaults')
mode = ENV.fetch('INPUT_RUNTIME_MODE', '')
mode = spec.fetch('runtime').fetch('mode') if mode.empty? || mode == 'gitops'
require_value(%w[serverless selfhost hybrid].include?(mode), 'unsupported runtime mode')
original_fallback = defaults.fetch('fallback_upstream')
original_billing_fallback = serverless.fetch('cloud_run').fetch('billing_service')
billing_domain = spec.fetch('domains').values.find { |entry| entry['serverless'] == serverless.fetch('billing_host') }
defaults['billing_primary_upstream'] ||= "https://#{billing_domain.fetch('selfhost')}" if billing_domain
defaults['billing_fallback_upstream'] = original_billing_fallback
{
  'INPUT_PRIMARY_UPSTREAM' => 'primary_upstream',
  'INPUT_FALLBACK_UPSTREAM' => 'fallback_upstream',
  'INPUT_BILLING_PRIMARY_UPSTREAM' => 'billing_primary_upstream',
  'INPUT_BILLING_FALLBACK_UPSTREAM' => 'billing_fallback_upstream',
  'INPUT_TIMEOUT_MS' => 'timeout_ms'
}.each do |input_key, key|
  value = ENV.fetch(input_key, '').strip
  defaults[key] = value unless value.empty?
end
forbidden_hosts = [serverless.fetch('accounts_host'), serverless.fetch('billing_host')]
forbidden_hosts += serverless.fetch('accounts_aliases', []) + serverless.fetch('billing_aliases', [])
forbidden_hosts += spec.dig('runtime', 'routing', 'dns', 'canonical_records').keys
%w[primary_upstream fallback_upstream billing_primary_upstream billing_fallback_upstream].each do |key|
  value = defaults[key]
  require_value(value && !value.empty?, "#{key} is required")
  uri = URI.parse(value)
  require_value(uri.is_a?(URI::HTTPS) && uri.host && uri.userinfo.nil? && uri.port == 443 &&
                ['', '/'].include?(uri.path) && uri.query.nil? && uri.fragment.nil? &&
                uri.host.match?(/\A[a-z0-9][a-z0-9.-]*\.[a-z0-9-]+\z/i) &&
                !forbidden_hosts.include?(uri.host.downcase),
                "#{key} must be a distinct HTTPS origin without credentials, path or query")
end
timeout = defaults.fetch('timeout_ms', '2500').to_s
require_value(timeout.match?(/\A[0-9]+\z/) && (100..10000).include?(timeout.to_i), 'timeout_ms must be 100..10000')
defaults['timeout_ms'] = timeout
defaults['failover_methods'] = %w[GET HEAD OPTIONS]
config['metadata']['mode'] = mode
config['metadata']['gitops_sha'] = ENV.fetch('GITOPS_REF')
spec.fetch('runtime')['mode'] = mode
spec.fetch('domains').each do |canonical, entry|
  next unless [serverless['accounts_host'], serverless['billing_host']].include?(entry['serverless'])
  spec.fetch('runtime').fetch('routing').fetch('dns').fetch('canonical_records')[canonical] = entry.fetch(mode == 'serverless' ? 'serverless' : 'selfhost')
end
config['metadata']['cutover_required'] = mode != 'serverless' ||
  defaults['fallback_upstream'] != original_fallback ||
  defaults['billing_fallback_upstream'] != original_billing_fallback
File.write(ENV.fetch('EDGE_GATEWAY_CONFIG_FILE'), JSON.pretty_generate(config) + "\n")
if ENV['GITHUB_OUTPUT']
  File.open(ENV['GITHUB_OUTPUT'], 'a') do |file|
    file.puts("runtime_mode=#{mode}")
    file.puts("cutover_required=#{config['metadata']['cutover_required']}")
  end
end
puts "Prepared #{environment} #{mode} routing from #{ENV.fetch('GITOPS_REF')}; no resources changed"
RUBY
