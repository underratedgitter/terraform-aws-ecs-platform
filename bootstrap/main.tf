data "aws_caller_identity" "current" {}

locals {
  bucket_name = var.state_bucket_name != "" ? var.state_bucket_name : "${var.project}-tfstate-${data.aws_caller_identity.current.account_id}"
  create_ci   = var.github_repository != ""
}

resource "aws_s3_bucket" "state" {
  bucket = local.bucket_name

  # State is the one thing here that cannot be rebuilt from code.
  lifecycle {
    prevent_destroy = true
  }
}

# Every apply overwrites the state object. Without versioning, a bad apply or a
# truncated upload loses the only record of what exists.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Old state versions are small but unbounded. Keep 90 days of history.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  depends_on = [aws_s3_bucket_versioning.state]

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json
}

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid       = "DenyUnencryptedTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

# Terraform 1.10 can lock with an S3 object instead (`use_lockfile`), but the
# required_version here is 1.5, and DynamoDB locking works on every version.
# On-demand billing keeps this inside the free tier at this volume.
resource "aws_dynamodb_table" "locks" {
  name         = "${var.project}-tflocks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  lifecycle {
    prevent_destroy = true
  }
}

# ---------------------------------------------------------------------------
# GitHub Actions OIDC
#
# The alternative is a long-lived access key in a repository secret. This issues
# a credential per workflow run that expires in an hour and cannot be used from
# anywhere but the named repository.
# ---------------------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  count = local.create_ci && var.create_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # AWS verifies GitHub's certificate against its own trust store for this
  # provider, so the thumbprint is no longer load-bearing. Kept because the
  # argument is still required.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_openid_connect_provider" "existing" {
  count = local.create_ci && !var.create_oidc_provider ? 1 : 0

  url = "https://token.actions.githubusercontent.com"
}

locals {
  oidc_provider_arn = local.create_ci ? (
    var.create_oidc_provider
    ? aws_iam_openid_connect_provider.github[0].arn
    : data.aws_iam_openid_connect_provider.existing[0].arn
  ) : ""
}

data "aws_iam_policy_document" "ci_assume" {
  count = local.create_ci ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Scoped to one repository. Without this condition any GitHub Actions run in
    # the world could assume the role.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:*"]
    }
  }
}

resource "aws_iam_role" "ci_plan" {
  count = local.create_ci ? 1 : 0

  name                 = "${var.project}-ci-plan"
  description          = "Assumed by GitHub Actions to run terraform plan. Read-only plus state locking."
  assume_role_policy   = data.aws_iam_policy_document.ci_assume[0].json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "ci_readonly" {
  count = local.create_ci ? 1 : 0

  role       = aws_iam_role.ci_plan[0].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# A plan still has to read state and take the lock, which ReadOnlyAccess does not
# cover. This is the smallest addition that makes `terraform plan` work.
data "aws_iam_policy_document" "ci_state" {
  count = local.create_ci ? 1 : 0

  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
    resources = [aws_dynamodb_table.locks.arn]
  }
}

resource "aws_iam_role_policy" "ci_state" {
  count = local.create_ci ? 1 : 0

  name   = "terraform-state-access"
  role   = aws_iam_role.ci_plan[0].id
  policy = data.aws_iam_policy_document.ci_state[0].json
}
