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

## SSH access to a new host (1Password SSH agent)

1. Generate the key inside 1Password so the private half never touches disk:
   `op item create --category "SSH Key" --ssh-generate-key ed25519 --vault <vault> --title "<Host> SSH Key" --format json`.
   Keep only the public key and fingerprint from the JSON; match existing
   key-item naming in that vault.
2. Serve it: add an `[[ssh-keys]]` block (`item`, `vault`) to
   `~/.config/1Password/ssh/agent.toml`, after backing the file up, then confirm
   with `ssh-add -l` against the 1Password agent socket.
3. Save the public key to a file outside any version-controlled `~/.ssh` and
   connect with `-o IdentitiesOnly=yes -i <pubkey file>`; the agent offers
   keys in order and servers cap auth attempts, so without it the right key
   may never be tried.
4. Authorize on the target: the user enables SSH (macOS: System Settings →
   General → Sharing → Remote Login), copies the item's public key field and
   runs `mkdir -p ~/.ssh && chmod 700 ~/.ssh && { pbpaste; echo; } >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys`.
   If the target's `~/.ssh` is a dotfiles symlink, keep `authorized_keys` out
   of that repo.
5. Verify: first connect with `StrictHostKeyChecking=accept-new`, `BatchMode=yes`,
   and report the host-key fingerprint.

Reachability: test the port (`nc -z -G 8 <host> 22`), not ping. A sleeping
Mac's Wi-Fi chip can answer ping (slowly) while SSH is closed. A closed-lid
MacBook sleeps, and an incoming connection only wakes it through a Bonjour
sleep proxy (`dns-sd -B _sleep-proxy._udp local.`). Without one, the user
opens the lid or runs `sudo pmset -a disablesleep 1` (undo with `0`).
