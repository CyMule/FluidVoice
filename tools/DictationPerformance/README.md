# Dictation performance replay

This harness measures Parakeet v2 preview scheduling using the app's optimized
FluidAudio dependency and the production `DictationPreviewCadence` policy.
It uses local models, built-in fixtures, and speech synthesized to files by macOS.
It does not record the microphone, send audio to a service, or train a model.

## Reproduce on Apple Silicon

Install the Parakeet v2 model through Murmur first. From the repository root:

```sh
FLUIDVOICE_CONFIGURATION=Release ./build.sh public
python3 tools/DictationPerformance/build.py
python3 tools/DictationPerformance/prepare-fixtures.py
LLVM_PROFILE_FILE=DerivedData/DictationPerformance/replay.profraw \
  DerivedData/DictationPerformanceReplay \
  Sources/Fluid/Resources/speech-model-check.pcm \
  DerivedData/DictationPerformance/manifest.json \
  > DerivedData/DictationPerformance/results.jsonl
python3 tools/DictationPerformance/analyze.py
```

The signed build requires an installed Apple Development certificate; use
`./build.sh unsigned` with the same configuration environment variable if needed.
The link script expects Xcode's Release products in `DerivedData` and the pinned
package graph. No Python packages are required. Do not compile another build or
run dictation during the replay; the suite takes about five minutes of paced audio.
`prepare-fixtures.py` uses the macOS Samantha voice; synthesis can differ between
OS versions. Fixture SHA-256 values are captured in each result.

Passing only the stock PCM (without a manifest) runs the original exploratory
batch, fixed-deadline, and exact-cache experiments. That mode is not the paired
adaptive acceptance suite and should not be fed to `analyze.py`.

The focused app regression command is:

```sh
xcodebuild test -project Fluid.xcodeproj -scheme Fluid -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath DerivedData \
  -only-testing:FluidDictationIntegrationTests/DirectAudioReliabilityTests \
  -only-testing:FluidDictationIntegrationTests/ParakeetSpeechModelCatalogTests \
  -only-testing:FluidDictationIntegrationTests/DictationE2ETests/testDictionaryCanonicalReplacementDoesNotExpandAgain \
  -only-testing:FluidDictationIntegrationTests/DictationE2ETests/testDictionaryCanonicalProtectionPreservesOtherRulesAndLiteralText \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

## Method and acceptance criteria

Eight fixture configurations produce 22 paired scenarios and 44 replays: two
repository recordings, five synthetic phrases, and a repeated recording crossing
the 15-second incremental-session threshold. Phrases include numbers, negation,
correction, a product name, and a short reply. Synthetic speech is a regression
check, not a representative corpus of natural speech.

Audio arrives at real-time speed. Both policies use the same PCM, model, minimum
one-second input, batch/incremental transition, and finalization path. Order is
alternated and trailing silence varies by round to change the phase of the stop
relative to inference. The baseline waits 600 ms after every decode; the adaptive
policy uses the production helper. It targets an ordinary inference work fraction
of 25% with 200–600 ms idle waits, reacts immediately to slow decodes, and recovers
gradually. Under serious/critical thermal pressure the app uses the baseline.

The analyzer requires all final transcripts to equal a same-audio full-batch
reference, first preview median at least 150 ms earlier, preview gap median at
least 25% shorter, and stop-to-final p95 no more than 50 ms above baseline.
These gates were chosen before the acceptance run completed.

`firstResultMs` is the first nonempty provider result; `perRunMedianPreviewGapMs`
summarizes each replay's median interval between results (including empty results).
Replays with only one preview have no gap, so the two policies can have different
gap sample counts. `stopToFinalMs` includes waiting for any in-flight preview and
final decoding. `previewWorkPercent` is inference wall time divided by audio time,
not CPU utilization, energy, or battery consumption. p95 uses nearest rank.

## Recorded result

`results/m1-max-2026-10-08.jsonl` contains the raw structured events;
`results/m1-max-2026-10-08-summary.json` contains the analyzer output. This was an
Apple M1 Max, 64 GB, macOS 26.5.2, low power mode off, nominal thermal state,
Parakeet TDT 0.6B v2 Core ML, FluidAudio revision
`eb1e6628998e47022799d305b52c2680d3576801`. The app baseline was `6aa23d28`.

- Median first preview: 1,340 ms → 1,104 ms (236 ms earlier).
- Median preview interval: 721 ms → 353 ms (51% shorter).
- Stop-to-final p95: 145 ms → 164 ms; observed maximum: 166 ms → 167 ms.
- Median preview work fraction: 9.7% → 18.9%.
- All 44 final transcripts exactly matched their batch references.
- 67 focused app regression tests passed, including five cadence tests.

This is a small warm-model replay experiment, not a claim of statistically proven
noninferiority or world-leading performance. It does not measure microphone
startup, rendered preview frames, the user dictionary, AI postprocessing, or text
insertion. Exact matching detects a change from the reference; it does not show
that the reference itself is correct. Natural speech, accents, noise, Bluetooth,
cold launch, heavy load, long sessions, and power consumption need broader checks.

The app also emits one `PREVIEW_SUMMARY` log per recording with completed previews.
Its first-result clock starts at recording setup and ends at preview assignment;
it is explicitly not a screen-paint measurement. Existing delivery logs can report
paste dispatch before the target app actually shows the text. A future end-to-end
benchmark should timestamp first captured audio and observe target-field content
and rendered frames before making user-visible latency claims.

## Next experiments

Keep the final high-quality path as the reference. Evaluate persistent streaming
sessions, speculative finalization of identical audio snapshots, and UI/paste
latency separately. Existing Parakeet long-audio sessions already reuse completed
windows. A naive fixed 200 ms deadline was rejected in initial exploration because
it increased stop tails substantially. Model replacement, quantization, precision
changes, or early final commits require a real speech quality corpus and a separate
acceptance decision; this change does none of those.
