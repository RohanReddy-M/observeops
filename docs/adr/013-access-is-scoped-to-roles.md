# ADR-013: Access Is Granted to a Role, on a Named Port or Resource, and Nothing Else

**Status:** Accepted
**Date:** 2026-10-07

---

## Context

This project's documentation said "least privilege" in several places. A review compared each claim with the Terraform and the IAM policies. The words and the configuration disagreed almost everywhere:

| The documentation said | The configuration did |
|---|---|
| The app server accepts traffic from the load balancer only | Accepted all traffic, any port, from the whole VPC range. The two rules that named the load balancer pointed at ports it never uses |
| The CI role is scoped to one branch | Any branch or pull request of the repository could assume it |
| (nothing) | The CI role held `AmazonSSMFullAccess`: it could read every secret in Parameter Store and run commands on any instance in the account |
| Each component has what it needs | Both servers shared one IAM role, so the monitoring server could read and write the application's database table and pull its images |
| The instance role can use the application's table | The policy named tables as `observeops-*`, which also matched the Terraform state lock table |
| IMDSv2 is enforced on all instances | Enforced on one of two |
| Grafana requires a login | The admin password was a fixed string printed in `docker-compose.yml` and the README, on a Grafana reachable from the internet |

None of these had caused an incident. Each one is the kind of thing that turns somebody else's small bug into your large one.

## Decision

One rule, applied in three places: **name who, name what, and write the reason next to it.**

1. **Network.** A security group rule names the *security group* allowed to connect and the *port*, never an address range. The load balancer may reach port 80 on the app server. The monitoring server may reach the application's metrics ports. The app server may reach five named ports on the monitoring server. Nothing else is open, and no rule mentions the VPC range. (`terraform/modules/security`)
2. **Identity.** One IAM role per server, each listing the exact resources it uses: the app server's role names four ECR repositories, one DynamoDB table by ARN and one parameter path; the monitoring server's role has no data access at all. The CI role can be assumed only from `main` or the `production` environment and holds only the calls the pipeline makes (ADR-004).
3. **Secrets.** Anything that grants access is generated, stored in Parameter Store, and read at start-up. The SecureShip API key and the Grafana admin password are created by Terraform (`random_password`); neither appears in the repository.

## Rationale

**Why security groups reference groups, not address ranges.** "Allow 10.0.0.0/16" means "allow whatever is in the network", which includes anything added later and anything an attacker gets a foothold on. "Allow the load balancer's security group" means "allow that role". It stays correct when instances are replaced and addresses change, and it is the only form that says what was meant.

**Why this needed separate rule resources.** The app group must name the monitoring group and the monitoring group must name the app group. Written as inline `ingress` blocks, each group needs the other's ID before it can be created, and Terraform reports a cycle. Separate `aws_vpc_security_group_ingress_rule` resources let both groups be created empty and the rules be attached afterwards.

**Why one wide permission was widened on purpose.** Tightening is not always the right direction. The app server's instance-metadata hop limit was 1, the strictest setting, which stops containers from reaching the metadata service at all. SecureShip runs in a container and needs the instance role to reach DynamoDB, so in production it could never authenticate. It is now 2. The cost is that every container on that host can obtain the role, which is exactly why the role itself had to become narrow first. A control that breaks the system it protects gets removed by the first person who has to make the system work; the durable version is the loosest setting that still works, combined with a small blast radius.

**Why "write the reason next to it".** Every rule in the new security group module has a description saying which component uses it and why. A rule nobody can explain is a rule nobody dares to delete, and that is how a firewall ends up allowing everything.

## What is still wide, and known

- **Outbound traffic is unrestricted** on both servers. They need package mirrors, Docker Hub, ECR, SSM, the LLM API and Slack. Closing this properly means VPC endpoints for the AWS services and an egress proxy with an allow-list for the rest.
- **The CI role can run a shell script on the servers**, which is root on them. That is what a deploy is. The real control is who can push to `main`, and this single-maintainer repository has no branch protection or required review.
- **Prometheus is readable from the internet** at `/prometheus/` (its admin endpoints are blocked at nginx). It exposes metric names, labels and internal addresses.
- **`/fail` and `/load`** on StatusService are public endpoints that exist to cause errors and load on demand. Rate-limited, but they should not exist on a real service.
- **One API key** shared by every client, with no rotation procedure.
- **The log shipper mounts the Docker socket**, which is equivalent to root on the host.
- **IAM changes are not reported.** The audit alerter's rule lives in ap-south-1; IAM is a global service whose events are delivered in us-east-1 only.

## Consequences

**Positive**
- Each claim in the README's security section can now be pointed at a line of Terraform.
- A compromise of the monitoring server no longer gives access to the application's data, and a compromise of CI no longer gives every secret in the account.

**Negative**
- More resources (75, up from 64) and more to read.
- Adding a component now means adding a rule for it. Forgetting produces a failure that looks like a network fault: the first symptom of the new log shipper's missing rule would have been a scrape target that was down for no visible reason.

## The Interview Answer

"I wrote 'least privilege' in my README and then checked it against my own Terraform, and it was not true in seven places. The application server accepted all traffic from the VPC while the comment above the rule said load balancer only. My CI role could read every secret in the account. Two servers shared one role. So I applied one rule everywhere: name who, name what, write why. Security groups reference other groups and a port. Each server has its own role listing exact resources. Secrets are generated and read at start-up. The interesting case went the other way: my metadata hop limit was at its strictest setting and that silently stopped the application from reaching its database, so I loosened it and narrowed the role instead. And I keep a list of what is still wide, because the list is more useful to the next person than the word 'secure'."
