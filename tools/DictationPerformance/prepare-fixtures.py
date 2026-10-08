"""Create reproducible synthetic regression fixtures without using the microphone."""
from pathlib import Path
import json, subprocess, wave
repo=Path(__file__).resolve().parents[2]
root=repo/'DerivedData/DictationPerformance'
root.mkdir(parents=True,exist_ok=True)
fixtures=[]
def wav_pcm(path,out):
 with wave.open(str(path),'rb') as f:
  assert (f.getnchannels(),f.getsampwidth(),f.getframerate())==(1,2,16000)
  out.write_bytes(f.readframes(f.getnframes()))
stock=repo/'Sources/Fluid/Resources/speech-model-check.pcm'
fixtures.append(dict(id='stock',path=str(stock),text='',rounds=3))
hello=root/'hello.pcm'
wav_pcm(repo/'Tests/FluidDictationIntegrationTests/Resources/dictation_fixture.wav',hello)
fixtures.append(dict(id='hello',path=str(hello),text='',rounds=3))
phrases={
 'numbers':'The total is forty seven dollars and ninety five cents, not seventy four dollars.',
 'negation':'Do not send the email until I have reviewed the final version.',
 'correction':'Schedule the meeting for Tuesday. Actually, make that Thursday at three thirty.',
 'names':'Open PostHog and compare the conversion rate with last week.',
 'short':'Yes, that is correct.',
}
for name,text in phrases.items():
 aiff=root/(name+'.aiff'); wav=root/(name+'.wav'); pcm=root/(name+'.pcm')
 subprocess.run(['say','-v','Samantha','-r','180','-o',str(aiff),text],check=True)
 subprocess.run(['afconvert','-f','WAVE','-d','LEI16@16000','-c','1',str(aiff),str(wav)],check=True)
 wav_pcm(wav,pcm)
 fixtures.append(dict(id=name,path=str(pcm),text=text,source='macOS Samantha synthetic speech',rounds=3))
fixtures.append(dict(id='long-stock',path=str(stock),text='',repetitions=5,rounds=1))
(root/'manifest.json').write_text(json.dumps(fixtures,indent=2)+'\n')
print(root/'manifest.json')
print('Total paced audio seconds:',sum((Path(f['path']).stat().st_size/32000*f.get('repetitions',1)+.332)*f['rounds']*2 for f in fixtures))
