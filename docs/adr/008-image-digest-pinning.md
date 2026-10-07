# ADR-008: Images Are Pinned by Version Tag, Not by Digest

**Status:** Accepted, with the limits stated below

> **Amended 2026-10-07.** The decision stands. Most of the reasoning given for it
> did not survive being checked against the repository, and has been replaced:
> ECR tags here are mutable, not immutable; digest updates can be automated;
> Trivy scans the repository's files, not the images, and would not notice a
> swapped image in any case; and Docker Content Trust was offered as a control
> that is not enabled anywhere. Dependabot now covers every image.

**Date:** 2026-05-01

---

## Context

Every image this project runs is named in one of three places: nine third-party images in `docker-compose.yml` (Prometheus, Grafana, Loki, nginx and so on), one base image in four Dockerfiles (`python:3.11-slim`), and four images of our own that CI builds and the deploy pulls from ECR.

An image can be referred to in three ways:

| Form | Example | What it guarantees |
|---|---|---|
| Floating tag | `grafana/grafana:latest` | Nothing. A different image every time upstream releases |
| Version tag | `grafana/grafana:13.2.3` | The publisher's intent. They can still push new bytes under the same tag |
| Digest | `grafana/grafana@sha256:…` | The exact bytes. A digest is a hash of the image, so it cannot be moved |

A tag is a label that someone can move. That is the entire problem. In March 2025 the GitHub Action `tj-actions/changed-files` was compromised and its existing version tags were pointed at a malicious commit; every pipeline that referred to it by tag ran the attacker's code on its next run, with no change on the victim's side. Container image tags work the same way.

## Decision

1. **Third-party images: an exact version tag, never `latest`.** Not a digest.
2. **Our own images: deployed by the commit-SHA tag** that the pipeline built in the same run.
3. **Dependabot proposes every upgrade** (compose images, Dockerfile base images, Python packages, GitHub Actions, Terraform providers), grouped into one pull request per ecosystem per month.
4. **GitHub Actions are pinned to release tags**, never to a branch such as `@master`.

## What this protects against, and what it does not

**It does protect against** silent drift. Nothing changes version unless a commit changes it, so "what is running" is answerable from git, an upgrade is a reviewable diff, and CI runs against the new version before it is deployed. This was not true before October 2026: nothing watched the compose images, and the monitoring stack was found two major versions behind without a single pull request ever having been opened.

**It does not protect against** a publisher, or someone who has taken over a publisher's account, re-pushing an existing tag. `prom/prometheus:v3.15.0` would then pull different bytes and nothing here would notice.

**Our own images are not immune either,** and an earlier version of this record said they were. The ECR repositories are `MUTABLE`, because the pipeline moves two tags on every build (`main` and `latest`) alongside the SHA tag. "One SHA tag is one image" is therefore a convention the pipeline follows, not something the registry enforces: anything with push access could overwrite a SHA tag. Enforcing it means `IMMUTABLE` repositories, dropping the moving tags, and making the push idempotent, since re-running a pipeline for the same commit would otherwise fail on a tag that already exists.

**Scanning does not close the gap.** Trivy in CI scans this repository's files (dependency manifests, Dockerfiles, Terraform) and reports to the Security tab without failing the build. ECR scans our four images when they are pushed. Both look for *known vulnerabilities in listed packages*. A deliberately backdoored image has no CVE and would pass both.

## Why not digests

The honest reason is review cost, not tooling. The tooling exists: Renovate can pin and update digests (`pinDigests`), and Dependabot updates a digest when a reference already carries one.

What pinning by digest costs is noise. Upstream images are rebuilt under the same version tag whenever their base image gets security patches, so a digest-pinned `nginx:1.30.5-alpine` produces an update pull request with no version change, repeatedly, across nine images. For one maintainer that is a stream of diffs nobody can meaningfully review (a hash changed to another hash), which trains the reviewer to merge without looking. A control that is routinely rubber-stamped is not a control.

So the trade is explicit: accept the residual risk of a re-pushed upstream tag, in exchange for upgrade pull requests that are few enough to actually read.

## When this decision would change

- **Real data or a compliance requirement.** Then: digests for everything, updated by Renovate, plus signature verification (cosign) at deploy time so that the cluster refuses an image that the build did not sign. Docker Content Trust, which an earlier version of this record leaned on, is the older Notary-based mechanism and is being retired in favour of Sigstore; it is not enabled here and should not be relied on.
- **More than one person with push access to the registry.** Then `IMMUTABLE` tags stop being optional.
- **A deployment that pulls on its own schedule** (Kubernetes with `imagePullPolicy: Always`). A moved tag then reaches production without any deploy. Here an image is only pulled when `deploy.sh` runs.

## The Interview Answer

"A tag is a label somebody can move; a digest is a hash of the bytes and cannot be. I pin third-party images to exact version tags and let Dependabot propose upgrades monthly, grouped, so every change of version is a diff I review and CI tests. That stops silent drift, which was my real problem: my monitoring stack had fallen two major versions behind because nothing was watching those images. It does not stop a compromised publisher re-pushing a tag, and I do not pretend it does. I chose not to pin digests because upstream rebuilds would give me a constant stream of hash-to-hash pull requests that I would end up merging blind. And I corrected myself on one point: I used to say my own SHA-tagged images were immutable. They are not; the repositories allow tags to be overwritten because the pipeline moves `latest`. With real data I would use immutable tags, digests through Renovate, and verify signatures at deploy."
