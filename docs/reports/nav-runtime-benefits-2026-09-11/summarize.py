import json, pathlib, statistics, sys
root = pathlib.Path(sys.argv[1])
rows = {}
for pair in range(1,6):
    for probe in ['danger','ray']:
        a = json.loads((root/f'{pair}-baseline-{probe}.json').read_text())
        b = json.loads((root/f'{pair}-candidate-{probe}.json').read_text())
        assert len(a['rows']) == len(b['rows'])
        for ar,br in zip(a['rows'], b['rows']):
            assert ar['name']==br['name'] and ar['details']==br['details'], (ar,br)
            rows.setdefault(ar['name'],[]).append({'pair':pair, 'baseline_median_ns':ar['median_ns'], 'candidate_median_ns':br['median_ns'], 'median_ratio':br['median_ns']/ar['median_ns'], 'p95_ratio':br['p95_ns']/ar['p95_ns']})
summary = {}
for name, pairs in rows.items():
    ratio=statistics.median(p['median_ratio'] for p in pairs)
    summary[name]={'pairs':pairs, 'paired_median_ratio':ratio, 'paired_p95_ratio':statistics.median(p['p95_ratio'] for p in pairs), 'baseline_median_ns':statistics.median(p['baseline_median_ns'] for p in pairs), 'candidate_median_ns':statistics.median(p['candidate_median_ns'] for p in pairs), 'pass_no_regression':ratio<=1.05}
assert all(r['pass_no_regression'] for r in summary.values())
assert min(r['paired_median_ratio'] for r in summary.values())<0.95
(root/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary,indent=2))
