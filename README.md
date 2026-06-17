# SGLang on Azure H100 — OpenAI-Compatible Endpoint

Deploy **Qwen3.6-27B** (or any HuggingFace model) on Azure with a single H100 GPU, served via [SGLang](https://github.com/sgl-project/sglang) behind a Caddy HTTPS reverse-proxy with API-key authentication.

```
https://openai.contoso.day/v1/chat/completions
```

## Architecture

```mermaid
flowchart TB
    subgraph Internet
        Client[🖥️ Client App / curl]
    end
    
    subgraph Cloudflare
        DNS[DNS: openai.contoso.day]
    end
    
    subgraph Azure["Azure (indonesiacentral)"]
        subgraph RG["Resource Group: sglang-rg"]
            PIP[Public IP<br/>70.153.148.66]
            
            subgraph NSG["NSG: sglang-nsg"]
                direction TB
                N1[Inbound: 22, 80, 443]
                N2[Outbound: All]
            end
            
            subgraph VM["VM: sglang-h100<br/>Standard_NC40ads_H100_v5"]
                subgraph Docker
                    Caddy[🔒 Caddy v2<br/>HTTPS :443<br/>Let's Encrypt TLS<br/>API Key Auth]
                    SGLang[🚀 SGLang Server<br/>127.0.0.1:30000]
                end
                GPU[🎮 NVIDIA H100 NVL<br/>94 GB VRAM]
                HFCache[📦 HF Cache<br/>/opt/hf-cache]
            end
        end
    end
    
    Client -->|HTTPS| DNS
    DNS -->|A Record| PIP
    PIP --> NSG
    NSG --> Caddy
    Caddy -->|Proxy + Auth| SGLang
    SGLang --> GPU
    SGLang --> HFCache
    
    style Caddy fill:#22c55e,color:#fff
    style SGLang fill:#3b82f6,color:#fff
    style GPU fill:#f59e0b,color:#fff
```

## Request Flow

```mermaid
sequenceDiagram
    participant C as Client
    participant CF as Cloudflare DNS
    participant CA as Caddy (HTTPS)
    participant SG as SGLang
    participant GPU as H100 GPU
    
    C->>CF: DNS lookup openai.contoso.day
    CF-->>C: 70.153.148.66
    
    C->>CA: POST /v1/chat/completions<br/>Authorization: Bearer <API_KEY>
    
    alt No API Key or Invalid
        CA-->>C: 401 Unauthorized
    else Valid API Key
        CA->>SG: Forward to 127.0.0.1:30000
        SG->>GPU: Run inference (Qwen3.6-27B)
        GPU-->>SG: Generated tokens
        SG-->>CA: JSON response
        CA-->>C: 200 OK + completion
    end
```

## Deployment Scripts

```mermaid
flowchart LR
    subgraph "Phase 1: Setup"
        A[00-genkey.sh<br/>Generate API Key] --> B[01-deploy.sh<br/>Create VM + GPU Driver]
    end
    
    subgraph "Phase 2: Network"
        B --> C[02-start-vm.sh<br/>Ensure Running]
        C --> D[03-open-nsg.sh<br/>Open Firewall]
    end
    
    subgraph "Phase 3: Application"
        D --> E[05-run-sglang.sh<br/>Launch Containers]
    end
    
    subgraph "Cleanup"
        F[99-destroy.sh<br/>Delete Everything]
    end
    
    style A fill:#10b981,color:#fff
    style B fill:#3b82f6,color:#fff
    style E fill:#8b5cf6,color:#fff
    style F fill:#ef4444,color:#fff
```

## Quick Start

### Prerequisites

- Azure subscription with H100 quota in `indonesiacentral`
- Azure CLI (`az`) authenticated
- WSL2 (Ubuntu) or Linux
- A domain name (optional, for Let's Encrypt; falls back to self-signed cert for IP access)

### 1. Clone & Configure

```bash
git clone https://github.com/ibranibeny/sglang-azure-workshop.git
cd sglang-azure-workshop

# Edit deploy/config.sh to customize:
# - MODEL_PATH (default: Qwen/Qwen3.6-27B)
# - TLS_DOMAIN (your domain, or leave empty for IP-based access)
# - LOCATION (Azure region)
```

### 2. Deploy

```bash
cd deploy

# Generate API key (stored in .secrets/api_key)
bash 00-genkey.sh

# Create VM with H100 + NVIDIA driver
bash 01-deploy.sh

# Open firewall
bash 03-open-nsg.sh

# Launch SGLang + Caddy (downloads model, starts serving)
bash 05-run-sglang.sh
```

### 3. Test

```bash
export API_KEY=$(cat deploy/.secrets/api_key)

# Health check (no auth required)
curl https://openai.contoso.day/health

# Chat completion
curl https://openai.contoso.day/v1/chat/completions \
  -H "Authorization: Bearer $API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "Qwen/Qwen3.6-27B",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'

# List models
curl https://openai.contoso.day/v1/models \
  -H "Authorization: Bearer $API_KEY"
```

## Project Structure

```
.
├── deploy/
│   ├── config.sh           # All configuration (VM size, model, domain, etc.)
│   ├── 00-genkey.sh        # Generate 256-bit API key
│   ├── 01-deploy.sh        # Create RG, VNet, NSG, VM, install GPU driver
│   ├── 02-start-vm.sh      # Start/allocate VM
│   ├── 03-open-nsg.sh      # Open inbound/outbound ports
│   ├── 04-check-nsg.sh     # Verify NSG rules
│   ├── 05-run-sglang.sh    # Launch SGLang + Caddy containers
│   ├── 99-destroy.sh       # Delete all resources
│   ├── Caddyfile.tmpl      # Caddy config template
│   ├── cloud-init.yaml     # VM bootstrap (Docker install)
│   └── .secrets/           # API key (git-ignored)
├── specs/                  # Feature specifications
├── DEPLOYMENT_REPORT.md    # Detailed deployment status
└── README.md               # This file
```

## Configuration

Edit `deploy/config.sh`:

| Variable | Default | Description |
|----------|---------|-------------|
| `MODEL_PATH` | `Qwen/Qwen3.6-27B` | HuggingFace model ID |
| `VM_SIZE` | `Standard_NC40ads_H100_v5` | 1× H100 NVL (94GB) |
| `LOCATION` | `indonesiacentral` | Azure region |
| `TLS_DOMAIN` | `openai.contoso.day` | Domain for Let's Encrypt (empty = self-signed) |
| `TLS_EMAIL` | _(empty)_ | ACME contact email (optional) |
| `TP_SIZE` | `1` | Tensor parallelism (GPUs) |

## VM Sizes

| SKU | GPUs | VRAM | Use Case |
|-----|------|------|----------|
| `Standard_NC40ads_H100_v5` | 1× H100 NVL | 94 GB | Up to ~70B models |
| `Standard_NC80adis_H100_v5` | 2× H100 NVL | 188 GB | 70B+ models, `--tp 2` |

## Cost Management

The H100 VM is **expensive** (~$4+/hour). Stop billing when idle:

```bash
# Stop VM (keeps disk, stops compute billing)
az vm deallocate -g sglang-rg -n sglang-h100

# Restart later
az vm start -g sglang-rg -n sglang-h100
bash deploy/05-run-sglang.sh   # Re-launch containers

# Delete everything
bash deploy/99-destroy.sh
```

## Security Notes

- 🔒 SGLang binds to `127.0.0.1` only — not directly exposed
- 🔒 All traffic goes through Caddy with API-key authentication
- 🔒 TLS via Let's Encrypt (auto-renewed) or self-signed
- ⚠️ Default NSG opens all ports for testing — restrict in production

## Troubleshooting

### Connection timeout
```bash
# Check NSG rules
bash deploy/04-check-nsg.sh

# Re-open ports if missing
bash deploy/03-open-nsg.sh
```

### Model not loading
```bash
# SSH into VM
ssh azureuser@70.153.148.66

# Check SGLang logs
docker logs -f sglang

# Check GPU
nvidia-smi
```

### Caddy/TLS issues
```bash
# On the VM
docker logs --tail 100 caddy
```

## OpenAI SDK Compatibility

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://openai.contoso.day/v1",
    api_key="your-api-key-here"
)

response = client.chat.completions.create(
    model="Qwen/Qwen3.6-27B",
    messages=[
        {"role": "system", "content": "You are a helpful assistant."},
        {"role": "user", "content": "What is the capital of France?"}
    ],
    max_tokens=100
)

print(response.choices[0].message.content)
```

## License

MIT

## Acknowledgments

- [SGLang](https://github.com/sgl-project/sglang) — Fast serving framework
- [Caddy](https://caddyserver.com/) — Automatic HTTPS server
- [Qwen](https://huggingface.co/Qwen) — Open-weight LLM family
