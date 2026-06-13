# Self-signed cert imported into ACM (no domain available). Browsers and
# smoke tests use -k / skip-verify; trade-off documented in the README.
resource "tls_private_key" "alb" {
  algorithm = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_self_signed_cert" "alb" {
  private_key_pem = tls_private_key.alb.private_key_pem

  subject {
    common_name  = "${local.name}.podinfo.internal"
    organization = "canary-rollout"
  }

  validity_period_hours = 24 * 365
  allowed_uses          = ["key_encipherment", "digital_signature", "server_auth"]
}

resource "aws_acm_certificate" "alb" {
  private_key      = tls_private_key.alb.private_key_pem
  certificate_body = tls_self_signed_cert.alb.cert_pem
}

resource "aws_lb" "main" {
  name               = "${local.name}-alb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
}

resource "aws_lb_target_group" "blue" {
  name     = "${local.name}-blue"
  port     = local.blue_port
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  deregistration_delay = 10

  health_check {
    path                = "/healthz"
    matcher             = "200-399"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_target_group" "green" {
  name     = "${local.name}-green"
  port     = local.green_port
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  deregistration_delay = 10

  health_check {
    path                = "/healthz"
    matcher             = "200-399"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate.alb.arn

  default_action {
    type = "forward"

    forward {
      target_group {
        arn    = aws_lb_target_group.blue.arn
        weight = 100
      }
      target_group {
        arn    = aws_lb_target_group.green.arn
        weight = 0
      }
      stickiness {
        enabled  = false
        duration = 1
      }
    }
  }

  lifecycle {
    # Canary weights are shifted at deploy time by the CodeDeploy hooks;
    # Terraform must tolerate that drift instead of resetting traffic.
    ignore_changes = [default_action]
  }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# Deploy-time state the hooks read/write (which color currently serves).
resource "aws_ssm_parameter" "active_color" {
  name  = "/${var.project}/${var.env}/ec2/active-color"
  type  = "String"
  value = "none"

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "active_image" {
  name  = "/${var.project}/${var.env}/ec2/active-image"
  type  = "String"
  value = "none"

  lifecycle {
    ignore_changes = [value]
  }
}
