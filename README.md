# Multi-Agent Vector Database RAG Outlook (mcp-rag-outlook)

This repository contains the standalone RAG stack and AST-aware Model Context Protocol (MCP) server designed to expand the codebase search and long-term context memory capabilities for multiple concurrent coding agents.

It works in tandem with the local dual-RTX 5060 Ti vLLM server to enable **16 concurrent agents** to work efficiently within a shared 380K context pool without experiencing Out-Of-Memory (OOM) failures or position embedding (RoPE) degradation.

---

## 3-Tier Context Memory Architecture

To allow any single agent to scale up to the model's native limit of **262K tokens** while running **16 agents concurrently**, the system implements a tiered memory design:

```
  ┌─────────────────────────────────────────────────────────────┐
  │                        AGENT CLIENT                         │
  └──────────────────────────────┬──────────────────────────────┘
                                 │
         ┌───────────────────────┼───────────────────────┐
         │ (Active Dialog)       │ (Inactive / Idle)     │ (Long-Term Search)
         ▼                       ▼                       ▼
┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐
│  Tier 1: VRAM    │    │  Tier 2: RAM/SSD │    │  Tier 3: RAG     │
│  PagedAttention  │◄──►│  vLLM KV Cache   │    │  Milvus VectorDB │
│  Prefix Caching  │    │  PCIe Swapping   │    │  AST Chunk Search│
└──────────────────┘    └──────────────────┘    └──────────────────┘
```

1.  **Tier 1: GPU VRAM (Active Attention)**
    *   Uses **PagedAttention** for dynamic memory allocation, preventing fragmentation.
    *   Uses **Prefix Caching** to share common prompts (system rules, workspace directories) in a single VRAM location, drastically cutting prefill costs across concurrent runs.
2.  **Tier 2: Host RAM & SSD (vLLM Swapping)**
    *   When the 380K VRAM limit is hit, vLLM automatically swaps inactive KV caches over the PCIe bus to host CPU RAM (`--swap-space 16` and `--cpu-offload-gb 8`).
    *   Uses high-speed DMA (Direct Memory Access) page-locked memory to execute these transfers in the background during active computation.
3.  **Tier 3: Vector Database (Semantic Code Search)**
    *   Rather than dumping entire source files directly into the active prompt window, static codebase context is indexed semantically into **Milvus**.
    *   The agent calls the **AST-aware Code Indexer MCP** to query the database on demand, fetching only the top relevant code snippets (typically under 10K tokens) into its working context window.

---

## Component Setup & Deployment

### 1. Deploy Milvus standalone
Ensure you have stopped any previous docker-conflict containers, then run:
```powershell
docker compose up -d
```
This deploys the standalone vector store stack:
*   **milvus-standalone** (Port `19530`): Core vector indexing and search engine.
*   **milvus-etcd** (Internal Port `2379`): Metadata storage.
*   **milvus-minio** (Ports `9000` / `9001`): Object storage for vectors and indexes (with matched access keys).

### 2. Configure the MCP Server Launcher
The folder `mcp_server` contains a pre-configured Node.js launcher wrapper.
1.  Verify the environment settings inside [mcp_server/.env](mcp_server/.env):
    ```env
    EMBEDDING_PROVIDER=OpenAI
    OPENAI_BASE_URL=http://localhost:1234/v1
    OPENAI_API_KEY=lm-studio
    EMBEDDING_MODEL=text-embedding-nomic-embed-text-v1.5@q8_0
    MILVUS_ADDRESS=localhost:19530
    ```
2.  Install launcher dependencies:
    ```powershell
    # Run in the mcp_server folder
    cmd.exe /c npm install
    ```
3.  Run or register the launcher (`launch-mcp.js`). The script performs a port check to verify that Milvus is fully online before launching the AST indexer.

---

## Integration with OpenCode / OpenChamber

We have provided a complete configuration profile in [config/opencode_rag.json](config/opencode_rag.json).

To activate it:
1.  Locate your active OpenCode configuration file at:
    `%USERPROFILE%\.config\opencode\opencode.json`
2.  Backup your existing configuration file.
3.  Copy the contents of `config/opencode_rag.json` to replace it.
4.  Restart your OpenCode server or OpenChamber workspace in VS Code.
