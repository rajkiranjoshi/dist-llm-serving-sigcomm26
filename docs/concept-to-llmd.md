# Concept to llm-d component mapping

| Concept/Topic | llm-d component | Link to src code |
|---------------|-----------------|------------------|
| Request routing / load balancing | "llm-d router" i.e. EPP | |
| Request scheduling (SLO, prioritization, isolation) | Flow Control | |
| RDMA Networking | N/A. Libraries driving RDMA networking are bundled with the inference engine (e.g. vLLM). See NIXL, DeepEP, Mori-EP. | |
| Auto-scaling | | |
| KV cache storage and management | | |
| Telemetry, tracing and diagnostics (Observability) | | |
| Fault Tolerance | | |