# terraform-aws-ecs-platform

Terraform that provisions a working AWS environment for a containerised web
service: network, container hosts, load balancer, registry, logs and alarms.
The platform is three modules wired together by one environment directory,
the environment's state lives in S3 with DynamoDB locking, and CI validates
every configuration and plans the dev environment on pull requests without
holding a single long-lived AWS key.

It exists to run [this Node service](https://github.com/underratedgitter/CI-CD-Pipeline-Automation-with-Docker-Cloud-Deployment),
which otherwise deploys to a PaaS that hides all of the below.

---

## What it builds

```
                            internet
                                │
                        ┌───────▼────────┐
                        │  ALB  :80      │   sg: 0.0.0.0/0 → :80
                        │  2 public AZs  │
                        └───────┬────────┘
                                │ ephemeral 32768-65535
                                │ (source: the ALB's security group, nothing else)
        ┌───────────────────────▼───────────────────────┐
        │  ECS cluster — EC2 capacity provider          │
        │  ┌─────────────────────────────────────────┐  │
        │  │ t3.micro  ·  ASG 1-2  ·  IMDSv2 only    │  │
        │  │   task: bridge net, dynamic host port   │  │
        │  │   256 CPU / 256 MiB, hard memory limit  │  │
        │  └─────────────────────────────────────────┘  │
        └───────┬───────────────────────┬───────────────┘
                │                       │
        ┌───────▼──────┐        ┌───────▼─────────┐
        │ ECR          │        │ CloudWatch Logs │
        │ scan on push │        │ 14-day retention│
        │ 10-image cap │        └───────┬─────────┘
        └──────────────┘                │
                               ┌────────▼──────────┐
                               │ Alarms            │
                               │ unhealthy targets │
                               │ 5xx rate > 5%     │
                               └───────────────────┘

  VPC 10.20.0.0/16 — 2 public /24, 2 private /24, IGW, optional NAT
```

---

## The decisions worth arguing about

**No NAT gateway by default.** A NAT gateway is about $32/month before data
processing — more than everything else here combined, and not in the free tier.
With `enable_nat_gateway = false` the container hosts run in the public subnets
with a public IP, because a private subnet with no NAT cannot reach ECR or the
ECS control plane and the instance simply never joins the cluster. They are not
exposed by that: the only ingress rule on them sources from the load balancer's
security group. Set it to `true` and the same code moves them to private subnets
and drops their public IPs — `workload_subnet_ids` switches, nothing else changes.

**One NAT gateway, not one per AZ**, when it is on. Halves the cost and creates a
single-AZ dependency for outbound traffic. Correct for dev, wrong for production,
and written down here so it is a decision rather than an oversight.

**`bridge` networking with a dynamic host port**, not `awsvpc`. A t3.micro
supports two ENIs in total, so `awsvpc` caps the host at roughly one task and
makes a rolling deploy impossible on a single node. Dynamic ports let the new
task come up beside the old one.

**No CPU limit on the task, a hard memory limit.** CPU is compressible — a task
over its share is slowed. Memory is not: over the limit, something is killed.
Setting a CPU limit throttles the container at its quota even on an idle host,
which surfaces as latency nobody can explain from the dashboards.

**A hand-written task execution policy** instead of `AmazonECSTaskExecutionRolePolicy`.
The managed policy grants ECR read on every repository in the account and log
writes to every group. The one in `modules/service` grants the same actions
scoped to this repository ARN and this log group ARN. `ecr:GetAuthorizationToken`
stays on `*` because it is account-level and cannot be scoped — that one is worth
knowing rather than pretending away.

**Task role separate from execution role, and empty.** The execution role belongs
to the ECS agent — it pulls the image and creates log streams. The task role
belongs to the application. The app calls no AWS API today, so its role has no
policies. Anything it needs later attaches there, not to the execution role,
which is the mistake that quietly gives a web process permission to pull every
image in the account.

**No SSH.** No key pair, no port 22, anywhere. `AmazonSSMManagedInstanceCore` on
the instance role means access is `aws ssm start-session`, which is authenticated
by IAM and logged in CloudTrail.

**IMDSv2 required.** `http_tokens = "required"` on the launch template. IMDSv1
answers any process that can make an HTTP request, which turns an SSRF in the app
into the instance role's credentials.

**OIDC for CI, not an access key.** `bootstrap` creates a role GitHub Actions
assumes through the GitHub OIDC provider, with the trust policy scoped by
`sub` to this one repository. Credentials last an hour and cannot be replayed
from anywhere else. The alternative — an access key in a repository secret — is a
permanent credential in a place a lot of people can read.

**Terraform owns the service, CI owns the release.** The ECS service ignores
changes to `task_definition` and `desired_count`, so a deploy that registers a new
task revision does not show up as drift, and a `terraform apply` does not roll the
running version back to whatever the tfvars said.

---

## Cost

Sized to sit inside the 12-month AWS free tier. Numbers are `ap-south-1`,
on-demand, as a sanity check rather than a quote.

| | Free tier | After it lapses |
|---|---|---|
| EC2 `t3.micro` × 1 | 750 h/month | ~$7.50/month |
| Application Load Balancer | 750 h/month + 15 LCU | ~$18/month |
| EBS gp3 30 GiB | 30 GiB | ~$2.40/month |
| ECR | 500 MB | $0.10/GB/month |
| S3 state + DynamoDB locks | 5 GB S3 / 25 GB DynamoDB | pennies |
| CloudWatch Logs + 2 alarms | 5 GB ingest, 10 alarms | $0.50/GB |
| **NAT gateway** *(off by default)* | **not included** | **~$32/month + $0.045/GB** |

`terraform destroy` in `envs/dev` removes everything except the state bucket,
the lock table and the CI role, all of which live in `bootstrap`; the bucket and
table carry `prevent_destroy`.

---

## Running it

Needs Terraform ≥ 1.17.1 (what every `required_version` pins), the AWS CLI and
Docker, plus credentials for an account you are willing to spend in.

```bash
# 1. State backend, one time per account.
cd bootstrap
terraform init
terraform apply -var='github_repository=underratedgitter/terraform-aws-ecs-platform'
terraform output backend_block     # values for step 2

# 2. Point the dev environment at that backend.
cd ../envs/dev
cp backend.hcl.example backend.hcl        # bucket, region and table from above
cp terraform.tfvars.example terraform.tfvars
terraform init -backend-config=backend.hcl

# 3. Create the ECR repository first. The service waits for tasks to reach a
#    steady state, and they cannot start from an empty repository.
terraform apply -target=module.service.aws_ecr_repository.this

# 4. Build and push the image as the tag in terraform.tfvars (default: latest).
#    The terraform output calls need envs/dev as the working directory; the
#    docker build needs the application's Dockerfile as its context.
REGISTRY="$(terraform output -raw ecr_repository_url | cut -d/ -f1)"
IMAGE="$(terraform output -raw ecr_repository_url):latest"
aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"
docker build -t "$IMAGE" /path/to/application
docker push "$IMAGE"

# 5. Read the plan before applying it.
terraform plan -out=tfplan
terraform apply tfplan

# 6. Open the service.
terraform output url
```

`bootstrap` creates the GitHub OIDC provider by default. An account can hold only
one, so if it already exists pass `-var='create_oidc_provider=false'` and the
configuration reads the existing provider instead.

Steps 3 and 4 are only needed on the first deploy, when the repository is empty.
If you change `image_tag` in `terraform.tfvars`, push that tag rather than
`latest`: after the first deploy it is only a bootstrap value, and a release is
a new task revision.

Do not set `desired_count = 0` to get around this: the service ignores changes to
`desired_count`, so raising it later would not take effect.

### Tearing it down

```bash
cd envs/dev && terraform destroy
```

The state bucket and lock table survive on purpose. Remove `prevent_destroy` in
`bootstrap/main.tf` first if you really want them gone.

---

## Layout

```
bootstrap/            S3 state bucket, DynamoDB lock table, GitHub OIDC role.
                      Local state — it creates the bucket everything else uses.
modules/
  network/            VPC, subnets across 2 AZs, IGW, optional NAT, optional
                      flow logs, and an emptied default security group.
  ecs-cluster/        ECS cluster, launch template, ASG, capacity provider,
                      instance role. AMI resolved from SSM, not hardcoded.
  service/            ALB, target group, listener, ECR repository with a
                      lifecycle policy, log group, both IAM roles, task
                      definition, service, and two CloudWatch alarms.
envs/dev/             Wires the three modules together and sets the container's
                      NODE_ENV and PORT. One file to copy for a second
                      environment.
```

---

## CI

`.github/workflows/terraform.yml` runs on every push to `main` and every pull
request that targets it.

- **fmt, validate, lint** — `terraform fmt -check -recursive` and
  `terraform validate` with `-backend=false`, so validation needs no AWS
  credentials at all. Runs against `bootstrap`, `envs/dev` and each module
  separately, because a module that is only ever validated through its caller
  stops being independently valid without anyone noticing. `tflint` runs
  recursively over the same tree.
- **Trivy config scan** — HIGH and CRITICAL misconfiguration check on the HCL,
  with `--exit-code 0` so it reports rather than blocks. Results are uploaded as
  SARIF so findings land in the Security tab rather than scrolling past in a log.
- **plan on pull requests** — runs after `static` passes, assumes the OIDC role,
  plans `envs/dev`, and posts the output as a PR comment. Skips cleanly when
  `AWS_ROLE_ARN` or `TF_STATE_BUCKET` is not set, so a fork does not fail on a
  credential it was never going to have.

Repository variables it reads: `AWS_ROLE_ARN`, `AWS_REGION`, `TF_STATE_BUCKET`,
`TF_LOCK_TABLE` — the values of `bootstrap`'s `ci_role_arn`, `region`,
`state_bucket` and `lock_table` outputs. No secrets.

---

## What this deliberately does not do

Worth saying, since the gap between what a repository claims and what it contains
is the thing that makes the rest of it hard to trust:

- **No HTTPS.** The listener is HTTP on port 80. TLS needs a domain and an ACM
  certificate, and neither should be invented in a public example. `values` for a
  443 listener are a small addition once a real hostname exists.
- **No multi-account structure.** One account, one environment directory. A real
  org separates dev and prod into accounts and assumes across.
- **No remote-state consumers.** A second environment would copy `envs/dev`; at
  more than two, this wants a proper layered structure or Terragrunt.
- **No autoscaling on the service.** The ASG scales hosts through the capacity
  provider; the ECS service itself sits at a fixed `desired_count`. Application
  autoscaling on ALB request count per target is the obvious next thing.
- **No deploy pipeline.** CI validates and plans; it never applies. Registering
  the new task revision and updating the service is left to whatever ships the
  application.

---

## License

MIT.
