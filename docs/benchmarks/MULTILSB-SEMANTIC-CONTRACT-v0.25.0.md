# MULTILSB semantic contract - v0.25.0

The 120 official instances are normalized into deterministic JSON documents without changing their source semantics.

The audit confirms that LotSizingDataModel already represents carried backlog, backlog limits, backlog costs, solution backlog levels and the corresponding solver balance terms. Backlogging is therefore not the remaining admission blocker.

The source Mosel model also uses a shared family setup binary `w[t,f]`. Activating any member item requires this family binary, and `v[f,k] * w[t,f]` consumes machine capacity. No lossless canonical counterpart was found for this shared family-level setup decision and its capacity consumption. Replacing it with per-item setups would change feasible solutions and objective/capacity semantics, so v0.25.0 deliberately performs no canonical XML admission.

Every normalized document preserves resource-utilization parameters, production coefficients, family membership, family setup times, the 72 BOM arcs, marginal holding costs and all demand values. Reload validation is required for all 120 files.
