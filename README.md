# University Online Exam & Assignment Platform (AWS)

Production-style, two-AZ AWS design for 8,000 students and ~400 staff: role-based sign-in, timed MCQ/short-answer exams with 30-second autosave, auto-marking, PDF/ZIP uploads up to 50 MB, and email when results are released. Targets: 99.9% availability during exams, survive loss of one AZ, RPO ≤ 5 min, RTO ≤ 1 h, 5-year retention, encryption in transit and at rest.

## Summary

| Layer | Services |
|---|---|
| Edge | Route 53 (optional in lab), ACM, WAF, CloudFront |
| Frontend | S3 (private, OAC) |
| Auth | Cognito (groups: student, tutor, admin) |
| API / compute | API Gateway HTTP API (JWT authorizer) → Lambda in private subnets, two AZs |
| Database | Aurora PostgreSQL Serverless v2 (writer AZ A, reader AZ B) behind RDS Proxy |
| Files | S3 uploads bucket, presigned POST, SSE-KMS, lifecycle (IA 30 d → Glacier IR 180 d → expire 5 y) |
| Async | S3 event / API → SQS (+DLQ) → Lambda workers → SES |
| Ops | CloudWatch, X-Ray, SNS, Secrets Manager, KMS, AWS Backup |
| Delivery | Terraform + GitHub Actions (OIDC), push to `main` redeploys |

## Repository map

| Path | Content |
|---|---|
| [architecture/architecture.md](architecture/architecture.md) | Task 1: diagram, two walkthroughs, peak + AZ-loss explanation |
| [docs/services.md](docs/services.md) | Task 2: service table (role, why over alternative, configuration, connections) |
| [lab/LAB_INSTRUCTIONS.md](lab/LAB_INSTRUCTIONS.md) | Task 3: build and simulation instructions for the Cloud Architecture Lab |
| [evidence/](evidence/) | Lab image, screenshots, deployment video, logs |
| [infra/](infra/), [bootstrap/](bootstrap/) | Terraform for the whole stack, state bucket, GitHub OIDC role |
| [backend/](backend/), [frontend/](frontend/) | Lambda code (api, marker, notifier) and single-page app |
| [scripts/](scripts/) | build, seed users, run walkthroughs, simulate AZ failure |
| [.github/workflows/deploy.yml](.github/workflows/deploy.yml) | CI/CD |

## Deploy

Prerequisites: AWS credentials for a sandbox account, Terraform ≥ 1.10, Python 3.12+ and pip, AWS CLI, a GitHub repo. Region defaults to `us-east-1` (WAF and ACM for CloudFront live there).

GitHub Actions defaults to Aurora Express for the AWS Free Plan. This uses one writer, AWS-owned database encryption, and direct IAM-authenticated PostgreSQL over TLS through the Aurora internet access gateway. Set the repository variable `DB_EXPRESS` to `false` before deploying the standard private Aurora cluster with RDS Proxy on a compatible AWS account. Choose the mode before creating the database. Switching modes on an existing deployment requires migrating its data.

1. **Bootstrap (once, local state):**
   ```bash
   cd bootstrap && terraform init && terraform apply -var github_repo=<owner>/<repo>
   ```
   Note the `state_bucket` and `deploy_role_arn` outputs.
2. **Verify email addresses in SES** (sender and tutor; SES sandbox only sends to verified addresses).
3. **GitHub repo → Settings → Secrets and variables → Actions → Variables**, set these repository variables from the AWS bootstrap outputs. Run the commands from the repository root.

   | Repository variable | Command to print its value |
   |---|---|
   | `AWS_ROLE_ARN` | `terraform -chdir=bootstrap output -raw deploy_role_arn` |
   | `TF_STATE_BUCKET` | `terraform -chdir=bootstrap output -raw state_bucket` |

   Paste the complete ARN and bucket name. Also set `SES_SENDER`, `TUTOR_EMAIL`, `ALARM_EMAIL`, and optionally `AWS_REGION`.
4. **Push to `main`.** The workflow builds the Lambda package, runs `terraform plan/apply`, invalidates CloudFront and smoke-tests `/` and `/api/health`. Pull requests run plan only.
   *Manual alternative:*
   ```bash
   scripts/build.sh
   cd infra
   terraform init -backend-config="bucket=<state_bucket>" -backend-config="key=exam-platform/terraform.tfstate" -backend-config="region=us-east-1" -backend-config="use_lockfile=true"
   terraform apply -var ses_sender=<you> -var tutor_email=<you> -var alarm_email=<you>
   ```
5. **Create demo users and run the walkthroughs:**
   ```bash
   scripts/seed.sh                                   # tutor@example.com / student@example.com
   scripts/demo.sh | tee evidence/demo-output.txt    # walkthrough 1 and 2
   EXAM_ID=1 scripts/az-failure.sh failover          # AZ-loss simulation, writes evidence/az-failure-autosave.log
   ```
   Open the `site_url` output in a browser to show the UI (sign in, autosave, upload) for the video.

Optional custom domain: pass `-var domain_name=exams.example.edu -var hosted_zone_id=Z123...`.

## Simulate the Cloud Architecture Lab (Task 3)

Upload [lab/LAB_INSTRUCTIONS.md](lab/LAB_INSTRUCTIONS.md) to the lab, build, run simulations A (exam autosave), B (40 MB upload), C (AZ loss), and export the image to `evidence/`.

## Tear down

```bash
cd infra && terraform destroy -var ses_sender=x -var tutor_email=x -var alarm_email=x
cd ../bootstrap && terraform destroy -var github_repo=<owner>/<repo>   # only after the infra stack is gone
```
The lab sets `force_destroy` on buckets and `skip_final_snapshot` on Aurora so this works. AWS Backup recovery points may need deleting in the console first. NAT gateways and Aurora cost money while running: tear down after recording evidence.

## Pre-exam runbook (peak readiness)

- 24 h before: raise `db_min_acu` (for example 4) and apply; confirm alarms and SNS subscription.
- During: watch the CloudWatch dashboard (5xx, Lambda concurrency, ACU, queue depth).
- Raise Lambda/API Gateway account quotas ahead of exam week if needed.

## Honest limitations

- Not validated by `terraform validate`/`plan` in the authoring environment (Terraform was not installed); run `terraform validate` first and fix any version-specific issues.
- Lab shortcuts: AdministratorAccess for the deploy role, no final DB snapshot, `force_destroy` buckets, ID token passed to API (production: shorter tokens, refresh flow, MFA for staff), tutor notification goes to one configured address.
- DB schema is created on first Lambda cold start; use a migration tool in production.
- Evidence files (lab image, video, screenshots) must be produced by you from the lab and your AWS account.
