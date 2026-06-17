# sglang Qwen3.6 Coder 35B FP8 on H100 (vm-sglang-h100)

## Bahan & verifikasi (semua sudah dicek per 2026-06-09)

| Item | Value |
| --- | --- |
| VM | `vm-sglang-h100` Standard_NC40ads_H100_v5 indonesiacentral |
| Public IP | `48.193.44.221` (static) |
| Private IP | `10.0.0.4` |
| GPU | NVIDIA H100 NVL 95830 MiB |
| Driver | 575.57.08 (max CUDA 12.9) |
| OS | Ubuntu 22.04 LTS, kernel 6.8.0-1051-azure |
| Python | 3.10.12 |
| Storage venv | `/mnt/sglang-data` (64 GB persistent disk `sdc`, UUID `d4de18d0-9f49-46c9-9a4e-8480744b6d8d`) |
| Storage model | `/mnt/nvme` (3.5 TB **EPHEMERAL** NVMe — hilang saat VM deallocate) |
| sglang | 0.5.10.post1 |
| torch | 2.9.1+cu128 |
| flashinfer | 0.6.7.post3 |
| transformers | 5.3.0 |
| Model | `Qwen/Qwen3.6-35B-A3B-FP8` (37.46 GB, 42 safetensors, Apache-2.0) |
| Snapshot | `95a723d08a9490559dae23d0cff1d9466213d989` |

## Kenapa sglang 0.5.10.post1, bukan 0.5.12?

Driver 575.57.08 = **CUDA 12.9 max**. Dari probing METADATA wheel:

| sglang | torch | cuda-python | flashinfer |
| --- | --- | --- | --- |
| 0.5.10 / 0.5.10.post1 | 2.9.1 (cu128 compat) | 12.9 | 0.6.7.post3 |
| 0.5.11 / 0.5.12 / 0.5.12.post1 | 2.11.0 (**cu130 required**) | >=13.0 | 0.6.8+ |

Semua versi 0.5.10+ punya `qwen3_5.py` + `qwen3_5_mtp.py` (support Qwen3.6 arsitektur). Jadi pakai 0.5.10.post1 = upgrade driver tidak perlu.

Untuk pakai 0.5.12.post1 di masa depan: upgrade NVIDIA driver ke 580+ (CUDA 13).

## Arsitektur model (Qwen3_5MoeForConditionalGeneration)

- Hybrid Mamba2 (linear_attention) + full_attention: 30 linear + 10 full layers (full setiap layer ke-4)
- MoE: 256 experts × top-8 routed + 1 shared expert
- Hidden 2048, head_dim 256, attn_heads 16, kv_heads 2 (GQA)
- FP8 e4m3 dynamic activation, block 128×128 quant
- MTP head 1 layer (untuk NEXTN speculative decoding)
- Max position native 262144 (256K) — runtime di-cap ke 196608 (192K) untuk balance VRAM vs Copilot full-repo context (Qwen min recommendation 128K, lihat catatan tuning di bawah)
- vocab 248320, rope_theta 10M, partial_rotary_factor 0.25, mrope_interleaved

## File yang dibuat di repo

- [scripts/sglang-qwen36-coder.service](scripts/sglang-qwen36-coder.service) — systemd unit file
- [scripts/sglang-qwen36-deploy.sh](scripts/sglang-qwen36-deploy.sh) — deploy/redeploy script
- [scripts/sglang-qwen36-smoke.sh](scripts/sglang-qwen36-smoke.sh) — end-to-end smoke test (local → 48.193.44.221:8000)
- [scripts/copilot-chatLanguageModels.example.json](scripts/copilot-chatLanguageModels.example.json) — VS Code Copilot BYOK config

## NSG rules (port 8000)

Sudah ditambahkan ke **kedua** NSG (NIC + subnet):

| NSG | Priority | Source | Port | Access |
| --- | --- | --- | --- | --- |
| `vm-sglang-h100NSG` | 110 | 10.26.0.0/16 (AKS) | 8000 | Allow (existing) |
| `vm-sglang-h100NSG` | 210 | 140.213.190.191/32 + 180.252.83.91/32 | 8000 | Allow (baru) |
| `vm-sglang-h100NSG` | 220 | 140.213.190.191/32 + 180.252.83.91/32 | 22 (SSH) | Allow (re-added) |
| `vm-sglang-h100VNET-vm-sglang-h100Subnet-nsg-indonesiacentral` | 215 | 140.213.190.191/32 + 180.252.83.91/32 | 8000 | Allow (baru) |
| `vm-sglang-h100VNET-vm-sglang-h100Subnet-nsg-indonesiacentral` | 220 | 140.213.190.191/32 + 180.252.83.91/32 | 22 (SSH) | Allow (re-added) |

> **Catatan:** SSH allow rule sempat hilang dari kedua NSG (kemungkinan auto-remediation policy). Kalau SSH timeout lagi, cek dengan `az network nic list-effective-nsg -g rg-sglang-mistral -n vm-sglang-h100VMNic --query "value[].effectiveSecurityRules[?destinationPortRange=='22']"` dan re-add rule `Allow-SSH-from-allowlist` priority 220.

Kalau IP publik Kakak berubah (ISP dynamic), update keduanya:

