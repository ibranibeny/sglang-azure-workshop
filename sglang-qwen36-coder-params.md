## sglang Qwen3.6-Coder server parameters — runtime reference

Dokumentasi semua parameter yang dipakai pada
[scripts/sglang-qwen36-coder.service](sglang-qwen36-coder.service) dan
alasannya **terkait penggunaan oleh GitHub Copilot Chat / Agent** via custom
endpoint BYOK.

Semua deskripsi parameter mengikuti
[docs sglang official](https://docs.sglang.io/docs/advanced_features/server_arguments)
(versi yang dipakai: **0.5.10.post1**, di-fetch 2026-06-09). Setiap baris
"Why for Copilot" adalah justifikasi berdasarkan pola request VS Code Copilot
yang terverifikasi (sumber: source `extensions/copilot/dist/extension.js` dan
test empiris).

---

## Snapshot lingkungan

| Item | Nilai |
| --- | --- |
| Tanggal verifikasi | 2026-06-09 |
| Host | `vm-sglang-h100` (Azure Standard_NC40ads_H100_v5, indonesiacentral) |
| GPU | 1× NVIDIA H100 NVL 95830 MiB |
| Driver | 575.57.08 (CUDA runtime cap 12.9) |
| sglang | 0.5.10.post1 (di-pin; 0.5.11+ butuh driver ≥ 580 / CUDA 13) |
| Model | Qwen/Qwen3.6-35B-A3B-FP8 (35 B params, hybrid Mamba2 + Transformer, 256-experts MoE top-8, FP8 e4m3) |
| Snapshot ID | `95a723d08a9490559dae23d0cff1d9466213d989` |
| Service unit | `/etc/systemd/system/sglang-qwen36-coder.service` |
| Endpoint | `http://48.193.44.221:8000` |
| Served model id | `Qwen3.6-35B-A3B-FP8` |

---

## Komando launch lengkap (live di VM)

```bash
/mnt/sglang-data/sglang/bin/python -m sglang.launch_server \
  --model-path /mnt/nvme/huggingface/hub/models--Qwen--Qwen3.6-35B-A3B-FP8/snapshots/95a723d08a9490559dae23d0cff1d9466213d989 \
  --served-model-name Qwen3.6-35B-A3B-FP8 \
  --host 0.0.0.0 \
  --port 8000 \
  --tp-size 1 \
  --context-length 196608 \
  --mem-fraction-static 0.85 \
  --max-running-requests 4 \
  --chunked-prefill-size 8192 \
  --reasoning-parser qwen3 \
  --tool-call-parser qwen3_coder \
  --attention-backend fa3 \
  --sampling-backend flashinfer \
  --mamba-backend triton \
  --mamba-scheduler-strategy extra_buffer \
  --speculative-algorithm NEXTN \
  --speculative-num-steps 1 \
  --speculative-eagle-topk 1 \
  --speculative-num-draft-tokens 2 \
  --enable-metrics \
  --trust-remote-code \
  --api-key ${API_KEY}
```

---

## Parameter inti (CLI flags)

### Model & tokenizer

| Flag | Nilai | Default sglang | Why for Copilot |
| --- | --- | --- | --- |
| `--model-path` | snapshot lokal di `/mnt/nvme/...` | required | Snapshot HF di NVMe ephemeral. ExecStartPre re-download otomatis jika VM deallocate menghapus NVMe. |
| `--served-model-name` | `Qwen3.6-35B-A3B-FP8` | None (pakai path) | VS Code Copilot kirim `model: t.id` di body. Field `id` di `chatLanguageModels.json` HARUS persis sama dengan ini, kalau tidak sglang reject. |
| `--trust-remote-code` | enabled | False | Wajib untuk model Qwen3.6 (architecture `Qwen3_5MoeForConditionalGeneration` belum native di transformers stock, butuh kode custom dari HF repo). |

### HTTP server & auth

| Flag | Nilai | Default | Why for Copilot |
| --- | --- | --- | --- |
| `--host` | `0.0.0.0` | `127.0.0.1` | Endpoint diakses dari laptop developer via Internet. Listen di-restrict di network layer (NSG allowlist IP /32), BUKAN di host. |
| `--port` | `8000` | `30000` | Port reservation existing infra di VM (vLLM lama jalan di 8000 juga). |
| `--api-key` | dari env `API_KEY` | None | Wajib enable supaya request tanpa `Authorization: Bearer <key>` ditolak HTTP 401. Copilot kirim header ini otomatis berdasarkan API key di VS Code secret storage. |

### Parallelism

| Flag | Nilai | Default | Why for Copilot |
| --- | --- | --- | --- |
| `--tp-size` | `1` | `1` | Hanya 1 H100 NVL. Tensor parallel >1 butuh multi-GPU. |

### Context & memory budget

| Flag | Nilai | Default | Why for Copilot |
| --- | --- | --- | --- |
| `--context-length` | `196608` (192 K) | dari model config (262 144) | Model native 256K, tapi 256K × 4 running requests akan habiskan KV cache + GPU memory. 192K = balance: cukup besar untuk Copilot workspace context (Qwen rekomen ≥ 128K untuk preserve thinking quality), hemat ~34 GB GPU memory. Math: chat config Copilot kita `maxInputTokens 131072 + maxOutputTokens 65536 = 196608`, fit persis. |
| `--mem-fraction-static` | `0.85` | `0.9` | Alokasi 85% × 96 GB ≈ 81 GB untuk weights + KV cache pool. Sisa 15% (~14 GB) buat activations, CUDA graph pad, DeepGEMM JIT workspace. 0.9 default kadang OOM saat capture CUDA graph di model hybrid Mamba. |
| `--max-running-requests` | `4` | None (auto, biasanya 32-256) | Copilot agent mode burst paling banyak 2–3 concurrent (kalau user dispatch sub-agent paralel). 4 = punya 1 slot cadangan tanpa boros KV cache. Memori per slot ≈ (192K tok × KV size FP8). |
| `--chunked-prefill-size` | `8192` | None (sglang pilih otomatis) | Memotong prefill panjang jadi chunk 8K supaya tidak monopoli GPU dan ganggu decode slot lain. Cocok untuk Copilot yang sering kirim prompt 30K–100K (workspace context). |
| `--max-prefill-tokens` | `16384` (default, tidak kita set) | `16384` | Batas total token prefill per batch. Cukup karena kita sudah pakai `chunked-prefill-size=8192`. |

### Reasoning & tool calling (paling Copilot-specific)

| Flag | Nilai | Default | Why for Copilot |
| --- | --- | --- | --- |
| `--reasoning-parser` | `qwen3` | None | Qwen3.6 emit chain-of-thought di `<think>...</think>`. Parser ini ekstrak jadi `reasoning_content` (terpisah dari `content`). VS Code Copilot **butuh field `reasoning_content` terpisah** supaya thinking effort picker bisa nampilin "Medium / High" dan supaya `content: ""` tidak salah dianggap response kosong. |
| `--tool-call-parser` | `qwen3_coder` | None | Parser yang convert format `<tool_call>{...}</tool_call>` Qwen3.6 jadi OpenAI-compatible `tool_calls: [{id, type:"function", function:{name, arguments}}]`. **Tanpa parser ini, Copilot agent mode tidak bisa call file editing tools**. Per HF model card Qwen, ini adalah parser official untuk Qwen3.6 family (BUKAN `hermes` atau `qwen25` — sudah diverifikasi). |
| `--sampling-defaults` | `model` (default, tidak kita set) | `model` | Pakai `generation_config.json` model untuk sampling defaults (temperature, top_p, dll) — Qwen Team sudah tuning ini, jangan override. |

### Kernel backends (perf-critical)

| Flag | Nilai | Default | Why for Copilot |
| --- | --- | --- | --- |
| `--attention-backend` | `fa3` | None (auto) | FlashAttention-3 — optimal di Hopper (H100). 1.5–2× lebih cepat dari triton untuk decode panjang dengan GQA (Qwen3.6 pakai 16 attn heads / 2 KV heads = GQA ratio 8). Kompatibel dengan speculative decoding NEXTN. |
| `--sampling-backend` | `flashinfer` | None (auto) | Sampling kernel FlashInfer lebih cepat untuk top-k/top-p + repetition penalty, vs pytorch fallback. Penting karena Copilot agent banyak short turn (decode-heavy). |
| `--mamba-backend` | `triton` | (no explicit default) | Backend Mamba2 SSM. Triton kernel paling matang di sglang 0.5.10 untuk hybrid Mamba+Transformer. |
| `--mamba-scheduler-strategy` | `extra_buffer` | `auto` (= `no_buffer`) | **Wajib** untuk: (1) supaya overlap scheduler aktif (CPU dispatch overlap GPU compute → lower TTFT), (2) supaya radix cache branching point caching jalan (prompt yang share prefix bisa reuse mamba state). Trade-off: mamba state memory per running req naik ~1.16× (karena `speculative_num_draft_tokens=2`). Untuk 4 slots: pengeluaran memory kecil, gain throughput besar. |

### Speculative decoding (NEXTN / MTP)

Qwen3.6 ship dengan MTP (Multi-Token Prediction) head 1-layer. NEXTN = sglang
speculative algorithm yang konsumsi MTP head bawaan model (tidak butuh draft
model terpisah).

| Flag | Nilai | Default | Why for Copilot |
| --- | --- | --- | --- |
| `--speculative-algorithm` | `NEXTN` | None | Aktifkan speculative decoding pakai MTP head built-in. Tested accept rate **0.95–0.99** di workload Copilot (sangat tinggi karena prompt code-domain konsisten). Throughput decode ~2× tanpa bias akurasi. |
| `--speculative-num-steps` | `1` | None | 1 step lookahead = setiap forward pass coba 1 token tambahan dari MTP. Karena head cuma 1 layer, lebih dari 1 step accept rate-nya turun drastis. |
| `--speculative-eagle-topk` | `1` | None | Top-1 sampling dari draft. Tidak ada gain dengan top-k > 1 untuk MTP 1-layer. |
| `--speculative-num-draft-tokens` | `2` | None | Total draft + verify = 2 token per step. Sweet spot kombinasi dengan `num_steps=1`. |

### Observability

| Flag | Nilai | Default | Why for Copilot |
| --- | --- | --- | --- |
| `--enable-metrics` | enabled | False | Expose Prometheus `/metrics` (token/req throughput, latency histogram). Dipakai smoke test dan monitoring kalau di-scrape dari laptop / observability stack. |

---

## Environment variables (`Environment=` di systemd unit)

| Variable | Nilai | Why |
| --- | --- | --- |
| `HF_HOME` | `/mnt/nvme/huggingface` | Pakai NVMe ephemeral 3.5 TB. Trade-off jujur: hilang saat deallocate, tapi loading model dari NVMe ~10× lebih cepat dari OS disk standard. ExecStartPre re-download otomatis. |
| `HF_XET_HIGH_PERFORMANCE` | `1` | Enable Xet (HF storage protocol baru) high-perf path saat download. Mempercepat first-boot ~2× via chunked dedupe (model 37 GB punya banyak block duplikat di shard berbeda). |
| `CUDA_VISIBLE_DEVICES` | `0` | Hard-pin ke GPU 0 (cuma 1 GPU di VM). Mencegah konflik kalau ada workload lain. |
| `SGLANG_ALLOW_OVERWRITE_LONGER_CONTEXT_LEN` | `1` | Wajib supaya `--context-length 196608` diterima padahal lebih kecil dari config model (262144). Tanpa flag ini sglang abort startup dengan "context_length must equal model config". |
| `TOKENIZERS_PARALLELISM` | `false` | Disable parallelism di HF tokenizer untuk hindari deadlock dengan Python multiprocessing milik sglang. Konvensi standard. |
| `SGLANG_ENABLE_SPEC_V2` | `1` | **Wajib** untuk sglang 0.5.10 saat menggabungkan: speculative decoding (NEXTN) + radix cache + Mamba hybrid. Tanpa ini service crash saat warmup dengan assertion error. |
| `SGLANG_JIT_DEEPGEMM_FAST_WARMUP` | `1` | DeepGEMM JIT compile FP8 GEMM kernels per shape M. Default mode compile ~16K kernel (cover semua M sampai 8192) — 20+ menit di first boot. Fast mode compile ~3K kernel (cover small bs + sampled larger M), ~5× lebih cepat. Trade-off: M yang uncommon kena JIT miss → first request shape itu lambat ~5 detik (tapi langsung di-cache di `~/.cache/deep_gemm/`). Untuk Copilot decode kecil-batch (max 4), distribusi M sangat sempit → fast warmup safe. |

---

## ServerArgs efektif (state internal yang sglang derive)

Berikut nilai default sglang yang tidak kita override tapi penting untuk
dipahami (dari log `server_args=ServerArgs(...)` di journal):

| Field | Nilai | Catatan |
| --- | --- | --- |
| `schedule_policy` | `fcfs` | First-come-first-served. Untuk single-user Copilot ini optimal (no head-of-line blocking risiko). |
| `radix_eviction_policy` | `lru` | Radix cache eviction Least-Recently-Used. Cocok untuk Copilot pattern (turn berikutnya share prefix dengan turn sebelumnya). |
| `page_size` | `1` | Granularity KV cache page. Default OK. |
| `dtype` | `auto` (= FP8 e4m3 untuk model ini) | Mengikuti model. |
| `kv_cache_dtype` | `auto` (= FP8 mengikuti weights) | KV cache pakai FP8 → hemat 50% memory vs FP16. |
| `grammar_backend` | `xgrammar` | Backend constrained decoding. Copilot belum kirim `response_format: json_schema` (untuk apply_patch dll pakai tool_calls), tapi standby kalau dipakai nanti. |
| `watchdog_timeout` | `300` (detik) | Crash server kalau forward batch > 5 menit (mencegah hang). Untuk reasoning Qwen, 1 forward pass < 1 detik, jauh dari trigger. |
| `decode_log_interval` | `40` | Log decode batch tiap 40 step. Cukup verbose untuk debug, tidak banjir log. |
| `stream_interval` | `1` | Emit 1 token per stream chunk. Snappy untuk Copilot UI (token muncul satu-satu). |
| `mamba_full_memory_ratio` | `0.9` | Ratio Mamba state memory / KV cache memory pool. Default OK untuk hybrid model. |

---

## Resource limits & lifecycle (`[Service]` block)

| Direktif | Nilai | Why |
| --- | --- | --- |
| `User` / `Group` | `azureuser` | Run non-root. Env file (berisi API key) tetap 600 root:root supaya azureuser baca via `EnvironmentFile=` tapi tidak bisa cat. |
| `Restart` | `on-failure` | Auto-restart kalau crash. Tidak `always` supaya `systemctl stop` bisa shutdown clean. |
| `RestartSec` | `15` | Tunggu 15 detik sebelum restart — beri GPU waktu reset. |
| `TimeoutStartSec` | `2400` (40 menit) | First boot bisa lama: model re-download (~15 min jika NVMe wiped) + DeepGEMM warmup (~10-20 min). Subsequent restart < 3 menit (model + cache hot). |
| `TimeoutStopSec` | `120` | Stop budget 2 menit. Mamba state flush butuh waktu. |
| `KillSignal` | `SIGINT` | Graceful shutdown ala Python KeyboardInterrupt. Sglang handle dengan flush ongoing requests. |
| `LimitMEMLOCK` | `infinity` | sglang pin GPU pages → butuh unlimited mlock. |
| `LimitNOFILE` | `1048576` | Banyak socket untuk concurrent HTTP + IPC scheduler. |

ExecStartPre 1: cek model present di NVMe, kalau hilang re-download via `hf
download Qwen/Qwen3.6-35B-A3B-FP8 --max-workers 8`. Heuristik: count
`*.safetensors` < 42 = corrupt, re-download.

ExecStartPre 2: cleanup stale SHM (`ipcs -m | xargs ipcrm`). Pattern dari unit
existing `sglang.service`.

---

## Karakteristik performa (terverifikasi empiris pada VM ini)

| Metrik | Nilai observasi |
| --- | --- |
| First boot (NVMe kosong) | ~25-35 menit (download 15 min + warmup 10-20 min) |
| Restart (cache hot) | < 3 menit |
| DeepGEMM cubin cache size | ~242 file di `~/.cache/deep_gemm/cache/` (persisten di `/home/azureuser`, bukan NVMe) |
| Decode throughput (single req, accept rate 0.97) | ~280 tokens/sec |
| GPU memory usage (idle, after warmup) | 85.8 / 95.8 GB (89.6% sesuai `mem-fraction-static`) |
| Speculative accept rate | 0.95–0.99 (pola Copilot sangat predictable) |
| Smoke test 4 case (model list / chat / tool_call / metrics) | semua PASS |
| Token usage realistis (complex code task) | ~7K reasoning + ~3.5K content = ~10.5K total |
| Context window terpakai khas | < 20% dari 192K cap |

---

## Apa yang TIDAK dipasang dan kenapa

| Param | Kenapa tidak dipakai |
| --- | --- |
| `--enable-torch-compile` | Per docs: "out of maintenance and might cause error". Skip. |
| `--cuda-graph-max-bs` / `--disable-cuda-graph` | Default OK. CUDA graph capture jalan otomatis untuk bs [1,2,3,4]. |
| `--enable-mixed-chunk` | Risiko regresi performance di model Mamba hybrid. Belum stable di 0.5.10. |
| `--enable-hierarchical-cache` / `--hicache-*` | Hanya berguna kalau ada storage backend (NVMe untuk overflow KV). Single-user, 4 slots, 192K — KV cache muat di GPU, tidak butuh tier. |
| `--enable-dp-attention` | Butuh dp_size > 1, dan model Qwen3_5MoeForConditionalGeneration belum dapat sertifikasi di list "DeepSeek-V2 dan Qwen 2/3 MoE" per docs. |
| `--enable-deterministic-inference` | Trade-off ~15-30% throughput untuk reproducibility bit-exact. Tidak penting untuk chat. |
| `--log-requests` | Default `False`. Kalau aktif berisi prompt user (privacy concern + log noise). Aktifkan ad-hoc untuk debugging spesifik saja. |
| `--enable-cache-report` | Default `False`. Bisa diaktifkan kalau ingin lihat `usage.prompt_tokens_details.cached_tokens` di response (good for cost analysis), tapi belum dibutuhkan. |
| `--enable-trace` | OpenTelemetry tracing — overkill untuk single endpoint. Cukup pakai `/metrics` Prometheus. |

---

## Tuning playbook untuk kasus nyata

Mapping symptom → param yang perlu di-utak-atik. Semua perubahan butuh
restart service (`systemctl restart sglang-qwen36-coder`) dan re-warmup
(cache DeepGEMM tetap hot, jadi < 3 menit).

| Symptom | Tuning |
| --- | --- |
| Banyak request paralel mantul (queue panjang di sglang log) | Naikin `--max-running-requests` 4 → 6 atau 8. Pastikan masih ada room: tiap +1 slot ≈ +(context_len × KV bytes) memory. Cek `mem_fraction_static`. |
| VS Code Copilot tampil "Response too long" | Naikin `maxOutputTokens` di [`chatLanguageModels.json`](chatLanguageModels.entry.json), kompensasi turunin `maxInputTokens`. Sum HARUS ≤ 196608. Server tidak perlu restart (cuma config Copilot). |
| Mau context lebih besar (misal 256K full) | Naikin `--context-length` ke 262144. Turunin `--max-running-requests` ke 2-3 supaya muat. Re-evaluate `mem-fraction-static`. |
| TTFT pelan untuk prompt sangat panjang (50K+) | Turunin `--chunked-prefill-size` 8192 → 4096. Trade-off: prefill batch lebih kecil → TTFT lebih cepat, tapi throughput prefill turun sedikit. |
| Mau output streaming lebih halus | Sudah optimal (`stream_interval=1`). Tidak ada knob lagi. |
| Mau matikan thinking (latency-sensitive use) | JANGAN di server side. Set di Copilot model picker → Thinking Effort → Low. Server-side parser tetap aktif, model decide thinking budget. |

---

## Cara verify config live di VM

```bash
# 1. Unit file di disk
sudo cat /etc/systemd/system/sglang-qwen36-coder.service

# 2. ServerArgs efektif yang sglang derive (cek baris pertama setelah boot)
sudo journalctl -u sglang-qwen36-coder.service --no-pager \
  | grep "server_args=ServerArgs" | tail -1

# 3. Model id + max_model_len yang dilihat client
curl -s -H "Authorization: Bearer $API_KEY" \
  http://127.0.0.1:8000/v1/models | jq .

# 4. Live runtime metrics
curl -s -H "Authorization: Bearer $API_KEY" \
  http://127.0.0.1:8000/metrics | grep -E "(num_requests|generation_tokens|e2e_request_latency_seconds_(sum|count))"

# 5. GPU + service status
nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu,power.draw --format=csv
systemctl status sglang-qwen36-coder.service --no-pager -n 5
```

---

## Client config — OpenCode (CLI)

[OpenCode](https://opencode.ai/) treat endpoint sglang ini sebagai **custom OpenAI-compatible provider**.
Berbeda dengan VS Code Copilot yang ada UI Manage Language Models, OpenCode
konfigurasi via `opencode.json` / `opencode.jsonc`. Semua tabel di bawah
mengacu ke [opencode.ai/docs/config](https://opencode.ai/docs/config) dan
[opencode.ai/docs/providers](https://opencode.ai/docs/providers) (verified
2026-06-09).

### Recommended `~/.config/opencode/opencode.jsonc`

```jsonc
{
  "$schema": "https://opencode.ai/config.json",

  "provider": {
    "vllm-provider": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "sglang Qwen3.6 Coder (self-hosted H100)",
      "options": {
        "baseURL": "http://48.193.44.221:8000/v1",
        "apiKey": "{env:SGLANG_API_KEY}",
        "timeout": 600000,
        "chunkTimeout": 120000
      },
      "models": {
        "Qwen3.6-35B-A3B-FP8": {
          "name": "Qwen3.6-35B-A3B-FP8 (sglang)",
          "limit": {
            "context": 131072,
            "output": 65536
          }
        }
      }
    }
  },

  "model": "vllm-provider/Qwen3.6-35B-A3B-FP8",
  "small_model": "vllm-provider/Qwen3.6-35B-A3B-FP8",

  "compaction": {
    "auto": true,
    "prune": false,
    "reserved": 20000
  }
}
```

Set API key di shell profile (jangan inline di JSON):

```bash
echo 'export SGLANG_API_KEY="<YOUR_API_KEY>"' >> ~/.bashrc
```

### Per-option rationale (opencode-specific)

| Field | Nilai | Default opencode | Why for sglang+Qwen3.6 |
| --- | --- | --- | --- |
| `provider.<id>` | `vllm-provider` | n/a | Provider ID arbitrary; harus konsisten dengan kunci di `auth.json` jika dipakai `/connect`. Boleh pakai `sglang` juga, tidak ada efek behavior. |
| `provider.<id>.npm` | `@ai-sdk/openai-compatible` | n/a | **Wajib** untuk endpoint yang expose `/v1/chat/completions` (yang dipakai sglang). Jangan pakai `@ai-sdk/openai` — itu untuk `/v1/responses` (Responses API ChatGPT, BUKAN OpenAI-compatible). |
| `options.baseURL` | `http://48.193.44.221:8000/v1` | n/a | Wajib end with `/v1` (path-prefix OpenAI standard). Tanpa `/v1` request akan 404 di sglang. |
| `options.apiKey` | `{env:SGLANG_API_KEY}` | n/a | Pakai env var substitution supaya secret tidak commit ke repo. |
| `options.timeout` | `600000` (10 menit) | `300000` (5 menit) | Default 5 menit cukup untuk most requests, tapi Qwen3.6 thinking mode di reasoning-effort tinggi bisa sampai 2-3 menit per turn (lihat screenshot user: build 2m17s, 2m08s). Naikin ke 10 menit kasih headroom. |
| `options.chunkTimeout` | `120000` (2 menit) | tidak terdokumentasi (kemungkinan ~30000) | Timeout antara streamed chunks. Dengan sglang `stream_interval=1` + decode 280 tok/s, normalnya chunk datang sub-detik. Tapi pas reasoning model thinking, ada momen single-chunk delay 2-10 detik (model lagi compute next thinking token). 120s buffer sangat aman. **JANGAN setting ke 600000 (10 menit)** — itu nyembunyiin masalah real kalau server stuck. |
| `options.setCacheKey` | tidak di-set | `false` | Khusus Anthropic prompt caching. Sglang tidak handle ini, jadi skip. |
| `models.<id>` | `Qwen3.6-35B-A3B-FP8` | n/a | **Harus persis match** dengan `--served-model-name` di sglang. Salah dikit → 404 model not found. |
| `models.<id>.limit.context` | `131072` | `200000` (dari models.dev fallback) | Total input budget (system prompt + history + workspace context). Sum dengan output ≤ sglang `--context-length 196608`. Pilihan 131K = `196608 - 65536`. |
| `models.<id>.limit.output` | `65536` | `65536` (dari models.dev fallback) | Max output tokens per turn. Sama dengan Copilot config — empirically cover thinking-heavy code task tanpa truncation. |
| `model` | `vllm-provider/Qwen3.6-35B-A3B-FP8` | n/a | Default model untuk semua agent. Format `<provider-id>/<model-id>`. |
| `small_model` | `vllm-provider/Qwen3.6-35B-A3B-FP8` | otomatis fallback ke `gpt-5-nano` di OpenCode Zen | **Penting kalau self-hosted strict**: kalau tidak di-set, opencode generate session title pakai gpt-5-nano via zen (kalau ada zen credential) — keluar dari air-gapped boundary. Set ke model yang sama supaya semua traffic lewat sglang lokal. Cost: title gen pakai model 35B (mahal compute), tapi cuma sekali per session. |
| `compaction.auto` | `true` | `true` | Auto-compact saat context full. Wajib untuk session panjang dengan 131K cap. |
| `compaction.prune` | `false` | `false` | Kalau `true` opencode hapus tool output lama untuk hemat token. Defaultnya safer (`false`) — keep history, biar compaction yang summarize. |
| `compaction.reserved` | `20000` | `10000` | Buffer token sebelum trigger compaction. Untuk model thinking-heavy seperti Qwen3.6, naikin ke 20K supaya compaction pass-nya sendiri (yang juga butuh thinking) tidak overflow context. |

### Provider-level optional yang TIDAK di-set dan kenapa

| Field | Kenapa skip |
| --- | --- |
| `disabled_providers` / `enabled_providers` | Tergantung pilihan user. Kalau ingin strict self-hosted only (block cloud), tambahkan: `"disabled_providers": ["openai", "anthropic", "gemini", "opencode", "opencode-go"]`. |
| `permission` | Default opencode allow all. Untuk env shared atau auto-run, set `"permission": { "bash": "ask", "edit": "ask" }`. |
| `tools` | Default semua tool aktif. Kalau mau disable shell akses (kasih AI baca-only), pakai `"tools": { "bash": false, "write": false, "edit": false }`. |
| `snapshot` | Default `true`. Jangan disable kecuali repo sangat besar — snapshot = undo session. |
| `instructions` | Pakai kalau ada `CONTRIBUTING.md` / coding rules yang mau ditarik per project. Tidak terkait ke sglang/Qwen tuning. |
| `share` | Default `"manual"`. Untuk privacy tinggi set `"disabled"`. |

### Perbedaan vs VS Code Copilot setup

| Aspek | VS Code Copilot BYOK | OpenCode |
| --- | --- | --- |
| Config location | `chatLanguageModels.json` di User dir | `~/.config/opencode/opencode.jsonc` |
| API key storage | OS keyring via UI prompt (BUKAN JSON) | Env var substitution (`{env:NAMA}`) atau `auth.json` via `/connect` |
| Field input budget | `maxInputTokens: 131072` | `models.<id>.limit.context: 131072` |
| Field output budget | `maxOutputTokens: 65536` | `models.<id>.limit.output: 65536` |
| Timeout request | Hardcoded di extension (~5 menit) | Configurable: `options.timeout` |
| Timeout chunk stream | Tidak exposed | Configurable: `options.chunkTimeout` |
| Reasoning effort | UI picker (Low/Medium/High) → header injection | Tidak ada UI; pakai model default. Bisa override per agent via custom agent prompt. |
| Tool call format | OpenAI tool_calls (parsed) | OpenAI tool_calls (parsed via AI SDK) |
| Auto-continue length-truncated | Tidak (per analisa extension.js) | Tidak — sama behavior. Output truncated = stop. |
| Session compaction | Tidak (per-turn context only) | `compaction.auto: true` — auto-summarize saat context penuh |
| Title generation | Tidak | `small_model` field — bisa pakai model sama atau berbeda |
| Per-agent model override | Custom modes | `agent.<name>.model: "..."` di config |

### Caveats honest untuk opencode

- **Thinking content display**: OpenCode pakai `@ai-sdk/openai-compatible` yang men-pass-through field `reasoning_content` dari sglang. UI TUI opencode tampilkan thinking dengan indikator `Thought: <duration>` (lihat screenshot user). Jadi parser sglang `--reasoning-parser qwen3` tetap relevan dan kerja sama dengan opencode.
- **Tool call accuracy**: Qwen3.6-Coder family dengan parser `qwen3_coder` — confirmed work untuk opencode tools (`bash`, `read`, `edit`, `write`, `glob`, `grep`). Per docs llama.cpp section: "If tool calls aren't working well, pick a loaded model with strong tool-calling support (for example, a Qwen-Coder or DeepSeek-Coder variant)." — kita pakai exactly that.
- **`small_model` cost trade-off**: Title generation kirim ~2K tokens ke model 35B. Latency ~3-5 detik per session start. Kalau ingin instant, biarkan default (zen gpt-5-nano) dengan trade-off keluar dari self-hosted boundary. Pilihan tergantung threat model.
- **Single-user assumption**: sglang dideploy dengan `--max-running-requests 4`. Kalau 1 user pakai opencode + 1 user pakai Copilot bersamaan, dan satu user dispatch 3 sub-agent paralel, total 4 slot bisa penuh. Naikin di server kalau perlu (lihat tuning playbook di atas).
- **No retry-on-disconnect**: Opencode tidak auto-resume conversation kalau koneksi putus mid-stream. Reasoning Qwen yang udah jalan 2 menit hilang. Mitigation: opencode menyimpan session state — bisa re-run query di session yang sama.

### Quick test setelah edit config

```bash
# 1. Cek opencode load provider tanpa error
opencode debug config | grep -A 20 "vllm-provider"

# 2. List model resolve dari endpoint
opencode auth list

# 3. Smoke test 1 turn
opencode run "What is 2+2? Answer in one word."

# 4. Test tool calling (bash)
opencode run "Run 'date' and tell me what day it is"
```

---

## Referensi

- [docs sglang Server Arguments (official)](https://docs.sglang.io/docs/advanced_features/server_arguments)
- [Qwen3.6 HF model card](https://huggingface.co/Qwen/Qwen3.6-35B-A3B-FP8) — sumber `tool_call_parser=qwen3_coder` dan rekomendasi min 128K context
- [VS Code Copilot — Bring your own language model](https://code.visualstudio.com/docs/agent-customization/language-models#_bring-your-own-language-model-key)
- [OpenCode Config docs](https://opencode.ai/docs/config) — `provider`, `model`, `compaction`, `permission`, `timeout`, `chunkTimeout`
- [OpenCode Providers — Custom provider](https://opencode.ai/docs/providers#custom-provider) — pattern `@ai-sdk/openai-compatible`
- [OpenCode Providers — llama.cpp example](https://opencode.ai/docs/providers#llamacpp) — `limit.context` / `limit.output` reference
- [scripts/sglang-qwen36-coder-README.md](sglang-qwen36-coder-README.md) — ops & deploy guide
- [scripts/sglang-qwen36-coder.service](sglang-qwen36-coder.service) — unit file sumber kebenaran
