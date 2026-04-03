# Computer Science > Cryptography and Security

**arXiv:2512.06556** (cs)

\[Submitted on 6 Dec 2025\]

# Title:Securing the Model Context Protocol: Defending LLMs Against Tool Poisoning and Adversarial Attacks

Authors: [Saeid Jamshidi](https://arxiv.org/search/cs?searchtype=author&query=Jamshidi,+S), [Kawser Wazed Nafi](https://arxiv.org/search/cs?searchtype=author&query=Nafi,+K+W), [Arghavan Moradi Dakhel](https://arxiv.org/search/cs?searchtype=author&query=Dakhel,+A+M), [Negar Shahabi](https://arxiv.org/search/cs?searchtype=author&query=Shahabi,+N), [Foutse Khomh](https://arxiv.org/search/cs?searchtype=author&query=Khomh,+F), [Naser Ezzati-Jivan](https://arxiv.org/search/cs?searchtype=author&query=Ezzati-Jivan,+N)

> Abstract:The Model Context Protocol (MCP) enables Large Language Models to integrate external tools through structured descriptors, increasing autonomy in decision-making, task execution, and multi-agent workflows. However, this autonomy creates a largely overlooked security gap. Existing defenses focus on prompt-injection attacks and fail to address threats embedded in tool metadata, leaving MCP-based systems exposed to semantic manipulation. This work analyzes three classes of semantic attacks on MCP-integrated systems: (1) Tool Poisoning, where adversarial instructions are hidden in tool descriptors; (2) Shadowing, where trusted tools are indirectly compromised through contaminated shared context; and (3) Rug Pulls, where descriptors are altered after approval to subvert behavior. To counter these threats, we introduce a layered security framework with three components: RSA-based manifest signing to enforce descriptor integrity, LLM-on-LLM semantic vetting to detect suspicious tool definitions, and lightweight heuristic guardrails that block anomalous tool behavior at runtime. Through evaluation of GPT-4, DeepSeek, and Llama-3.5 across eight prompting strategies, we find that security performance varies widely by model architecture and reasoning method. GPT-4 blocks about 71 percent of unsafe tool calls, balancing latency and safety. DeepSeek shows the highest resilience to Shadowing attacks but with greater latency, while Llama-3.5 is fastest but least robust. Our results show that the proposed framework reduces unsafe tool invocation rates without model fine-tuning or internal modification.

|     |     |
| --- | --- |
| Subjects: | Cryptography and Security (cs.CR); Artificial Intelligence (cs.AI) |
| Cite as: | [arXiv:2512.06556](https://arxiv.org/abs/2512.06556) \[cs.CR\] |
| DOI: | [https://doi.org/10.48550/arXiv.2512.06556](https://doi.org/10.48550/arXiv.2512.06556) |

- [View PDF](https://arxiv.org/pdf/2512.06556)
- [HTML (experimental)](https://arxiv.org/html/2512.06556v1)
