# janitor Tilt extension

`janitor_local_resource` is a drop-in wrapper for Tilt `local_resource`. It
wraps `serve_cmd` with `janitor` by default so dev-server process trees are
drained when Tilt dies unexpectedly or the watched worktree disappears.

janitor supports macOS and Linux. Windows `*_bat` commands are not wrapped.

## Install

Register this repository as a custom extension repo, then load `ext://janitor`.
Pin `ref` to the first release tag that contains `tilt/janitor/`; use `main`
before that release exists.

```python
v1alpha1.extension_repo(
    name='janitor',
    url='https://github.com/alleneubank/janitor',
    ref='vX.Y.Z',  # pin to the FIRST release tag that ships tilt/janitor/
)
v1alpha1.extension(name='janitor', repo_name='janitor', repo_path='tilt/janitor')
load('ext://janitor', 'janitor_local_resource')
```

Vendored projects can load the extension directly:

```python
load('./tilt/janitor/Tiltfile', 'janitor_local_resource')
```

## Usage

Before:

```python
local_resource(
    'anvil',
    serve_cmd='anvil --host 0.0.0.0',
    deps=['foundry.toml'],
    allow_parallel=True,
)
```

After:

```python
janitor_local_resource(
    'anvil',
    serve_cmd='anvil --host 0.0.0.0',
    deps=['foundry.toml'],
    allow_parallel=True,
)
```

`serve_cmd` is wrapped by default. Other keyword arguments are forwarded to
`local_resource` unchanged. `cmd` is forwarded unchanged unless `wrap_cmd=True`
is set:

```python
janitor_local_resource(
    'indexer',
    cmd='npm run build:indexer',
    serve_cmd=['npm', 'run', 'dev:indexer'],
    wrap_cmd=True,
    grace_ms=3000,
)
```

String commands keep Tilt's shell behavior and become:

```python
['janitor', '--watch-path', config.main_dir, '--grace-ms', '5000', '--', 'sh', '-c', '<command>']
```

List commands keep argv behavior and become:

```python
['janitor', '--watch-path', config.main_dir, '--grace-ms', '5000', '--', '<argv0>', '<argv1>']
```

For an outer guard around Tilt itself, use the returned command in a Makefile,
justfile, or shell alias:

```python
load('ext://janitor', 'janitor_tilt_up_cmd')

print(janitor_tilt_up_cmd())
```

## Auto-Install

The extension resolves janitor in this order:

1. a per-call `janitor_bin=` argument, or the `JANITOR_BIN` environment variable
2. `janitor` on `PATH`
3. `$PREFIX/bin/janitor` with `PREFIX` defaulting to `~/.local`
4. auto-install through `install.sh`
5. fail with install instructions

Steps 1–3 run once when the Tiltfile loads. Auto-install (step 4) is deferred to
the first wrapped resource, **after** any per-call `janitor_bin` is considered,
so an explicit `janitor_bin` (or a binary already on `PATH`/`$PREFIX/bin`) is
never preempted by a network install — offline and vendored projects can pin a
binary and stay offline.

Auto-install is on by default on macOS and Linux. Disable it with:

```sh
JANITOR_AUTO_INSTALL=0 tilt up
```

Pin or relocate the install:

```sh
JANITOR_VERSION=vX.Y.Z tilt up
PREFIX=/usr/local tilt up
JANITOR_BIN=/path/to/janitor tilt up
```

`install.sh` selects the host release archive and verifies it against the
SHA-256 sidecar before installing to `$PREFIX/bin/janitor`.

## Grace Window

The extension default is `grace_ms=5000`, intentionally longer than janitor's CLI
default because dev servers often need a few seconds to flush files and release
ports after `SIGTERM`.

Keep `grace_ms` comfortably below Tilt's own serve-command kill timeout. During
a graceful Tilt stop, Tilt sends `SIGTERM` to janitor and later `SIGKILL`s it; if
the janitor grace window is longer than Tilt's timeout, Tilt can kill janitor
mid-drain and the process tree can leak.
