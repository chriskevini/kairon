# Kairon Documentation

This directory contains all documentation for the Kairon life-tracking system.

## Documentation Structure

### Active Documentation

| Document | Purpose | Audience |
|----------|---------|----------|
| **[TOOLING-LOCAL.md](TOOLING-LOCAL.md)** | Local development with Docker containers | Developers |
| **[TOOLING-PROD.md](TOOLING-PROD.md)** | Production operations and remote management | DevOps, Operations |
| **[DEPLOYMENT.md](DEPLOYMENT.md)** | Deployment pipeline and workflow management | DevOps, CI/CD |
| **[testing/n8n-ui-compatibility-testing.md](testing/n8n-ui-compatibility-testing.md)** | Workflow validation and testing system | Developers |

### Guidelines and Best Practices

| Document | Purpose | Location |
|----------|---------|----------|
| **AGENTS.md** | Agent guidelines, ctx pattern, n8n best practices | Root directory |
| **README.md** | Project overview and quick start | Root directory |

### Archived Documentation

Historical documentation is stored in `docs/archive/` for reference:

- Implementation plans and design decisions
- Postmortems and recovery plans
- Deprecated features and approaches
- Historical migrations and changes

## Quick Start

1. **New to Kairon?** Start with `../README.md` for project overview
2. **Setting up local development?** Read `TOOLING-LOCAL.md` for Docker-based testing
3. **Managing production systems?** Read `TOOLING-PROD.md` for remote operations
4. **Deploying changes?** Read `DEPLOYMENT.md` for pipeline details
5. **Understanding the codebase?** Read `../AGENTS.md` for patterns and guidelines

## Key Concepts

- **ctx Pattern**: Standardized data flow between n8n workflow nodes
- **Local Development**: Docker-based isolated testing environment
- **Deployment Pipeline**: Automated testing and rollback for production
- **Workflow Transformation**: Converting workflows for different environments

## Support

- Check archived docs for historical context
- Use `AGENTS.md` for implementation patterns
- Refer to `TOOLING.md` for operational procedures