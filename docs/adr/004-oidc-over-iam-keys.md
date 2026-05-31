# ADR-004: OIDC Authentication for CI/CD Instead of IAM Access Keys

**Status:** Accepted
**Date:** 2026-05-01

---

## Context

GitHub Actions needs to push Docker images to ECR, run Terraform, and deploy to EC2. This requires AWS credentials. The traditional approach is to create an IAM user, generate access keys, and store them as GitHub secrets.

## Decision

Use OpenID Connect (OIDC) to give GitHub Actions temporary AWS credentials tied to a specific repository and branch. No long-lived access keys anywhere.

## Rationale

**The problem with IAM access keys:**

IAM access keys are static credentials. They:
- Never expire by default
- Are valid from anywhere in the world
- Must be manually rotated
- Can be accidentally committed to git
- Give the same permissions for months or years until rotated
- If leaked in a build log, workflow output, or via supply chain attack — the attacker has persistent AWS access

This is not a theoretical risk. AWS publishes regular security bulletins about access key exposure. GitHub themselves scans public repos for exposed AWS keys.

**How OIDC works instead:**

1. GitHub Actions starts a pipeline run
2. GitHub generates a short-lived JWT token signed with GitHub's private key, containing: `repo:RohanReddy-M/observeops`, `ref:refs/heads/main`, `workflow:deploy`
3. GitHub Actions calls AWS `sts:AssumeRoleWithWebIdentity`, presenting the JWT
4. AWS verifies the JWT using GitHub's public keys (fetched from `https://token.actions.githubusercontent.com`)
5. AWS returns temporary credentials: Access Key + Secret + Session Token, valid for 1 hour
6. Pipeline uses these to push to ECR, apply Terraform, run deploy script
7. Credentials expire automatically

**What this means in practice:**

- There is no secret stored in GitHub (no `AWS_ACCESS_KEY_ID`, no `AWS_SECRET_ACCESS_KEY`)
- The credentials are scoped to the exact repository, branch, and workflow that requested them
- If the credentials somehow leak in a log, they expire in 1 hour
- If GitHub is compromised, attackers cannot use our OIDC role from a different repo
- Audit trail: every STS assumption is logged in CloudTrail with the full GitHub context

**The principle: short-lived credentials always beat long-lived credentials.**

## The IAM Trust Policy

The AWS IAM role has a trust policy that only allows assumption from:
- Our specific GitHub repository (`repo:RohanReddy-M/observeops:*`)
- No other repo, no other AWS account, no IAM users

```json
{
  "Condition": {
    "StringLike": {
      "token.actions.githubusercontent.com:sub": "repo:RohanReddy-M/observeops:*"
    }
  }
}
```

Even if GitHub's OIDC service is compromised, an attacker cannot use our role with a different repository's token.

## Consequences

**Positive:**
- No long-lived credentials anywhere
- Credentials expire automatically — no rotation needed
- Scoped to exact repository — blast radius limited
- Full CloudTrail audit trail of every CI/CD AWS operation
- Immune to the most common IAM key leak scenarios

**Negative:**
- Initial setup is more complex than creating an IAM user
- Requires understanding of OIDC/JWT concepts
- If GitHub OIDC service is down, CI/CD cannot get credentials

## The Interview Answer

"We use OIDC instead of IAM access keys because static credentials are a liability. Every access key is a potential breach vector that needs rotation, monitoring, and can leak in hundreds of ways. With OIDC, GitHub Actions gets temporary credentials that expire in one hour, scoped to our specific repository. There is no secret to store, no secret to rotate, and no secret to leak. The trust policy is cryptographically bound to our repo — no other organization on GitHub can use our IAM role. This is how AWS itself recommends authenticating CI/CD pipelines in their security best practices."
