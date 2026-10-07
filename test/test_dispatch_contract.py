"""Offline release contracts: no Vault, Cloudflare or GitHub access."""
import ast
import datetime
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / '.github/scripts'
SHA = 'a' * 40


def config():
    mapping = {k + '.svc.plus': {'serverless': k + '-serverless-prod.svc.plus', 'selfhost': k + '-selfhost-prod.svc.plus'} for k in ('accounts', 'billing')}
    return {'kind': 'EdgeRoutingConfig', 'metadata': {'environment': 'prod', 'mode': 'serverless'}, 'spec': {
        'runtime': {'mode': 'serverless', 'routing': {'dns': {'canonical_records': {k: v['serverless'] for k, v in mapping.items()}}}},
        'domains': mapping,
        'serverless': {'accounts_host': mapping['accounts.svc.plus']['serverless'], 'accounts_aliases': ['accounts.svc.plus'],
            'billing_host': 'billing.svc.plus', 'billing_serverless_host': mapping['billing.svc.plus']['serverless'],
            'cloud_run': {'billing_service': 'https://billing.run.app'},
            'edge_gateway': {'boundaries': [{'id': i, 'worker_name': f'edge-gateway-{i}-prod'} for i in ('auth', 'admin', 'core')],
                'defaults': {'primary_upstream': 'https://accounts-selfhost-prod.svc.plus', 'fallback_upstream': 'https://accounts.run.app',
                             'timeout_ms': '2500'}}},
    }}


def inline_python(script):
    return re.search(r"python3[^\n]* <<'PY'\n(.*?)\nPY", script, re.S).group(1)


class DispatchTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.gitops = self.root / 'gitops'
        self.gitops.mkdir()
        file = self.gitops / 'topology/prod/serverless/runtime-topology.yaml'
        file.parent.mkdir(parents=True); file.write_text(json.dumps(config()))
        for args in (['init', '-q'], ['add', '.'], ['-c', 'user.name=contract', '-c', 'user.email=contract@example.test', 'commit', '-qm', 'fixture']):
            subprocess.run(['git', '-C', str(self.gitops), *args], check=True, capture_output=True)
        self.sha = subprocess.check_output(['git', '-C', str(self.gitops), 'rev-parse', 'HEAD'], text=True).strip()
        self.plan = self.root / 'plan.json'

    def prepare(self, **inputs):
        env = dict(os.environ, GITOPS_DIR=str(self.gitops), GITOPS_REF=self.sha,
                   DEPLOY_ENV='prod', EDGE_GATEWAY_CONFIG_FILE=str(self.plan))
        env.update(inputs)
        result = subprocess.run(['bash', str(SCRIPTS / 'prepare_dispatch.sh')], env=env, capture_output=True, text=True)
        if result.returncode == 0: self.config = json.loads(self.plan.read_text())
        return result

    def test_default_plan_and_safe_failover(self):
        self.assertEqual(self.prepare().returncode, 0)
        self.assertFalse(self.config['metadata']['cutover_required'])
        sl = self.config['spec']['serverless']
        self.assertEqual(sl['billing_host'], 'billing-serverless-prod.svc.plus')
        self.assertEqual(sl['billing_aliases'], ['billing.svc.plus'])
        self.assertEqual(sl['edge_gateway']['defaults']['failover_methods'], ['GET', 'HEAD', 'OPTIONS'])

    def test_hybrid_is_gated_and_cnames_target_selfhost(self):
        self.assertEqual(self.prepare(INPUT_RUNTIME_MODE='hybrid').returncode, 0)
        self.assertTrue(self.config['metadata']['cutover_required'])
        self.assertEqual(self.config['spec']['runtime']['routing']['dns']['canonical_records']['billing.svc.plus'], 'billing-selfhost-prod.svc.plus')

    def test_origins_reject_gateway_secrets_and_paths(self):
        for origin in ('https://accounts.svc.plus', 'https://billing-serverless-prod.svc.plus',
                       'https://user:do-not-leak@example.test', 'https://origin.example.test/path',
                       'https://origin.example.test?token=do-not-leak'):
            result = self.prepare(INPUT_PRIMARY_UPSTREAM=origin)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('do-not-leak', result.stdout + result.stderr)

    def test_timeout_and_exact_gitops_sha(self):
        for value in ('0', '10001', '25x', '2500\nextra'):
            self.assertNotEqual(self.prepare(INPUT_TIMEOUT_MS=value).returncode, 0)
        self.assertNotEqual(self.prepare(GITOPS_REF=SHA).returncode, 0)

    def test_missing_receipt_fails_before_github_access(self):
        self.assertEqual(self.prepare(INPUT_RUNTIME_MODE='selfhost').returncode, 0)
        result = subprocess.run(['bash', str(SCRIPTS / 'verify_cutover.sh')],
            env=dict(os.environ, EDGE_GATEWAY_CONFIG_FILE=str(self.plan), CUTOVER_RUN_ID=''), capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('cutover receipt', result.stderr)

    def receipt(self):
        self.assertEqual(self.prepare(INPUT_RUNTIME_MODE='selfhost').returncode, 0)
        body = inline_python((SCRIPTS / 'verify_cutover.sh').read_text())
        defaults = self.config['spec']['serverless']['edge_gateway']['defaults']
        receipt = {'schema': 'edge-gateway-cutover/v2', 'run_id': '123', 'workflow_sha': SHA, 'environment': 'prod',
            'verified_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'bindings': {k: defaults[k] for k in ('primary_upstream', 'fallback_upstream', 'billing_primary_upstream', 'billing_fallback_upstream')},
            'writers_quiesced': True, 'single_writer': True, 'latest_native_schema': True,
            'core_users': {'source': {'count': 24, 'email_sha256': 'c'*64, 'password_hash_sha256': 'e'*64, 'email_proxy_sha256': 'd'*64},
                           'target': {'count': 24, 'email_sha256': 'c'*64, 'password_hash_sha256': 'e'*64, 'email_proxy_sha256': 'd'*64}}}
        receipt['bindings']['mode'] = 'selfhost'
        return body, receipt

    def validate_receipt(self, body, receipt):
        artifact = self.root / 'artifact'; artifact.mkdir(exist_ok=True)
        (self.root / 'run.json').write_text(json.dumps({'head_sha': SHA}))
        (artifact / 'gtm-cutover.json').write_text(json.dumps(receipt))
        return subprocess.run(['python3', '-c', body, str(self.root), str(self.plan), '123'], capture_output=True, text=True)

    def test_complete_receipt_is_accepted(self):
        body, receipt = self.receipt()
        self.assertEqual(self.validate_receipt(body, receipt).returncode, 0)

    def test_incomplete_stale_proxy_and_origin_mismatch_rejected(self):
        for mutation in (
            lambda r: r['core_users']['target'].update(email_proxy_sha256='f'*64),
            lambda r: r['core_users']['target'].update(password_hash_sha256='f'*64),
            lambda r: r['bindings'].update(primary_upstream='https://other.example.test'),
            lambda r: r.update(single_writer=False),
            lambda r: r.update(verified_at='2020-01-01T00:00:00Z'),
            lambda r: r['core_users']['target'].update(count=23),
        ):
            body, receipt = self.receipt(); mutation(receipt)
            self.assertNotEqual(self.validate_receipt(body, receipt).returncode, 0)

    def live_writer(self, current_mode):
        self.assertEqual(self.prepare().returncode, 0)
        defaults = self.config['spec']['serverless']['edge_gateway']['defaults']
        values = {'RUNTIME_MODE': current_mode, **{k.upper(): v for k, v in defaults.items()}}
        data = {'success': True, 'result': {'bindings': [{'name': k, 'type': 'plain_text', 'text': v} for k, v in values.items()]}}
        env = {'EDGE_GATEWAY_CONFIG_FILE': str(self.plan), 'CLOUDFLARE_ACCOUNT_ID': 'a'*32, 'CLOUDFLARE_API_TOKEN': 'not-a-real-token'}
        with patch.dict(os.environ, env), patch('urllib.request.urlopen', side_effect=lambda *args, **kwargs: io.BytesIO(json.dumps(data).encode())):
            exec(compile(inline_python((SCRIPTS / 'require_live_cutover.sh').read_text()), 'live-writer', 'exec'), {})
        return json.loads(self.plan.read_text())['metadata']['cutover_required']

    def test_return_to_serverless_requires_equal_business_receipt(self):
        self.assertTrue(self.live_writer('selfhost'))

    def test_unchanged_live_writer_does_not_require_cutover(self):
        self.assertFalse(self.live_writer('serverless'))


if __name__ == '__main__': unittest.main()
