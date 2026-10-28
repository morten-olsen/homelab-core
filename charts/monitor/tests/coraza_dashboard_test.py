"""Exercise rendered dashboard queries at inventory and scrape failure seams."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

chart = Path(__file__).resolve().parents[1]
render = subprocess.check_output([
    'helm', 'template', 'monitor', str(chart), '--namespace', 'monitoring',
    '--show-only', 'templates/grafana-dashboard-coraza.yaml'
], text=True)
cm = json.loads(subprocess.check_output(['yq', '-o=json', '.'], input=render, text=True))
dash = json.loads(cm['data']['homelab-coraza.json'])
assert cm['metadata']['labels']['grafana_dashboard'] == '1'
assert dash['timezone'] == 'utc' and dash['time']['from'] == 'now-24h'
panels = {p['id']: p for p in dash['panels']}
snapshot = panels[3]['targets'][0]['expr']
assert not any('istio_request_messages_total' in t.get('expr', '') or 'istio_response_messages_total' in t.get('expr', '') for p in dash['panels'] for t in p.get('targets', []))
assert all(p.get('fieldConfig', {}).get('defaults', {}).get('custom', {}).get('spanNulls') is not True for p in dash['panels'])

# One live healthy pod, one missing target, one down scrape with cached success,
# one successfully scraped source missing its module metrics, and an IP rollover.
# A departed pod's counters must not turn into a current table row.
series = [{'series': 'up{job="kube-state-metrics",instance="ksm"}', 'values': '1+0x12'}]
for pod, ip in [('ok','10.0.0.1'),('missing','10.0.0.2'),('down','10.0.0.3'),('no-module','10.0.0.4'),('new-ip','10.0.0.5')]:
    series.append({'series': f'kube_pod_info{{namespace="istio-ingress",pod="gateway-{pod}",pod_ip="{ip}",job="kube-state-metrics",instance="ksm"}}', 'values': '1+0x12'})
for pod, ip, up in [('ok','10.0.0.1',1),('down','10.0.0.3',0),('no-module','10.0.0.4',1),('new-ip','10.0.0.99',1),('departed','10.0.0.6',1)]:
    labels=f'job="monitoring/istio-gateway",pod="gateway-{pod}",instance="{ip}:15020"'
    series.append({'series': 'up{'+labels+'}', 'values': f'{up}+0x12'})
    if pod == 'no-module':
        continue
    for name, result, values in [('waf_filter_tx_total','', '100+1x12'),('istio_agent_wasm_cache_entries','', '1+0x12'),('istio_agent_wasm_remote_fetch_count',',result="success"','3+0x12'),('istio_agent_wasm_config_conversion_count',',result="success"','5+0x12')]:
        series.append({'series': name+'{'+labels+result+'}', 'values': values})
series.append({'series':'istio_agent_wasm_remote_fetch_count{job="monitoring/istio-gateway",pod="gateway-ok",instance="10.0.0.1:15020",result="download_failure"}', 'values':'2+0x12'})
expr_tests = [
    {'expr':f'count by (pod) (({snapshot}) != ({snapshot}))', 'eval_time':'3m', 'exp_samples':[
        {'labels':'{pod="gateway-missing"}', 'value':5},
        {'labels':'{pod="gateway-new-ip"}', 'value':5},
        {'labels':'{pod="gateway-down"}', 'value':4},
    ]},
    {'expr':f'({snapshot}) == -1', 'eval_time':'3m', 'exp_samples':[
        {'labels':f'{{check="{field}",pod="gateway-no-module"}}', 'value':-1}
        for field in ['Cache entries','Fetch success (proxy start)','Convert success (proxy start)']
    ]},
    {'expr':f'({snapshot}) == 2', 'eval_time':'3m', 'exp_samples':[
        {'labels':'{check="Fetch issue: download_failure",pod="gateway-ok"}', 'value':2}
    ]},
]
# An unavailable inventory collector must not leave stale rows labelled healthy.
failed_inventory = [dict(s, values='0+0x12') if s['series'].startswith('up{job="kube-state-metrics"') else s for s in series]
tests = [{'interval':'15s','input_series':series,'promql_expr_test':expr_tests},
         {'interval':'15s','input_series':failed_inventory,'promql_expr_test':[{'expr':f'absent({snapshot})','eval_time':'3m','exp_samples':[{'labels':'{}','value':1}]}]}]
tests.append({'interval':'15s','input_series':[{'series':'up{job="kube-state-metrics",instance="ksm"}','values':'1+0x12'}], 'promql_expr_test':[
    {'expr':f'absent({panels[9]["targets"][0]["expr"]})', 'eval_time':'3m','exp_samples':[{'labels':'{}','value':1}]}]})
activity = panels[2]['targets'][0]['expr'].replace('$__rate_interval', '1m')
labels = 'job="monitoring/istio-gateway",pod="gateway-test",instance="10.0.0.1:15020"'
for values, expected in [('100 101 102 103 104 105 106 107 108 109 0 1 2', 1), ('100+0x12', 0)]:
    tests.append({'interval':'15s', 'input_series':[
        {'series':'up{'+labels+'}', 'values':'1+0x12'},
        {'series':'waf_filter_tx_total{'+labels+'}', 'values':values},
    ], 'promql_expr_test':[{'expr':f'({activity}) > bool 0', 'eval_time':'3m',
                           'exp_samples':[{'labels':'{}','value':expected}]}]})
tests.append({'interval':'15s','input_series':[], 'promql_expr_test':[
    {'expr':f'absent({activity})','eval_time':'3m','exp_samples':[{'labels':'{}','value':1}]}]})
with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp)/'queries.json'
    path.write_text(json.dumps({'evaluation_interval':'15s','tests':tests}))
    subprocess.run([os.environ.get('PROMTOOL','promtool'),'test','rules',str(path)],check=True)
print('ok: current inventory, missing/down scrapes, missing module, observed errors and IP rollover')
