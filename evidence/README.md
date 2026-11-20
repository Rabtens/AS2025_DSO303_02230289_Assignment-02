# Evidence

## Cloud Architecture Lab

| Artifact | What it shows |
|---|---|
| [Saved project](Online%20Exam%20Platform%20-%20Production%20Architecture%20%282%20AZ%29.json) and [architecture image](lab-architecture.png) | The two-AZ production design |
| [Exam walkthrough](lab-walkthrough-1.png) | Exam and autosave simulation |
| [40 MB submission walkthrough](lab-walkthrough-2.png) | Upload and notification simulation |
| [AZ failure](lab-az-failure.png) | Simulated loss of one Availability Zone |

See the [lab instructions](../lab/LAB_INSTRUCTIONS.md) for replay steps.

## Live AWS deployment

| Artifact | What it verifies |
|---|---|
| [Successful GitHub Actions run](https://github.com/Rabtens/AS2025_DSO303_02230289_Assignment-02/actions/runs/44725365978) | OIDC authentication, Terraform plan and apply, and the frontend and database health checks |
| [Pipeline screenshot](github-action-workflow-pipeline.png) | Successful deployment job |
| [Frontend screenshot](aws-frontend.png) | The application served through CloudFront |
| [API health screenshot](aws-api-health.png) | The live health endpoint passed its PostgreSQL query |

Live upload and notification evidence is pending. The deployed Aurora Express cluster has one writer. The two-AZ failover evidence above comes from the lab simulation.