```bash
RG=RG-SGLANG-MISTRAL
NEW_IP=<ip-baru>/32
for NSG in vm-sglang-h100NSG vm-sglang-h100VNET-vm-sglang-h100Subnet-nsg-indonesiacentral; do
  az network nsg rule update -g $RG --nsg-name $NSG \
    --name Allow-sglang-from-allowlist \
    --source-address-prefixes $NEW_IP 140.213.190.191/32 180.252.83.91/32
done
```

## GitHub Copilot — BYOK custom endpoint

VS Code Copilot mendukung custom OpenAI-compatible endpoint via setting `github.copilot.chat.chatLanguageModels`. **Catatan jujur dari official docs:**

> Currently, you cannot connect to a local model for inline suggestions.

Artinya: custom endpoint **hanya untuk Chat & Agent mode** — bukan untuk ghost-text inline completion.

Setting di `~/.config/Code/User/settings.json` (VS Code) atau `~/.vscode-server/data/User/settings.json` (VS Code Server):

```jsonc
"github.copilot.chat.chatLanguageModels": [
  {
    "vendor": "customendpoint",
    "name": "Qwen3.6-Coder-Local",
    "apiType": "chat-completions",
    "apiKey": "<YOUR_API_KEY>",
    "models": [
      {
        "id": "Qwen3.6-35B-A3B-FP8",
        "name": "Qwen3.6 Coder 35B (Local H100 IDC)",
        "url": "http://48.193.44.221:8000/v1/chat/completions",
        "toolCalling": true,
        "vision": false,
        "thinking": true,
        "streaming": true,
        "maxInputTokens": 131072,
        "maxOutputTokens": 65536,
        "supportsReasoningEffort": ["low", "medium", "high"],
        "reasoningEffortFormat": "chat-completions",
        "editTools": true,
        "requestHeaders": {}
      }
    ]
  }
]
```

Lalu di Copilot Chat picker, pilih **Qwen3.6 Coder 35B (Local H100 IDC)**.

## Service ops (deploy & runtime)

### Gotcha: speculative + radix cache + mamba

Kalau pakai `--speculative-algorithm NEXTN/EAGLE` di Qwen3_5MoE (hybrid Mamba), sglang 0.5.10 menolak default scheduler dengan error:

```
ValueError: Speculative decoding for Qwen3_5MoeForConditionalGeneration is not compatible with
radix cache when using --mamba-scheduler-strategy no_buffer. To use radix cache with
speculative decoding, please use --mamba-scheduler-strategy extra_buffer and set SGLANG_ENABLE_SPEC_V2=1.
```

Fix di unit file (sudah include):
- `Environment=SGLANG_ENABLE_SPEC_V2=1`
- `--mamba-scheduler-strategy extra_buffer`

### Gotcha: DeepGEMM JIT first-run cost

First start = **15-30 menit** untuk compile semua GEMM kernel shapes (nvcc + ptxas serial). Hasil cached di `~/.cache/deep_gemm/` (persistent di `/home/azureuser`). Restart berikutnya = detik. Disk persistent jadi cache survives VM stop/start.

Speed-up untuk first deploy: run `python -m sglang.compile_deep_gemm --model <path> --tp 1 --trust-remote-code` sebelum systemctl start (pre-populate cache).

### Operations

```bash
# DEPLOY (first time)
ssh azureuser@48.193.44.221
sudo cp /home/azureuser/sglang-qwen36-coder.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable sglang-qwen36-coder
sudo systemctl start sglang-qwen36-coder

# WATCH startup (first start = 15-30 min for DeepGEMM JIT compile + CUDA graph)
sudo journalctl -u sglang-qwen36-coder -f

# STATUS
sudo systemctl status sglang-qwen36-coder
sudo ss -tnlp | grep :8000

# RESTART (will be FAST after first warmup — DeepGEMM cached at ~/.cache/deep_gemm)
sudo systemctl restart sglang-qwen36-coder

# STOP
sudo systemctl stop sglang-qwen36-coder
```

### Catatan ephemeral NVMe

NVMe `/dev/nvme0n1` di Azure **Standard_NC40ads_H100_v5 wipe saat VM deallocate**. Service unit punya `ExecStartPre` yang detect kalau model hilang dan auto re-download 35 GB (~10 min dengan `--max-workers 8`). DeepGEMM cache (`~/.cache/deep_gemm/`) ada di disk persistent `/mnt/sglang-data` (via `/home/azureuser` symlink atau langsung), jadi cache tidak hilang.

⚠️  Tetap saja: deallocate = ~10 min penalty untuk re-download. Kalau VM mau sering dimatikan, pertimbangkan pindah model ke `/mnt/sglang-data/huggingface` (persistent 64 GB, perlu free 35 GB — saat ini 21 GB used = 43 GB free).

## Security

- **JANGAN expose 0.0.0.0/0** walaupun ada bearer key — risiko brute force + denial-of-wallet (GPU compute).
- API key disimpan di `/etc/sglang-qwen36-coder.env` dengan perm 600.
- Sekarang allowlist hanya 2 IP `/32`. Kalau perlu rotation/audit, taruh APIM atau Application Gateway sebagai reverse proxy dengan WAF policy.
