data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# --- instance role -----------------------------------------------------------
data "aws_iam_policy_document" "instance_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${local.name}-instance"
  assume_role_policy = data.aws_iam_policy_document.instance_trust.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cw_agent" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

data "aws_iam_policy_document" "instance" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [local.global.ecr_repository_arn]
  }

  statement {
    sid       = "Revisions"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${local.global.revisions_bucket}/*"]
  }

  statement {
    sid       = "Secret"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [local.global.secret_arn]
  }

  statement {
    sid       = "Kms"
    actions   = ["kms:Decrypt"]
    resources = [local.global.kms_key_arn]
  }

  statement {
    sid       = "DeployState"
    actions   = ["ssm:GetParameter", "ssm:PutParameter"]
    resources = ["arn:aws:ssm:${var.region}:*:parameter/${var.project}/${var.env}/*"]
  }

  # The elected leader instance performs the weighted canary shift.
  statement {
    sid     = "CanaryShift"
    actions = ["elasticloadbalancing:ModifyListener"]
    resources = [
      "arn:aws:elasticloadbalancing:${var.region}:*:listener/app/${local.name}-alb/*",
    ]
  }

  statement {
    sid = "CanarySignals"
    actions = [
      "elasticloadbalancing:DescribeLoadBalancers",
      "elasticloadbalancing:DescribeListeners",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeTargetHealth",
      "cloudwatch:DescribeAlarms",
      "autoscaling:DescribeAutoScalingGroups",
      "ec2:DescribeInstances",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "instance" {
  name   = "podinfo-host"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance.json
}

resource "aws_iam_instance_profile" "instance" {
  name = "${local.name}-instance"
  role = aws_iam_role.instance.name
}

# --- launch template + ASG (exactly 2 hosts) ---------------------------------
resource "aws_launch_template" "podinfo" {
  name_prefix   = "${local.name}-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.instance.name
  }

  vpc_security_group_ids = [aws_security_group.instance.id]

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 2          # containers need creds via IMDS
  }

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tpl", {
    region           = var.region
    project          = var.project
    env              = var.env
    blue_port        = local.blue_port
    green_port       = local.green_port
    ecr_registry     = split("/", local.global.ecr_repository_url)[0]
    secret_arn       = local.global.secret_arn
    docker_log_group = local.docker_log_group
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${local.name}-podinfo"
      Project     = "canary-rollout"
      Environment = var.env
    }
  }
}

resource "aws_autoscaling_group" "podinfo" {
  name                = "${local.name}-asg"
  min_size            = 2
  max_size            = 2
  desired_capacity    = 2
  vpc_zone_identifier = aws_subnet.public[*].id

  # Instances live in both TGs permanently; the listener's weighted forward
  # decides which color receives traffic.
  target_group_arns = [
    aws_lb_target_group.blue.arn,
    aws_lb_target_group.green.arn,
  ]

  health_check_type         = "EC2"
  health_check_grace_period = 120

  launch_template {
    id      = aws_launch_template.podinfo.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${local.name}-podinfo"
    propagate_at_launch = true
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }
}

resource "aws_cloudwatch_log_group" "docker" {
  name              = local.docker_log_group
  retention_in_days = 14
}
