import os
import lancedb
from lancedb.embeddings import get_registry
from lancedb.pydantic import LanceModel, Vector

def get_py_files(directory):
    py_files = []
    for root, _, files in os.walk(directory):
        for file in files:
            if file.endswith('.py'):
                py_files.append(os.path.join(root, file))
    return py_files

def chunk_file(file_path, base_dir, chunk_size=30, overlap=10):
    rel_path = os.path.relpath(file_path, base_dir)
    chunks = []
    with open(file_path, 'r', encoding='utf-8', errors='ignore') as f:
        lines = f.readlines()
    
    total_lines = len(lines)
    start = 0
    while start < total_lines:
        end = min(start + chunk_size, total_lines)
        chunk_lines = lines[start:end]
        code_content = "".join(chunk_lines)
        
        # Format chunk text with metadata header for context preservation
        chunk_text = f"File: {rel_path} (Lines {start+1}-{end})\n\n```python\n{code_content}```"
        chunks.append({"text": chunk_text})
        
        start += (chunk_size - overlap)
        if start >= total_lines or end == total_lines:
            break
            
    return chunks

def main():
    repo_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), "requests_repo/src/requests"))
    db_path = os.path.abspath(os.path.join(os.path.dirname(__file__), "../data/lancedb_store"))
    
    if not os.path.exists(repo_dir):
        print(f"Error: Repository directory not found at {repo_dir}")
        return

    print(f"Scanning python files in: {repo_dir}...")
    py_files = get_py_files(repo_dir)
    print(f"Found {len(py_files)} Python source files.")

    # Generate chunks
    all_chunks = []
    for file_path in py_files:
        file_chunks = chunk_file(file_path, os.path.dirname(repo_dir))
        all_chunks.extend(file_chunks)
    
    print(f"Generated {len(all_chunks)} code chunks.")

    # Initialize LanceDB
    os.makedirs(os.path.dirname(db_path), exist_ok=True)
    db = lancedb.connect(db_path)

    # Use a small local model for embedding
    embedding_func = get_registry().get("sentence-transformers").create(name="BAAI/bge-small-en-v1.5")

    class RaptorIndex(LanceModel):
        text: str = embedding_func.SourceField()
        vector: Vector(embedding_func.ndims()) = embedding_func.VectorField()

    table_name = "raptor_collapsed_index"
    print(f"Overwriting LanceDB table '{table_name}' at {db_path}...")
    table = db.create_table(table_name, schema=RaptorIndex, mode="overwrite")

    # Ingest chunks
    print("Computing embeddings and adding to database (running locally on CPU)...")
    batch_size = 64
    for i in range(0, len(all_chunks), batch_size):
        batch = all_chunks[i:i+batch_size]
        table.add(batch)
        print(f"  Added batch {i//batch_size + 1}/{len(all_chunks)//batch_size + 1} ({len(batch)} chunks)...")

    print("Creating vector index IVF_RQ...")
    table.create_index(vector_column_name="vector", index_type="IVF_RQ")
    
    print("Ingestion of 'requests' repository completed successfully!")

if __name__ == "__main__":
    main()
