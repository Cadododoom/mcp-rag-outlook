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
3.  **Tier 3: Vector Database (Semantic Code Search via CPU-Offloaded RAG)**
    *   Rather than dumping entire source files directly into the active prompt window, static codebase context is indexed semantically into **LanceDB** using a **1-bit RaBitQ index** (\(x_q = \text{sign}(R \cdot (x - c_j))\)) to compress 1024-dimensional float32 vectors down to 136 bytes.
    *   Search operations calculate Hamming distances on the host CPU using fast bitwise XOR and population count instructions.
    *   At query time, the system performs a multi-stage retrieval:
        *   **HiRAG Graph Retrieval**: Decomposes queries into Local, Bridge, or Global intents to traverse the entity relationship graph.
        *   **RAPTOR Hierarchical Search**: Fetches leaf-level facts alongside parent summaries from the GMM-clustered tree.
    *   All post-retrieval processing—including reranking via **BGE Reranker INT8 ONNX** and prompt compression via **LLMLingua-2**—is offloaded to the host CPU.

---

## Component Setup & Deployment

### 1. CPU-Offloaded LanceDB & Reranking Setup
The RAG pipeline operates locally on the host CPU to protect GPU VRAM:
1.  Ensure the ONNX reranker model (`model.onnx` and `model.onnx_data`) is placed under `./models/bge_reranker_onnx/`.
2.  Install dependencies:
    ```powershell
    pip install lancedb onnxruntime llmlingua
    ```
3.  The agent accesses this pipeline via the Workspace Skill `lancedb-raptor-rag-engine` dynamically.

### 2. Configure the MCP Server Launcher
The folder `mcp_server` contains a pre-configured Node.js launcher wrapper.
1.  Verify the environment settings inside [mcp_server/.env](mcp_server/.env):
    ```env
    EMBEDDING_PROVIDER=OpenAI
    OPENAI_BASE_URL=http://localhost:8080/v1
    OPENAI_API_KEY=llama-cpp
    EMBEDDING_MODEL=nomic-embed-text-v1.5.Q8_0
    MILVUS_ADDRESS=localhost:19530
    ```
2.  Install launcher dependencies:
    ```powershell
    # Run in the mcp_server folder
    cmd.exe /c npm install
    ```
3.  Run or register the launcher (`launch-mcp.js`). The script performs a check to verify that the RAG indexes are ready before starting the indexer.


---

## Integration with OpenCode / OpenChamber

We have provided two alternative configuration profiles in the `config/` directory:

1.  **Native 262k Profile** ([config/opencode_rag.json](config/opencode_rag.json)): Uses the full 262K native model context window. Recommended for single-agent deep analysis.
2.  **Virtual Context 22k Profile** ([config/opencode_virtual_ctx.json](config/opencode_virtual_ctx.json)): Caps the physical context window at 22K to support up to 16 concurrent agents in VRAM. Recommended for running high-concurrency workflows alongside our RAG memory loop.

To activate one of the configurations:
1.  Locate your active OpenCode configuration file at:
    `%USERPROFILE%\.config\opencode\opencode.json`
2.  Backup your existing configuration file.
3.  Copy the contents of either `config/opencode_rag.json` or `config/opencode_virtual_ctx.json` to replace it.
4.  Restart your OpenCode server or OpenChamber workspace in VS Code.

---

## Virtual Context (10K Cap) & Memory Loop Design

1.  **Client-Side Context Setup (Critical)**: The client application (e.g. Hermes Agent `config.yaml` or OpenCode `opencode.json`) MUST have its `context_length` set to the target size (e.g. `1,000,000`). If configured to a lower limit, the client will truncate the history array locally before transmission. This prevents the proxy from intercepting and indexing the truncated messages into the vector database, permanently losing those memories.
2.  **Proxy Truncation & Memory Loop**: When the proxy receives the 1M token payload, it indexes the message chunks into LanceDB/Milvus, truncates the active prompt down to the virtual context cap (e.g., `10,000` tokens), appends a `[SYSTEM WARNING]`, and forwards the compact prompt to the GPU LLM engine.
3.  **VRAM Efficiency & RAG Retrieval**: Since the LLM receives the system warning, it knows older conversation context exists in the DB. When needed, the agent invokes `retrieve_chat_memory` to fetch a small segment (under 1K tokens), keeping active VRAM consumption capped at 10k/22k tokens. This guarantees that **32 agents** can run simultaneously in GPU VRAM without causing swapping latency or OOM crashes.

---

## Deliberations on Scaling Beyond 1 Million Context (NVMe Storage System)

Configuring the agent's target context to **more than 1 million tokens (e.g., 10M, 100M, or more)** is highly beneficial for extensive multi-agent projects, codebases, and long-term execution threads. Because the storage layer is hosted on high-speed NVMe drives, we can allocate a large partition (e.g., **1 TB**) to support this architecture.

### Storage Capacity Calculations (1 TB NVMe Allocation)
*   **Vector Footprint**: Using `nomic-embed-text-v1.5` (768-dimension vectors), each text chunk is embedded into a vector.
    $$\text{Size per Vector (FP32)} = 768 \times 4 \text{ bytes} = 3072 \text{ bytes} \approx 3 \text{ KB}$$
*   Assuming an average chunk size of 512 tokens (~2000 characters), 1 million tokens represents about 2,000 chunks (vectors).
    $$\text{VDB Storage per 1M tokens} = 2,000 \times 3 \text{ KB} = 6 \text{ MB}$$
*   For **1 billion tokens** of agent memory, the vector database requires only **6 GB** of disk space (including indexing overhead, this scales to ~10-12 GB).
*   **1 TB of NVMe storage** can store **~80-100 billion tokens** of historical agent workspace memory, code indexes, and conversation logs.

### Key Considerations for Multi-Million Token Scaling
1.  **Payload Serialization & Networking Overhead**: If the client context is set to 10M+ tokens, the HTTP payload containing raw JSON chat history sent from the client to the proxy on every turn will grow to ~30-40 MB. This causes serialization latency in Node.js/Python and network transfer delays.
2.  **Hierarchical Vector Search**: As the database grows to hundreds of millions of vectors, search latency could degrade. However, Milvus/LanceDB's HNSW and IVF indexes keep queries sub-millisecond on NVMe-backed structures.
3.  **Dynamic Compression (LLMLingua-2)**: Scaling retrieved context from large memories requires CPU-based compression to ensure the active context remains under the 10k/22k VRAM cap. A multi-million context architecture relies heavily on efficient token compression to avoid bottlenecking the prefill stage.

---

## Database Backups to Google Drive (G:)

To protect your RAG memories and code indices from drive failures, we have provided an automated PowerShell script `backup-db.ps1` in the repository root.

### How to Run Backups:
1. Make sure your Google Drive desktop app is running and your Drive is mounted as `G:`.
2. Run the script from PowerShell:
   ```powershell
   ./backup-db.ps1
   ```
The script uses `Robocopy` to mirror the `./volumes` directory incrementally, making it extremely fast and cloud-sync friendly.
