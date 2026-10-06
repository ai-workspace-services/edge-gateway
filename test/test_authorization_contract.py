"""Offline guards for the explicit production GTM publication entry."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / '.github/scripts'
SHA = 'a' * 40


class AuthorizationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(); self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.plan = self.root / 'plan.json'
        self.config = {'kind': 'EdgeRoutingConfig', 'metadata': {'environment': 'prod'},
            'spec': {'runtime': {'routing': {'dns': {'api_alias_mode': 'worker-routes-cname'}}}}}
        self.plan.write_text(json.dumps(self.config))
        self.env = dict(os.environ, EDGE_GATEWAY_CONFIG_FILE=str(self.plan), RUNNER_TEMP=str(self.root),
            GITHUB_REPOSITORY='ai-workspace-services/edge-gateway', GITHUB_EVENT_NAME='workflow_dispatch',
            GITHUB_WORKFLOW_REF='ai-workspace-services/edge-gateway/.github/workflows/deploy.yml@refs/heads/main',
            GITHUB_SHA=SHA, GATEWAY_REVISION=SHA, GITHUB_RUN_ID='123', GITHUB_RUN_ATTEMPT='1')

    def guard(self):
        return subprocess.run(['bash', str(SCRIPTS / 'require_dispatch_owner.sh')],
                              env=self.env, capture_output=True, text=True)

    def authorize(self, **changes):
        receipt = dict(plan_sha256=hashlib.sha256(self.plan.read_bytes()).hexdigest(), revision=SHA,
                       run_id='123', run_attempt='1', verified_at=time.time())
        receipt.update(changes)
        (self.root / 'edge-gateway-live-authorization.json').write_text(json.dumps(receipt))

    def test_uat_contract_is_unchanged(self):
        self.config['metadata']['environment'] = 'uat'
        self.config['spec']['runtime']['routing']['dns'] = {}
        self.plan.write_text(json.dumps(self.config))
        self.assertEqual(self.guard().returncode, 0)

    def test_no_authorization_or_foreign_caller_cannot_mutate(self):
        self.assertNotEqual(self.guard().returncode, 0)
        self.authorize(); self.env['GITHUB_REPOSITORY'] = 'ai-workspace-infra/platform-ops-toolkit'
        for entry in ('deploy.sh', 'deploy_boundary.sh'):
            result = subprocess.run(['bash', str(SCRIPTS / entry), 'auth'], env=self.env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('guarded Edge Gateway dispatch', result.stderr)
            self.assertNotIn('[Vault]', result.stdout)

    def test_legacy_production_declaration_also_requires_authorization(self):
        self.config['spec']['runtime']['routing']['dns'] = {}
        self.plan.write_text(json.dumps(self.config))
        self.assertNotEqual(self.guard().returncode, 0)

    def test_same_run_fresh_authorization_accepts_only_the_same_plan(self):
        self.authorize(); self.assertEqual(self.guard().returncode, 0)
        self.plan.write_text(self.plan.read_text() + '\n')
        self.assertNotEqual(self.guard().returncode, 0)

    def test_wrong_attempt_revision_or_stale_authorization_rejected(self):
        for changes in ({'run_attempt': '2'}, {'revision': 'b'*40}, {'verified_at': time.time()-601}):
            self.authorize(**changes)
            self.assertNotEqual(self.guard().returncode, 0)

    def test_authorization_created_only_after_receipt_recheck(self):
        script = (SCRIPTS / 'require_live_cutover.sh').read_text()
        self.assertLess(script.index('bash .github/scripts/verify_cutover.sh'), script.index("with output.open('x')"))


if __name__ == '__main__': unittest.main()
