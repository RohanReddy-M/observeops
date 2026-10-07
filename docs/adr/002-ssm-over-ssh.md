# ADR-002: AWS Systems Manager (SSM) Instead of SSH

**Status:** Accepted
**Date:** 2026-05-01

> **Amended 2026-10-07.** Until this date Terraform still created an EC2 key pair
> and installed it on both instances. Port 22 was closed everywhere, so the key
> could not be used, but it was a credential on the box and a file that
> `terraform apply` needed. It has been removed, so the decision is now true as
> written. Three statements were corrected in place: the instances do have inbound
> ports (for application traffic); CloudTrail records that a session started, not
> what was typed in it; and "IMDSv2 on all instances" was false for the
> observability instance until this date.

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

The EC2 instance runs an SSM agent that maintains an outbound HTTPS connection to the AWS Systems Manager service. When you want a terminal session, you connect through AWS — the instance reaches out, AWS bridges the connection. **No inbound port is needed for administration**, so none is open: there is no port 22 in any security group, and no key pair exists.

This removes the remote-login surface, not every surface. The instances still accept application traffic: port 80 on the app server from the load balancer, and a handful of named ports between the two servers (see `terraform/modules/security`).

**The Capital One precedent:**

In the 2019 Capital One breach, an SSRF vulnerability allowed an attacker to reach the EC2 instance metadata service, steal IAM credentials, and exfiltrate 100 million records. One of the contributing factors was that the instance had overly permissive access and reachable services.

Our design enforces IMDSv2 (prevents SSRF credential theft) and uses SSM (eliminates SSH attack surface) as layered defenses.

**Additional benefits:**

1. **Audit trail**: starting a session or sending a command is an API call (`StartSession`, `SendCommand`), so CloudTrail records who did it, to which instance, when and from where. What was *typed* in an interactive session is a different matter: that is only kept if Session Manager logging to S3 or CloudWatch Logs is switched on, and here it is not.
2. **No key management**: No SSH keys to rotate, distribute, or accidentally commit to git.
3. **IAM-controlled access**: Access is controlled by IAM policies, not by who has a key file.

## Consequences

**Positive:**
- No listening remote-access service to attack, and no keys to steal
- Full audit trail in CloudTrail
- No key management overhead
- Works even if the instance has no public IP

**Negative:**
- SSM Session Manager plugin must be installed on the operator's machine
- Requires outbound HTTPS from the instance (already needed for Docker pull, package updates)
- Slightly more latency than direct SSH for interactive sessions

## The Interview Answer

"I use SSM instead of SSH because I do not need a listening login port, so I do not have one. The agent on the instance holds an outbound connection to AWS and a session is bridged over it, which means no port 22, no key pair to distribute or rotate, and access is granted or removed in IAM. Who started a session or sent a command is in CloudTrail. I am careful to say what that does not give me: the keystrokes inside a session are only recorded if session logging is configured, and I have not configured it. Separately, both instances require IMDSv2, which is the control for the Capital One style of attack, where a server-side request forgery bug was used to read role credentials from the metadata service."
