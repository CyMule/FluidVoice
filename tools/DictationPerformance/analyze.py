"""Validate paired replay results; report internal timing, not screen-paint latency."""
from pathlib import Path
import collections,json,math,statistics,sys
root=Path(__file__).resolve().parents[2]/'DerivedData/DictationPerformance'
source=Path(sys.argv[1]) if len(sys.argv)>1 else root/'results.jsonl'
rows=[json.loads(l) for l in source.read_text().splitlines() if l.startswith('{')]
assert rows[-1]['kind']=='done', 'Incomplete replay run'
runs=[r for r in rows if r['kind']=='replay']
assert runs and all(r['exactMatchBatch'] for r in runs), 'Final transcript changed'
pairs=collections.defaultdict(dict)
for r in runs:
 pair=pairs[(r['fixtureID'],r['round'])]
 assert r['policy'] not in pair
 pair[r['policy']]=r
 assert all(b['sampleCount']>a['sampleCount'] for a,b in zip(r['events'],r['events'][1:]))
 assert all(b['audioMs']+0.1>=a['readyMs'] for a,b in zip(r['events'],r['events'][1:])), 'Overlapping inference'
assert all(set(p)=={'current','adaptive'} for p in pairs.values()), 'Unpaired run'
def stats(xs):
 xs=sorted(xs)
 return dict(n=len(xs),median=round(statistics.median(xs),2),p95=round(xs[math.ceil(.95*len(xs))-1],2),max=round(xs[-1],2)) if xs else None
summary=dict(scope='Provider-only real-time replay; no microphone, dictionary, UI, paste, or human WER assessment',
 pairs=len(pairs),finalTranscriptComparisons=len(runs),exactMatches=sum(r['exactMatchBatch'] for r in runs),
 fixtures=sorted(set(r['fixtureID'] for r in runs)),thermalStates=sorted(set(r['thermalState'] for r in runs)),policies={})
for policy in ['current','adaptive']:
 rs=[r for r in runs if r['policy']==policy]
 first=[];gaps=[];work=[]
 for r in rs:
  nonempty=[e for e in r['events'] if e['text'].strip()]
  if nonempty:first.append(nonempty[0]['readyMs'])
  if len(r['events'])>1:gaps.append(statistics.median(b['readyMs']-a['readyMs'] for a,b in zip(r['events'],r['events'][1:])))
  work.append(r['previewWorkMs']/r['audioSeconds']/10)
 summary['policies'][policy]=dict(firstResultMs=stats(first),perRunMedianPreviewGapMs=stats(gaps),
  stopToFinalMs=stats([r['stopToFinalMs'] for r in rs]),previewWorkPercent=stats(work))
b=summary['policies']['current'];a=summary['policies']['adaptive']
summary['acceptanceChecks']={
 'firstPreviewAtLeast150msEarlier':a['firstResultMs']['median']<=b['firstResultMs']['median']-150,
 'previewGapAtLeast25PercentShorter':a['perRunMedianPreviewGapMs']['median']<=b['perRunMedianPreviewGapMs']['median']*.75,
 'stopP95Within50msOfBaseline':a['stopToFinalMs']['p95']<=b['stopToFinalMs']['p95']+50,
 'allFinalTranscriptsIdentical':True,
}
summary['pairedStopDifferencesMs']=stats([p['adaptive']['stopToFinalMs']-p['current']['stopToFinalMs'] for p in pairs.values()])
root.mkdir(parents=True,exist_ok=True)
(root/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary,indent=2))
if not all(summary['acceptanceChecks'].values()):sys.exit(2)
