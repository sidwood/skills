---
name: secret-provisioning
description: Use when provisioning credentials into applications.
---

# Secret Provisioning

Provision one credential through the target application's supported secret
boundary, without disclosing it, and verify the real integration.

## Workflow

1. Establish the contract: identify the target application and profile, the
   credential field or environment key, its supported secret destination, and
   the non-secret setting that selects the provider. Read current authoritative
   documentation when the names or integration contract could have changed.
2. Identify the secret manager's authorization mode and locator model from its
   current documentation. Discover only non-secret metadata first, using its
   native hierarchy and immutable identifiers rather than assuming accounts,
   vaults, paths, versions, or labels have universal meanings.
3. Resolve ambiguity before extraction. Require exactly one authorized source
   object, version when relevant, and field matching the documented locator or
   format. Stop on zero or multiple candidates rather than guessing.
4. Extract only the required field inside one process or pipeline. Keep its
   value in memory or standard input; keep shell tracing disabled. Never place
   it in command arguments, chat, logs, source control, clipboard history, or an
   agent-controlled temporary plaintext file.
5. Write through the application's native secret store when it has one. Keep
   provider selection and other non-secret behavior in the application's normal
   configuration. Preserve unrelated secrets and configuration.
6. For a dotenv destination, use the application's or repository's supported
   writer. Before editing directly, establish its dotenv grammar, symlink and
   ownership requirements, concurrent-writer behavior, and required mode. Do
   not invent quoting or replacement semantics for an unknown consumer.
7. Verify metadata only: the selected provider, destination path, exactly one
   matching field or assignment, expected non-secret format characteristics,
   and restrictive permissions. State whether a running process requires a
   restart.
8. Exercise the application's native integration with the smallest operation
   that proves authentication. For a leased or metered resource, release it in
   a `finally` path and verify the provider reports it closed.
9. Report the integration result and cleanup evidence without reproducing the
   credential or secret-bearing output. Completion requires successful native
   authentication and verified cleanup of every created metered resource.

## Rules

- Treat a stored credential as unverified until the application's own path
  authenticates successfully.
- Minimize secret-store access: metadata before values, immutable identifiers
  before display names, and one field rather than a complete object.
- Preserve identifiers, account names, field labels, configuration keys, and
  provider prefixes exactly.
- Do not substitute a hand-built API call when the requested application has a
  native integration path.
- Treat disconnection and resource release as separate events; verify the
  provider-side resource state.
- Stop when the destination cannot accept the credential without disclosure.
  Ask the user for a safer supported boundary rather than weakening handling.

For 1Password discovery and extraction, read
[references/onepassword-cli.md](references/onepassword-cli.md).
