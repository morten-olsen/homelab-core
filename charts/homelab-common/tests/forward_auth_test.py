import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

CHART = pathlib.Path(sys.argv.pop()).resolve()


class ForwardAuthRendering(unittest.TestCase):
    def render(self, values, template='{{ include "common.forwardAuth" (list . .Values) }}{{ include "common.virtualService" (list . .Values) }}'):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / 'templates').mkdir()
            shutil.copytree(CHART, root / 'charts' / 'homelab-common')
            (root / 'Chart.yaml').write_text('apiVersion: v2\nname: example\nversion: 1.0.0\n')
            (root / 'templates' / 'app.yaml').write_text(template)
            base = {
                'globals': {'domain': 'example.com', 'authentik': {'ref': {'name': 'authentik', 'namespace': 'shared'}},
                            'istio': {'gateways': {'private': 'shared/private'}}},
                'subdomain': 'example',
                'service': {'ports': [{'name': 'http', 'port': 80}]},
                'probe': {'path': '/ping'},
                'virtualService': {'enabled': True, 'gateways': {'private': True}},
                'forwardAuth': {'enabled': True, 'excludePaths': ['/api/*', '/ping']},
            }
            for key, value in values.items():
                if isinstance(value, dict) and isinstance(base.get(key), dict):
                    base[key].update(value)
                else:
                    base[key] = value
            (root / 'values.yaml').write_text(json.dumps(base))
            result = subprocess.run(['helm', 'template', 'example', str(root), '--namespace', 'prod'], text=True, capture_output=True)
            if result.returncode != 0:
                raise RuntimeError(result.stderr)
            parsed = subprocess.check_output(['yq', '-o=json', '-I=0', 'select(. != null)', '-'], input=result.stdout, text=True)
            return [json.loads(line) for line in parsed.splitlines()]

    def kinds(self, resources, kind):
        return [r for r in resources if r['kind'] == kind]

    def test_provider_policy_group_and_callback_route(self):
        resources = self.render({'forwardAuth': {'allowedGroups': [{'name': 'admin', 'namespace': 'shared'}]}})
        group, = self.kinds(resources, 'AuthentikGroup')
        provider, = self.kinds(resources, 'AuthentikProxyProvider')
        policy, = self.kinds(resources, 'AuthorizationPolicy')
        service, = self.kinds(resources, 'VirtualService')
        self.assertEqual(group['metadata']['name'], 'example')
        self.assertEqual(provider['metadata']['name'], 'example-forward-auth')
        self.assertEqual(provider['spec']['externalHost'], 'https://example.example.com')
        self.assertEqual(provider['spec']['accessTokenValidity'], 'hours=8')
        self.assertEqual(provider['spec']['allowedGroups'], [{'name': 'example', 'namespace': 'prod'}, {'name': 'admin', 'namespace': 'shared'}])
        self.assertEqual(policy['spec']['action'], 'CUSTOM')
        self.assertEqual(policy['spec']['provider'], {'name': 'authentik'})
        self.assertEqual(policy['spec']['rules'], [{'to': [{'operation': {'notPaths': ['/api/*', '/ping']}}]}])
        self.assertTrue(policy['spec']['selector']['matchLabels'])
        first, default = service['spec']['http']
        self.assertEqual(first['match'], [{'uri': {'prefix': '/outpost.goauthentik.io/'}}])
        self.assertEqual(first['route'][0]['destination']['host'], 'authentik.shared.svc.cluster.local')
        self.assertEqual(default['route'][0]['destination']['host'], 'example')

    def test_no_exclusions_checks_every_request(self):
        policy, = self.kinds(self.render({'forwardAuth': {'excludePaths': []}}), 'AuthorizationPolicy')
        self.assertEqual(policy['spec']['rules'], [{}])

    def test_oidc_owns_the_shared_group(self):
        resources = self.render({'oidc': {'enabled': True, 'redirectUris': ['/cb']}})
        self.assertEqual(self.kinds(resources, 'AuthentikGroup'), [])
        self.assertEqual(len(self.kinds(resources, 'AuthentikProxyProvider')), 1)

    def test_disabled_renders_nothing_and_no_callback_route(self):
        resources = self.render({'forwardAuth': {'enabled': False}})
        service, = self.kinds(resources, 'VirtualService')
        self.assertEqual(len(resources), 1)
        self.assertEqual(len(service['spec']['http']), 1)

    def test_probe_without_excluded_path_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, 'forwardAuth requires probe.path'):
            self.render({'probe': {'path': ''}})
        self.assertEqual(len(self.kinds(self.render({'probe': {'enabled': False}}), 'AuthorizationPolicy')), 1)


unittest.main()
