import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

CHART = pathlib.Path(sys.argv.pop()).resolve()


class OIDCRendering(unittest.TestCase):
    def render(self, values):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / 'templates').mkdir()
            shutil.copytree(CHART, root / 'charts' / 'homelab-common')
            (root / 'Chart.yaml').write_text('apiVersion: v2\nname: example\nversion: 1.0.0\n')
            (root / 'templates' / 'oidc.yaml').write_text('{{ include "common.oidc" (list . .Values) }}')
            base = {'globals': {'domain': 'example.com', 'authentik': {'ref': {'name': 'authentik', 'namespace': 'shared'}}}, 'subdomain': 'example', 'oidc': {'enabled': True, 'redirectUris': ['/callback']}}
            for key, value in values.items():
                if isinstance(value, dict) and key in base:
                    base[key].update(value)
                else:
                    base[key] = value
            (root / 'values.yaml').write_text(json.dumps(base))
            output = subprocess.check_output(['helm', 'template', 'example', str(root), '--namespace', 'prod'], text=True)
            parsed = subprocess.check_output(['yq', '-o=json', '-I=0', 'select(. != null)', '-'], input=output, text=True)
            return [json.loads(line) for line in parsed.splitlines()]

    def test_own_group_is_always_included_and_members_are_single_owned(self):
        members = [{'id': 7, 'uuid': 'd8359fc2-7656-45d2-a22e-5cbd13cb941f'}]
        resources = self.render({'oidc': {'group': {'members': members}, 'allowedGroups': [{'name': 'admin', 'namespace': 'shared'}]}})
        groups = [r for r in resources if r['kind'] == 'AuthentikGroup']
        clients = [r for r in resources if r['kind'] == 'AuthentikClient']
        self.assertEqual(len(groups), 1)
        self.assertEqual(groups[0]['spec']['members'], members)
        self.assertEqual(clients[0]['spec']['allowedGroups'], [{'name': 'example', 'namespace': 'prod'}, {'name': 'admin', 'namespace': 'shared'}])
        self.assertEqual(clients[0]['spec']['redirectUris'], ['https://example.example.com/callback'])

    def test_empty_additional_groups_still_requires_app_group(self):
        resources = self.render({'oidc': {'allowedGroups': []}})
        group = next(r for r in resources if r['kind'] == 'AuthentikGroup')
        client = next(r for r in resources if r['kind'] == 'AuthentikClient')
        self.assertEqual(group['spec']['members'], [])
        self.assertEqual(client['spec']['allowedGroups'], [{'name': 'example', 'namespace': 'prod'}])

    def test_disabled_oidc_has_no_identity_resources(self):
        self.assertEqual(self.render({'oidc': {'enabled': False}}), [])


unittest.main()
