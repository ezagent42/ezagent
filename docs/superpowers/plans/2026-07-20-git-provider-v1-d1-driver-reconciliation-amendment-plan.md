# Git Provider V1 D1 Driver Reconciliation Amendment Plan

**Goal:** Close the ambiguous provider-effect callback window without guessing an
external result or weakening D0 secret/authority boundaries.

1. Write RED conformance and callback-recovery barriers for reconciliation,
   confirmed absence, ambiguous absence, and terminal completion.
2. Add the closed `Driver.reconcile_callback/1` contract and registry validation;
   implement it in both fake drivers and remote-shaped conformance fixtures.
3. Rebuild a private callback exchange only from durable backend data, reconcile
   prepared operations using the original stable correlation, journal the opaque
   result, and route it through existing cleanup obligations.
4. Make terminal/recovery refuse finalization while a callback reconciliation is
   unresolved; ensure full pair/class/correlation/digest keys are used.
5. Run guarded fresh-partition focused tests, provider suite, formatter/diff
   checks, independent review, then Task 9 recovery work.

All Mix commands remain serialized inside the 1 GiB user cgroup. Protected
handoffs and task reports are never staged, edited, or removed.
