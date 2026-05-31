# ADR-002: AWS Systems Manager (SSM) Instead of SSH

**Status:** Accepted
**Date:** 2026-05-01

---

## Context

We need a way to access EC2 instances for deployment and debugging. The traditional approach is SSH with a key pair and port 22 open in the security group.

## Decision

Use AWS Systems Manager Session Manager for all EC2 access. No SSH key pair distributed. Port 22 closed. No bastion host.

## Rationale

**The attack surface problem with SSH:**

Port 22 open on the internet is one of the most attacked ports in the world. Automated scanners continuously probe for:
- Default credentials
- Known SSH vulnerabilities (e.g., OpenSSH CVEs)
- Weak key algorithms
- Brute force attempts

We don't need any of this exposure to run a CI/CD pipeline or debug a server.

**How SSM works instead:**

The EC2 instance runs an SSM agent that maintains an outbound HTTPS connection to the AWS Systems Manager service. When you want a terminal session, you connect through AWS — the instance reaches out, AWS bridges the connection. The instance has **zero open inbound ports**.

An attacker scanning our VPC finds nothing to connect to on the app or obs server.

**The Capital One precedent:**

In the 2019 Capital One breach, an SSRF vulnerability allowed an attacker to reach the EC2 instance metadata service, steal IAM credentials, and exfiltrate 100 million records. One of the contributing factors was that the instance had overly permissive access and reachable services.

Our design enforces IMDSv2 (prevents SSRF credential theft) and uses SSM (eliminates SSH attack surface) as layered defenses.

**Additional benefits:**

1. **Audit trail**: Every SSM session is logged to CloudTrail. We know exactly who accessed which instance and when.
2. **No key management**: No SSH keys to rotate, distribute, or accidentally commit to git.
3. **IAM-controlled access**: Access is controlled by IAM policies, not by who has a key file.

## Consequences

**Positive:**
- Zero attack surface for remote access
- Full audit trail in CloudTrail
- No key management overhead
- Works even if the instance has no public IP

**Negative:**
- SSM Session Manager plugin must be installed on the operator's machine
- Requires outbound HTTPS from the instance (already needed for Docker pull, package updates)
- Slightly more latency than direct SSH for interactive sessions

## The Interview Answer

"We use SSM instead of SSH because port 22 is one of the most targeted ports on the internet and we don't need to expose it. SSM works the opposite way — the instance reaches out to AWS, AWS bridges the session. No inbound ports needed. Every session is logged in CloudTrail automatically. I specifically studied the Capital One breach pattern where SSRF + IMDSv1 allowed credential theft — we enforce IMDSv2 on all our instances to prevent that same attack vector."
