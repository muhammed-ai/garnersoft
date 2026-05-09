# Garnersoft

Cloud infrastructure and DevOps consulting website for startups and growing teams.

---

## Project Structure

```
garnersoft/
├── .github/
│   └── workflows/
│       ├── deploy-frontend.yml   # Manually deploy frontend to S3 + invalidate CloudFront
│       └── terraform.yml         # Plan / Apply / Destroy infrastructure via Terraform
├── frontend/
│   ├── index.html                # Single-page website
│   └── styles.css                # Stylesheet
├── infrastructure/
│   ├── main.tf                   # S3, ACM, CloudFront, Route 53
│   ├── networking.tf             # VPC, subnets, IGW, NAT, route tables, security groups
│   ├── variables.tf              # Input variables and common tags
│   └── outputs.tf                # Exported values (bucket name, CloudFront ID, URLs)
└── README.md
```

---

## Architecture

### Resource Flow

```
User Browser
     │
     ▼
Route 53 (DNS)
  garnersoft.com  ──alias──►  CloudFront Distribution
  www.garnersoft.com                    │
                                        │  HTTPS (TLS 1.2+)
                                        │  ACM Certificate (us-east-1)
                                        │  OAC (SigV4 signed requests)
                                        ▼
                                   S3 Bucket (Private)
                              index.html + styles.css
                              (no public access — OAC only)
```

### CI/CD Flow

```
Developer
    │
    ▼
GitHub Repository
    │
    ├── terraform.yml (manual trigger)
    │       │
    │       ├── plan   ──► Terraform Plan output
    │       ├── apply  ──► Provisions AWS resources
    │       └── destroy──► Tears down AWS resources
    │
    └── deploy-frontend.yml (manual trigger)
            │
            ├── OIDC Auth ──► AWS IAM Role (no static credentials)
            ├── S3 Sync   ──► Uploads frontend/ to S3 bucket
            └── CloudFront Invalidation ──► Clears edge cache
```

### Networking Layout

```
VPC (10.0.0.0/16)
│
├── us-east-1a
│   ├── Public Subnet  ──► NAT Gateway ──► Elastic IP
│   └── Private Subnet ──► Private Route Table ──► NAT Gateway
│
├── us-east-1b
│   ├── Public Subnet  ──► NAT Gateway ──► Elastic IP
│   └── Private Subnet ──► Private Route Table ──► NAT Gateway
│
└── us-east-1c
    ├── Public Subnet  ──► NAT Gateway ──► Elastic IP
    └── Private Subnet ──► Private Route Table ──► NAT Gateway

Internet Gateway ◄──► Public Route Table ◄──► All Public Subnets

Security Groups:
  public-sg  : inbound 80/443 from 0.0.0.0/0
  private-sg : inbound all TCP from public-sg only
```

---

## Architecture Diagram

The full architecture diagram is available as a draw.io file: [`architecture.drawio`](./architecture.drawio)

Open it at [app.diagrams.net](https://app.diagrams.net) → File → Open from → Device → select `architecture.drawio`.

The diagram covers:
- DNS flow: Route 53 → CloudFront → S3 (private, OAC only)
- TLS: ACM certificate attached to CloudFront
- CI/CD: GitHub Actions → OIDC → S3 sync + CloudFront cache invalidation
- Terraform state: S3 backend
- Networking: VPC, public/private subnets (x3 AZs), NAT Gateways, IGW, security groups, route tables

---

## Prerequisites

| Requirement | Detail |
|---|---|
| AWS Account | With Route 53 hosted zone for `garnersoft.com` |
| GitHub OIDC | IAM role configured to trust `token.actions.githubusercontent.com` |
| Terraform state bucket | Create `garnersoft-terraform-state` S3 bucket manually before first `terraform init` |
| GitHub Secrets | `AWS_ROLE_ARN`, `AWS_REGION`, `S3_BUCKET_NAME`, `CLOUDFRONT_DISTRIBUTION_ID` |

---

## Deployment Steps

### 1. Bootstrap Terraform state bucket (one-time, manual)

```bash
aws s3 mb s3://garnersoft-terraform-state --region us-east-1
aws s3api put-bucket-versioning \
  --bucket garnersoft-terraform-state \
  --versioning-configuration Status=Enabled
```

### 2. Provision infrastructure

Trigger the **Terraform Infrastructure** workflow from GitHub Actions → select `apply`.

After apply completes, copy the `cloudfront_distribution_id` output value and add it as the `CLOUDFRONT_DISTRIBUTION_ID` GitHub secret.

### 3. Point domain nameservers to Route 53

In your domain registrar, update the nameservers to the four NS values shown in the Route 53 hosted zone.

### 4. Deploy the website

Trigger the **Deploy Frontend to S3** workflow from GitHub Actions.

---

## GitHub Actions Workflows

| Workflow | Trigger | What it does |
|---|---|---|
| `terraform.yml` | Manual (plan / apply / destroy) | Provisions or tears down all AWS infrastructure |
| `deploy-frontend.yml` | Manual | Syncs `frontend/` to S3 and invalidates CloudFront cache |

---

## Infrastructure Resources

| Resource | Purpose |
|---|---|
| S3 Bucket | Stores static website files — private, accessible only via OAC |
| S3 Versioning | Enables rollback to previous deployments |
| ACM Certificate | Free TLS certificate for HTTPS on CloudFront |
| CloudFront OAC | Signs requests from CloudFront to S3 using SigV4 — replaces public bucket access |
| CloudFront | Global CDN, HTTPS termination, edge caching |
| Route 53 Records | DNS routing for apex and www to CloudFront |
| VPC | Isolated private network for all AWS resources |
| Public Subnets (x3) | Host NAT Gateways and future load balancers |
| Private Subnets (x3) | Host EKS nodes and app servers, no public exposure |
| Internet Gateway | Connects VPC to the public internet |
| NAT Gateways (x3) | Outbound internet for private subnet resources |
| Elastic IPs (x3) | Static IPs for NAT Gateways |
| Route Tables | Control traffic flow between subnets and gateways |
| Public Security Group | Allows inbound 80/443 from internet |
| Private Security Group | Allows inbound only from public security group |

---

## Tech Stack

- **Frontend**: HTML5, CSS3 (no frameworks)
- **CDN**: AWS CloudFront
- **Storage**: AWS S3
- **DNS**: AWS Route 53
- **TLS**: AWS ACM
- **Networking**: AWS VPC
- **IaC**: Terraform >= 1.5
- **CI/CD**: GitHub Actions with OIDC (no static credentials)
