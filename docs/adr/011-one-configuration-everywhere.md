# ADR-011: One Configuration for Local and Production, and No Required Domain

**Status:** Accepted
**Date:** 2026-10-07

---

## Context

After ADR-001 split the stack across two servers, three things had to cross between them: Prometheus had to find the application host, nginx and the OTel collector had to find the observability host, and AlertManager needed webhook URLs that are secrets.

The first implementation put placeholders such as `__APP_SERVER_IP__` in the tracked config files and had `user_data` and `deploy.sh` replace them with `sed` on the servers. It worked on AWS and had three costs that only showed up later:

- **The stack no longer ran locally.** `docker compose up` mounted the unsubstituted files. Prometheus had no reachable application target; the README still said "run locally in 2 minutes".
- **The file on the server never matched git.** Each deploy had to `git checkout` the files before `git pull` so the pull would not abort, and a comment in `deploy.sh` documents a bug where `sed -i` replaced the file's inode and the bind mount kept serving the old one.
- **A hardcoded domain made the whole stack unbuildable.** The domain was written into Terraform. When its registration lapsed, ACM validation could never complete and `terraform apply` hung until it timed out.

## Decision

1. **Config files name roles, not addresses.** They refer to `app-server` and `obs-server`. `docker-compose.yml` maps each name with `extra_hosts`: the private IP from `.env` in production, `host-gateway` (the Docker host) when the variable is unset.
2. **Secrets are read from files.** AlertManager uses `api_url_file` and `url_file`; `user_data` writes those files from SSM. The directory is gitignored.
3. **Nothing rewrites a tracked file at deploy time.** The only thing that differs between a laptop and a server is `.env`.
4. **The domain is optional.** `var.domain_name` defaults to empty: the ALB then serves HTTP on its own DNS name and no hosted zone, certificate or HTTPS listener is created. Setting it adds them.

## Rationale

**If local and production configs differ, you are testing something you do not deploy.** With one set of files, an alert rule, a scrape job or a proxy route can be exercised on a laptop and is the same bytes on the server. This is what made it possible to find, in one afternoon, that Grafana was being scraped at the wrong path and that several alert rules could not fire.

**`extra_hosts` over a templating step.** A render step (envsubst, Helm-style templates) would also work, but it adds a build stage and a second copy of every file. A hosts entry is resolved by the container's normal resolver, so the config stays static and plain.

**Files over substitution for secrets.** A URL containing `&` is mangled by a naive `sed` replacement, silently. Reading a file has no escaping rules.

**A domain is something you add to a working system.** Making it required turned an expired registration, which should cost a certificate, into a total loss of the ability to rebuild.

## Alternatives considered

*Service discovery (Consul, Cloud Map).* The right answer at many hosts. For two hosts it is more moving parts than the problem.

*`file_sd_configs` for Prometheus targets.* Solves Prometheus only; nginx and the collector would still need something else.

*Keep the placeholders and add a "render for local" script.* Keeps two code paths, which is the actual problem.

## Consequences

**Positive**
- `docker compose up -d` works on a laptop with every scrape target up.
- `deploy.sh` lost its `sed` and inode workarounds.
- `terraform apply` no longer depends on DNS.

**Negative**
- Without a domain there is no TLS: ACM cannot issue a certificate for the ALB's own name. Acceptable for a stack that is torn down between demonstrations; not for anything holding user data.
- `extra_hosts` is a Docker Compose mechanism. On Kubernetes the same role is played by Services and DNS, and these files would not carry over unchanged.
- Static names hide a second assumption: that an address, once looked up, stays right. nginx resolves an upstream once at startup, and Docker gives a recreated container a new IP. The first version of this change left nginx proxying `/api/` to an address that had since been handed to a different service. It is fixed in `nginx.conf` (`resolver` + `zone` + `resolve`, re-resolving every 10 s; measured to follow a moved backend in 3 s), but it only showed up because a failure-injection harness recreated a container without recreating nginx. A deploy never did that, so a deploy never found it.

## When this decision would change

More than a handful of hosts, or hosts that come and go on their own (auto scaling): at that point addresses in `.env` stop being manageable and real service discovery earns its complexity.

## The Interview Answer

"My local and production configs had diverged because production values were sed-ed into the files on the server. The stack stopped running locally and I did not notice, which meant I could not test my own monitoring. I changed the files to refer to hosts by role and let Compose map the role to an address from the environment, with secrets read from files. The lesson was less about the mechanism than the principle: if you cannot run the exact configuration you deploy, you are not testing it."
