# terraform/ — starts services on registered NIOS-X hosts

Normally you don't run this directly: `../niosx deploy` and
`../niosx add` drive it for you.

It starts the services listed in `niosx_hosts.json` (gitignored, per-user,
written by `../niosx add`):

```json
{
  "<owner>-<vmid>": {
    "pool_id": "infra/pool/<id>",
    "services": ["dns", "dhcp"]
  }
}
```

`pool_id` **must** keep the `infra/pool/` prefix. The API returns a bare id at
`detail_hosts[].pool.pool_id`; the provider normalises to the prefixed form and
fails with *"inconsistent result after apply"* if you pass the bare one.

## Manual use

```bash
cp secrets.auto.tfvars.example secrets.auto.tfvars   # add your CSP API key
tofu init
$EDITOR niosx_hosts.json
tofu plan && tofu apply
```

Remove a host or service from the JSON and apply = those services are stopped
and removed. `tofu destroy` removes everything **you** started (state is local
to your machine, so it never touches anyone else's hosts).

## Notes

- Requires OpenTofu (`tofu`). The lock file pins `registry.opentofu.org`.
- Service names are `<label>-<service>`, e.g. `sholland-202-dns` — the label is
  the JSON key. Keep it unique; the CSP tenant is shared.
- If an apply errors, the resource may be left **tainted** even though it was
  created. `tofu untaint '<address>'` rather than letting a re-apply destroy and
  recreate a live service.
