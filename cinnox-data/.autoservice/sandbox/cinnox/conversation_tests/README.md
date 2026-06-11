# conversation_tests

Heavy-eval test cases. Each `*.yaml` file is one case with the shape:

```yaml
case_id: refund_pricing_q
description: Customer asks refund-eligible products and pricing
messages:
  - role: customer
    text: 我想问下退货政策
expect:
  - contains: 退货
  - not_contains: 不能退
```

Full schema: docs/superpowers/specs/2026-05-13-cr-proposal-impact-evaluation-design.md §3.2

Goodhart-protected: dream agent cannot author these cases — only master_admin via CR.
