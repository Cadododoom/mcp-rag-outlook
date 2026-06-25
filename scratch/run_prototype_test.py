import os
import sys

# Add skills path to sys.path
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), "../.agents/skills/lancedb-raptor-rag-engine")))
from query_edge_rag import execute_tool

def main():
    print("Testing local RAG prototype retrieval and LLMLingua-2 compression...")
    query = "What are the database connection credentials for postgres?"
    print(f"Query: '{query}'\n")
    
    result_str = execute_tool(query, compression_rate=0.33)
    print("Response JSON:")
    print(result_str)

if __name__ == "__main__":
    main()
