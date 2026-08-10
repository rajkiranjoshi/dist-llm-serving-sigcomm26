# Distributed LLM Serving (non-paper session at SIGCOMM 2026)

This repo contains the artifacts (including the post-session deliverables) related to the non-paper session on distributed LLM serving held at ACM SIGCOMM 2026 in Denver, Colarado, USA.

## About the session

**Beyond GPUs: Networking and Systems Problems in Distributed LLM Serving**

LLM serving is rapidly becoming as ubiquitous as traditional web serving. Under the hood, large-scale distributed LLM inference depends on components that touch topics already familiar to the SIGCOMM community: request routing and scheduling, topology-aware placement, storage/cache management, networking and transport, tracing/observability, etc.; many of which can be studied without requiring GPU hardware. This interactive non-paper session will introduce the distributed LLM inference stack in a structured way (prefill vs. decode, disaggregation, batched vs. online serving), then use a live interactive board to drill down into individual components and brainstorm how classic networking/systems concepts and ideas apply. We will also give a brief tour of llm-d, a vendor-neutral open-source framework for distributed LLM serving, and close with practitioner perspectives on current industry pain points. Attendees will leave with a clear mental model of the distributed LLM serving stack, a practical open-source on-ramp via llm-d, and concrete directions for impactful contributions.

## Artifacts Directory

TODO: add a directory tree at the end


