# ADR-008: Container Image Tag Pinning vs Digest Pinning

**Status:** Accepted with documented limitations
**Date:** 2026-05-01

---

## Context

Our docker-compose.yml and CI/CD pipeline pull container images. We need to decide how to reference those images: by tag, by tag+digest, or by digest only.

Examples:
- Tag only: `grafana/grafana:11.4.0`
- Tag + digest: `grafana/grafana:11.4.0@sha256:a1b2c3...`
- Digest only: `grafana/grafana@sha256:a1b2c3...`

## The Problem With Tags

Docker tags are **mutable**. The publisher can push a new image to the same tag at any time. `grafana/grafana:11.4.0` today and `grafana/grafana:11.4.0` tomorrow could be different bytes.

This is the supply chain attack vector: an attacker who compromises the publisher's Docker Hub account can push a malicious image to an existing tag. Every `docker compose pull` on your servers would silently pull the compromised image.

This is not theoretical. The `codecov/codecov-action` supply chain attack (2021) compromised thousands of CI pipelines by injecting malicious code into a dependency. Container images have the same risk profile.

**The attack flow:**
```
Attacker compromises DockerHub account for library X
    ↓
Pushes malicious image to existing tag (e.g., grafana:11.4.0)
    ↓
Our deployment pulls the "latest" image on next restart
    ↓
We run attacker-controlled code with full container privileges
```

## What Digest Pinning Does

A digest (`sha256:a1b2c3...`) is a cryptographic hash of the exact image contents. It is **immutable** — the same digest will always point to the same bytes, forever, regardless of what the publisher does.

```yaml
# Tag — mutable, pullable tomorrow as different image
image: grafana/grafana:11.4.0

# Digest pinned — immutable, always exactly this build
image: grafana/grafana:11.4.0@sha256:abf4a6219d62b36a5f5b7b35b4c01e5f3c1a...
```

## Our Decision

We pin by **version tag only** in docker-compose.yml, with the following accepted limitations:

### Why not full digest pinning here

1. **Digest maintenance overhead**: Every image update requires looking up the new digest (`docker inspect --format='{{index .RepoDigests 0}}'`). For a solo project with 15+ external images, this adds significant maintenance work on every update.

2. **No clear automation path**: Dependabot and Renovate can update version tags automatically. Digest pinning requires custom tooling or manual updates — there is no standard automated solution that works for all registries.

3. **Our actual images are in ECR**: The 4 images we control (secureship, ragservice, statusservice, llm-alert-autopilot) are pushed to our ECR registry via CI/CD. They are already immutable at the ECR level — once a digest is pushed, it cannot be overwritten because we use commit SHA tags, not `latest`.

4. **Risk profile at our scale**: We are running a demo/portfolio project. The realistic risk is low. The operational burden is high.

### What we do instead

**For our own images (ECR):** We pin by git commit SHA (`secureship:abc1234`), not `:latest`. This is functionally equivalent to digest pinning — each SHA points to exactly one build and cannot be overwritten.

**For external images (Grafana, Prometheus, etc.):** We pin to specific version numbers (`grafana:11.4.0`, not `grafana:latest`). This is not digest pinning but eliminates the most common attack vector (upstream using `latest`).

**Trivy scanning in CI:** We scan all images for known CVEs on every push. A newly compromised image would introduce new vulnerabilities that Trivy would detect on the next CI run.

**Docker Content Trust (DCT) in production:** When deploying on EC2, we can enable `DOCKER_CONTENT_TRUST=1` which forces Docker to verify image signatures. This requires publishers to sign their images (Grafana does; most major publishers do).

## When This Decision Would Change

If this project moves to a regulated environment (banking, healthcare, government) with supply chain requirements, full digest pinning becomes mandatory. The tooling to manage it is:

- **Renovate** with `pinDigests: true` — automatically opens PRs to update digests
- **Cosign** (Sigstore) — image signing and verification standard, increasingly adopted
- **SLSA** (Supply Chain Levels for Software Artifacts) — Google's framework, growing adoption

These tools make digest pinning operationally sustainable. We'd adopt them at the point where supply chain compliance is a hard requirement.

## The Interview Answer

"We pin our own images by git commit SHA in ECR — that's equivalent to digest pinning because SHA tags are immutable. For external images, we pin to specific version numbers rather than `latest`, which eliminates the most common vector. We run Trivy on every build, which catches newly introduced CVEs even if we don't pin by digest. The full digest pinning story is: tags are mutable and a compromised publisher can silently swap your image. Digests are cryptographic hashes — immutable by definition. In production at scale, I'd use Renovate with `pinDigests: true` to automate digest updates and Cosign for image signing verification. We accept the tag-only approach here because the operational burden doesn't justify it for a solo project, and our CI/CD pipeline's Trivy scanning catches the actual risk (CVEs), which is more practical than the theoretical supply chain attack."
