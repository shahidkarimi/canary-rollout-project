resource "aws_ecr_repository" "podinfo" {
  name                 = "${var.project}/podinfo"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = true # demo repo: allow teardown with images present

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.main.arn
  }
}

resource "aws_ecr_lifecycle_policy" "podinfo" {
  repository = aws_ecr_repository.podinfo.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 20 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 20
      }
      action = { type = "expire" }
    }]
  })
}

# CodeDeploy revision bundles (EC2 appspec + hooks), keyed per env/run.
resource "aws_s3_bucket" "revisions" {
  bucket        = "${var.project}-rollout-revisions-${local.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "revisions" {
  bucket = aws_s3_bucket.revisions.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "revisions" {
  bucket                  = aws_s3_bucket.revisions.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "revisions" {
  bucket = aws_s3_bucket.revisions.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
