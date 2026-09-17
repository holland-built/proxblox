# Tests

```bash
./niosx test            # everything
python3 tests/test_deploy.py
```

No Proxmox host and no Infoblox tenant is contacted. `tests/stubs/` shadows
`ssh`, `rsync`, `curl` and `tofu` on `PATH`, and each case gets a throwaway
`config.env`, qcow2, join token and API key in a temp directory — your real
ones are never read (`NIOSX_CONFIG`, `NIOSX_SECRETS`, `NIOSX_TOKEN_FILE`,
`NIOSX_STATE_DIR`).

## Why a pty

The prompts are behind `[ -t 0 ]`, so a plain `subprocess` never reaches them —
which is exactly why the interactive path went untested for so long.
`tests/harness.py` allocates a real pty, waits for output to go quiet, and then
answers the prompt, the way a person does.

## What the stubs let you set up

| Variable | Effect |
|----------|--------|
| `STUB_QM_CONFIG` | what `qm config` returns (empty = the VM does not exist) |
| `STUB_QM_STATUS` | `stopped` or `running` |
| `STUB_HALT=1` | abort at the first step that would change anything |
| `STUB_HTTP` | HTTP code for the CSP key check (e.g. `401`) |
| `STUB_APPS_FAIL=1` | make the applications API unreachable |
| `STUB_NAME_TAKEN=1` | the tenant already has a host with that name |

Two files record what happened: `STUB_LOG` (which steps ran — `RSYNC`,
`QM-START`, `REMOTE-SCRIPT`) and `STUB_CAPTURE` (the exact script that would
have run as root on Proxmox). Assertions use both, so a test can prove a step
was *not* taken, not just that a message was printed.

## Adding a case

```python
case("out-of-range number is rejected",
     inputs=["", "", "99"], rc=1,
     has=["!! no service numbered 99"], log_hasnt=["RSYNC"])
```

`has`/`hasnt` check the output, `log_has`/`log_hasnt` check which steps ran,
`capture_has` checks the remote script, `rc` checks the exit code.

## Keep them honest

A green suite proves nothing on its own. Break the behaviour on purpose and
confirm the test goes red — removing the name validation and unquoting
`--name` in `scripts/deploy-niosx.sh` must fail six cases.
