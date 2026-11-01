# github-runner stack

A self-hosted GitHub Actions runner on the official image, with its own private Docker
daemon. Workflows install their own dependencies. Deployed from
`docker-compose.github-runner.yml` via the Docker Compose Manager plugin.

## Services

| Service | Image | Purpose | UI port |
|---|---|---|---|
| `runner` | ghcr.io/actions/actions-runner | Registers with GitHub and runs one job at a time | — |
| `dind` | docker:dind | Docker daemon for the runner's jobs, separate from the host's | — |

## Deploying

1. Copy the entrypoint into place:

   ```sh
   mkdir -p /mnt/user/appdata/github-runner
   cp /path/to/repo/github-runner/entrypoint.sh /mnt/user/appdata/github-runner/entrypoint.sh
   ```

   Do this **before** the first start: a bind mount whose source is missing makes Docker
   create a directory at that path, and the runner can't start.

2. Create the PAT (below), copy `.env.example` to `.env`, and fill it in.

3. Start the stack from the Compose Manager plugin.

## PAT permissions

Use a fine-grained PAT. `RUNNER_URL` sets the scope, and the scope sets the permission:

| Scope | `RUNNER_URL` | Permission |
|---|---|---|
| Organization | `https://github.com/<org>` | Organization "Self-hosted runners": read and write |
| Repository | `https://github.com/<owner>/<repo>` | Repository "Administration": read and write |

Personal accounts have no account-level runners, so each personal repo needs repo scope.

## Using it from a workflow

```yaml
runs-on: [self-hosted, antarctican]
```

The image is not `ubuntu-latest`. It has no guaranteed node, Java, pwsh or Docker Compose,
so a workflow must install what it uses.

## Security

**Never attach this runner to a public repo.** A fork PR can run code on it. At org scope,
leave public repos out of the runner group.

The private daemon keeps other stacks out of a job's Docker API, but it isn't a security
boundary. `dind` is privileged, so a job that starts a privileged container can reach the
host. A job with `sudo` can also replace a binary in the writable layer, and the next start
runs it with `GITHUB_PAT` in its environment. Treat every workflow on this runner as having
root on the host and the PAT.

## Notes

- **One job at a time.** To serve a second scope or add concurrency, add another runner and
  dind pair of services with its own volumes and `RUNNER_NAME`.
- **Each job starts clean, with exceptions.** The runner is ephemeral: it exits after one
  job, `restart: unless-stopped` restarts the same container, and the entrypoint resets the
  files and the daemon before registering again. The writable layer survives that restart,
  so a `sudo apt install` from a job, or a non-hidden file in the home directory, persists
  until the container is recreated.
- **Cleanup runs before each job.** Workspace, hidden home files, temp files, containers and
  volumes are cleared every time. Images are removed 7 days after they were pulled, and
  build cache after 7 days. Change `168h` in `entrypoint.sh` to adjust both.
- **Size the Docker vdisk for this stack.** The named volumes live inside Unraid's Docker
  vdisk, shared with every other stack. Cleanup has no size limit and can't interrupt a
  running job, so leave room for a week of images plus your largest job's workspace.
- **Editing `entrypoint.sh`** means copying it to appdata again and restarting the runner.
