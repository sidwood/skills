# 1Password CLI provisioning

Use this branch only when the requested credential is stored in 1Password and
the `op` CLI is already authorized. Determine the authorization mode first;
interactive accounts and service accounts have different lookup contracts.

## Resolve without values

1. Establish whether authorization comes from an interactively configured
   account or `OP_SERVICE_ACCOUNT_TOKEN` without printing token values.
2. For interactive authorization, use `terminal` to run
   `op account list --format json`, retaining only account metadata. List vault
   metadata per account and treat vault IDs as account-scoped.
3. For a service account, require the known accessible vault name or ID before
   item retrieval. Do not use `op account list` to infer service-account
   identity, and pass `--vault <vault>` on item operations.
4. With interactive authorization and a supplied item UUID, resolve it across
   the selected authorized accounts. Treat the returned vault ID as
   authoritative rather than guessing from a display name.
5. Use title searches only when no immutable item ID is available. Require one
   result inside the selected account and vault boundary.

A failed title search does not prove absence. Titles may be generic, and a phrase
such as “personal vault” may describe ownership rather than a literal vault
name.

## Extract one field

- Retrieve only the exact field through a secret reference or parse the exact
  item inside the same process or pipeline.
- Select a field by its documented label and, when available, a non-secret format
  constraint such as a required prefix.
- Require one candidate; stop on zero or multiple matches.
- Pass the value directly over standard input to the application's supported
  destination writer.
- Keep raw item JSON and field values out of tool output, files, command
  arguments, shell history, and logs.

## Verify

- Confirm the resolved account, item UUID, vault ID, and field label as metadata.
- Confirm the target contains exactly one credential entry and has restrictive
  permissions.
- Exercise the target application's native integration.
- For cloud browsers or other metered leases, create the smallest useful
  resource, release it explicitly, and verify the provider reports it stopped.
