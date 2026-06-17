# Model Catalog & VRAM Sizing — H100 NVL (94 GB), single GPU

This reference helps you pick a HuggingFace model that fits one **H100 NVL (94 GB)** GPU and
configure SGLang with the **correct parser/launch flags** for that model family. It backs Step 1
of [the skill](../SKILL.md).

> Default VM is `Standard_NC40ads_H100_v5` (1× H100 NVL, 94 GB). For models that don't fit, the
> 2-GPU `Standard_NC80adis_H100_v5` (188 GB, `--tp 2`) is an option but needs an 80-vCPU quota.

## VRAM rule of thumb

```
weights_GB ≈ params_billions × bytes_per_param
  BF16/FP16 = 2.0   ·   FP8 = 1.0   ·   INT4/AWQ/GPTQ ≈ 0.5
```

Then leave headroom on the 94 GB card:
- **CUDA graphs + activations + fragmentation**: ~10–20 % of the weight footprint.
- **KV cache**: everything left in the static pool (`--mem-fraction-static 0.85` ≈ ~80 GB usable).
  More free VRAM after weights → longer context and/or more concurrent requests.

Practical verdicts on 94 GB:
- **≤ ~45 GB weights** → comfortable, room for long context (128K+).
- **~45–70 GB weights** → fits, but cap `--context-length` and `--max-running-requests`.
- **> ~75 GB weights** → too tight for one card; use FP8/quantized or go `--tp 2`.

## Curated models that fit 94 GB

Always confirm the exact model id and revision on HuggingFace before deploying; sizes below are
approximate. "Gated" models require `export HF_TOKEN=hf_…`.

| Model id | Params | Quant | ~Weights | Fit on 94 GB | Profile | Gated |
|----------|--------|-------|----------|--------------|---------|-------|
| `Qwen/Qwen3.6-35B-A3B-FP8` *(default)* | 35B MoE (A3B active) | FP8 | ~34 GB | ✅ ample, 192K ctx | **A** | no |
| `Qwen/Qwen3-32B` | 32B dense | BF16 | ~64 GB | ✅ tight, reduce ctx | **B** | no |
| `Qwen/Qwen3-30B-A3B` | 30B MoE | BF16 | ~60 GB | ✅ | **B** | no |
| `Qwen/Qwen2.5-Coder-32B-Instruct` | 32B dense | BF16 | ~64 GB | ✅ tight | **C** | no |
| `Qwen/Qwen2.5-32B-Instruct` | 32B dense | BF16 | ~64 GB | ✅ tight | **C** | no |
| `Qwen/Qwen2.5-14B-Instruct` | 14B dense | BF16 | ~28 GB | ✅ ample | **C** | no |
| `Qwen/Qwen2.5-7B-Instruct` | 7B dense | BF16 | ~15 GB | ✅ ample | **C** | no |
| `mistralai/Mistral-Small-24B-Instruct-2501` | 24B dense | BF16 | ~47 GB | ✅ | **E** | no |
| `google/gemma-2-27b-it` | 27B dense | BF16 | ~54 GB | ✅ | **F** | yes |
| `meta-llama/Llama-3.3-70B-Instruct` | 70B dense | **FP8** | ~70 GB | ⚠️ very tight, small ctx | **D** | yes |

> 70B+ in BF16 (~140 GB) does **not** fit one card — use an FP8 build or `--tp 2`. If a vendor FP8
> checkpoint isn't available, SGLang can quantize on the fly with `--quantization fp8`.

## Flag profiles

Set `MODEL_PATH` in [`config.sh`](../../../../deploy/config.sh), then make the SGLang launch flags in
[`deploy/05-run-sglang.sh`](../../../../deploy/05-run-sglang.sh) match the model's profile. The
repo's script ships with **Profile A**. Common base flags stay for all profiles:
`--host 0.0.0.0 --port $SGLANG_PORT --mem-fraction-static 0.85 --chunked-prefill-size 8192
--enable-metrics --trust-remote-code` and `--tp $TP_SIZE`.

### Profile A — Qwen3.6 hybrid (Mamba2 + MoE + MTP) — *repo default*
Keep the script as-is:
```
--context-length 196608 --max-running-requests 4
--reasoning-parser qwen3 --tool-call-parser qwen3_coder
--attention-backend fa3 --sampling-backend flashinfer
--mamba-backend triton --mamba-scheduler-strategy extra_buffer
--speculative-algorithm NEXTN --speculative-num-steps 1
--speculative-eagle-topk 1 --speculative-num-draft-tokens 2
```
Env: `SGLANG_ALLOW_OVERWRITE_LONGER_CONTEXT_LEN=1`, `SGLANG_ENABLE_SPEC_V2=1`, `TOKENIZERS_PARALLELISM=false`.

### Profile B — Qwen3 dense / MoE (reasoning, non-hybrid)
**Remove** all `--mamba-*` and `--speculative-*`/NEXTN flags and the `SGLANG_ENABLE_SPEC_V2` env.
```
--context-length 32768 --max-running-requests 8
--reasoning-parser qwen3 --tool-call-parser qwen25
--attention-backend fa3 --sampling-backend flashinfer
```
(Qwen3-Coder variants: use `--tool-call-parser qwen3_coder`.)

### Profile C — Qwen2.5 / Qwen2.5-Coder (non-reasoning)
Drop `--reasoning-parser` (these don't emit `<think>`), drop mamba/speculative flags.
```
--context-length 32768 --max-running-requests 8 --tool-call-parser qwen25
--attention-backend fa3 --sampling-backend flashinfer
```

### Profile D — Llama 3.x
```
--context-length 32768 --max-running-requests 8 --tool-call-parser llama3
```
Gated → set `HF_TOKEN`. For 70B use an FP8 checkpoint or add `--quantization fp8`; start with a
small context (e.g. 8192–16384) and raise it if VRAM allows.

### Profile E — Mistral
```
--context-length 32768 --max-running-requests 8 --tool-call-parser mistral
```

### Profile F — Gemma 2
```
--context-length 8192 --max-running-requests 8 --tool-call-parser pythonic
```
Gated → set `HF_TOKEN`. Gemma 2 caps context at 8K.

> **Parser names can change between SGLang releases.** Verify the supported values for the running
> image with: `docker run --rm $SGLANG_IMAGE python3 -m sglang.launch_server --help | grep -A2 -iE 'tool-call-parser|reasoning-parser'`.
> Only **instruct/chat** checkpoints reliably emit tool calls — base/pretrained weights do not.

## Validating a custom model

When the user names a model not in the table:

1. **Find params + native dtype** on the HuggingFace model card (and whether it's gated).
2. **Estimate weights**: `params_B × bytes_per_param` (see rule of thumb). If > ~75 GB, choose an
   FP8/quantized build, add `--quantization fp8`, or use `--tp 2` on the 2-GPU SKU.
3. **Pick the profile** by family (Qwen3.6 hybrid → A; Qwen3 → B; Qwen2.5 → C; Llama → D;
   Mistral → E; Gemma → F; anything else → start from C and set the matching `--tool-call-parser`,
   verifying the name via `--help`).
4. **Set context to fit**: start conservative (e.g. 32768). If `Capture cuda graph` / KV-cache
   init OOMs, lower `--context-length` and/or `--max-running-requests`, or lower `--mem-fraction-static`.
5. **Confirm tool calling** with [`test-tool-calling.ps1`](../../../../deploy/test-tool-calling.ps1)
   after updating its `$Model` to the served id. A pass shows `finish_reason: tool_calls`.
