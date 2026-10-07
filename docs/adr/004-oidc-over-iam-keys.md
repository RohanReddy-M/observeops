# ADR-004: OIDC Authentication for CI/CD Instead of IAM Access Keys

**Status:** Accepted
**Date:** 2026-05-01

> **Amended 2026-10-07.** The decision stands; the implementation did not match
> the text. The trust policy was `repo:RohanReddy-M/observeops:*` (any branch,
> any pull request from a branch of this repository) while this document said
> "specific branch", and the role carried the managed policies AmazonSSMFullAccess
> and AmazonEC2ContainerRegistryPowerUser. Both are now scoped as described below,
> and the full pipeline has been run with the narrower role.

---

## Context

GitHub Actions needs to push Docker images to ECR, run Terraform, and deploy to EC2. This requires AWS credentials. The traditional approach is to create an IAM user, generate access keys, and store them as GitHub secrets.

## Decision

Use OpenID Connect (OIDC) to give GitHub Actions temporary AWS credentials. The role can be assumed only by this repository's `main` branch or its `production` environment. No long-lived access keys anywhere.

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
2. GitHub issues the job a short-lived JWT signed with GitHub's private key. Its `sub` (subject) claim says where the job runs: `repo:RohanReddy-M/observeops:ref:refs/heads/main` for a job on main, or `repo:RohanReddy-M/observeops:environment:production` for a job that declares that environment. Its `aud` (audience) claim is `sts.amazonaws.com`
3. GitHub Actions calls AWS `sts:AssumeRoleWithWebIdentity`, presenting the JWT
4. AWS verifies the JWT using GitHub's public keys (fetched from `https://token.actions.githubusercontent.com`)
5. AWS returns temporary credentials: Access Key + Secret + Session Token, valid for 1 hour
6. Pipeline uses these to push to ECR, apply Terraform, run deploy script
7. Credentials expire automatically

**What this means in practice:**

- There is no secret stored in GitHub (no `AWS_ACCESS_KEY_ID`, no `AWS_SECRET_ACCESS_KEY`)
- The role can only be assumed by a token whose audience and subject match the trust policy below: this repository, on main or in the production environment
- If the credentials somehow leak in a log, they expire in 1 hour
- A workflow in any other repository cannot assume the role, because its token carries that repository's name. (This protects against other GitHub users, not against a compromise of GitHub's own token signing, which is the trust any OIDC federation rests on.)
- Audit trail: every STS assumption is logged in CloudTrail with the full GitHub context

**The principle: short-lived credentials always beat long-lived credentials.**

## The IAM Trust Policy

The role's trust policy accepts exactly two subjects (created by `scripts/bootstrap-aws-account.sh`):

```json
{
  "Condition": {
    "StringEquals": {
      "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
      "token.actions.githubusercontent.com:sub": [
        "repo:RohanReddy-M/observeops:ref:refs/heads/main",
        "repo:RohanReddy-M/observeops:environment:production"
      ]
    }
  }
}
```

The first is the image build, which runs on main. The second is the deploy job, which declares `environment: production`; declaring an environment replaces the branch in the subject, which is why both are listed. The environment is itself restricted to main in the repository settings. Without that restriction a workflow on any branch could name the environment and receive a token the role accepts.

## What the role can do

Being hard to assume is half of it; the other half is what the role is worth once assumed. It holds two inline policies and nothing else:

- push and pull images in this project's ECR repositories (`observeops/*`)
- find the app server, read one SSM parameter (the monitoring server's address), and send the `AWS-RunShellScript` document to instances tagged `Project=observeops`

That last permission is still powerful and should be described honestly: running a shell script on the application server is root on that server. So the real statement of risk is "anyone who can push to main can run code on the servers", which is what a deploy pipeline is. The control for that is branch protection and review on main, which this single-maintainer repository does not have.

## Consequences

**Positive:**
- No long-lived credentials anywhere
- Credentials expire automatically — no rotation needed
- Scoped to one branch and one environment of one repository, with only the permissions the pipeline uses
- Full CloudTrail audit trail of every CI/CD AWS operation
- Immune to the most common IAM key leak scenarios

**Negative:**
- Initial setup is more complex than creating an IAM user
- Requires understanding of OIDC/JWT concepts
- If GitHub OIDC service is down, CI/CD cannot get credentials

## The Interview Answer

"The pipeline has no AWS keys. For each job GitHub signs a token that says which repository, branch or environment the job is running in, and AWS exchanges it for credentials that last an hour, if the token matches the role's trust policy. Mine accepts two subjects: the main branch, and the production environment, which is itself limited to main. When I reviewed it I found my own trust policy said `repo:...:*`, any branch, and the role had AmazonSSMFullAccess, which meant CI could read every secret in Parameter Store. I narrowed both to what the pipeline actually calls. What is left is the honest core of any deploy role: it can run a script on the servers, so pushing to main is the real permission, and that is controlled by branch protection, not by IAM."
