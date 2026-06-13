#!/usr/bin/env bash
set -euxo pipefail

# --- Docker -----------------------------------------------------------------
dnf install -y docker ruby wget
systemctl enable --now docker

# --- CodeDeploy agent ---------------------------------------------------------
cd /tmp
wget -q "https://aws-codedeploy-${region}.s3.${region}.amazonaws.com/latest/install"
chmod +x ./install
./install auto
systemctl enable --now codedeploy-agent

# --- CloudWatch agent: docker json logs + host memory ------------------------
dnf install -y amazon-cloudwatch-agent
cat >/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<'CWEOF'
{
  "agent": { "metrics_collection_interval": 60 },
  "metrics": {
    "namespace": "CWAgent",
    "append_dimensions": {
      "AutoScalingGroupName": "$${aws:AutoScalingGroupName}",
      "InstanceId": "$${aws:InstanceId}"
    },
    "aggregation_dimensions": [["AutoScalingGroupName"]],
    "metrics_collected": {
      "mem": { "measurement": ["mem_used_percent"] },
      "disk": { "measurement": ["used_percent"], "resources": ["/"] }
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/lib/docker/containers/**.log",
            "log_group_name": "${docker_log_group}",
            "log_stream_name": "{instance_id}",
            "timestamp_format": "%Y-%m-%dT%H:%M:%S"
          }
        ]
      }
    }
  }
}
CWEOF
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

# --- Boot-start the active container (instance replacement / reboot path) ----
# Normal releases install containers via CodeDeploy hooks; this only restores
# the currently-active color when a fresh instance joins the ASG.
ACTIVE_COLOR=$(aws ssm get-parameter --region "${region}" \
  --name "/${project}/${env}/ec2/active-color" --query Parameter.Value --output text || echo none)
ACTIVE_IMAGE=$(aws ssm get-parameter --region "${region}" \
  --name "/${project}/${env}/ec2/active-image" --query Parameter.Value --output text || echo none)

if [[ "$ACTIVE_COLOR" != "none" && "$ACTIVE_IMAGE" != "none" ]]; then
  PORT=${blue_port}
  [[ "$ACTIVE_COLOR" == "green" ]] && PORT=${green_port}

  aws ecr get-login-password --region "${region}" \
    | docker login --username AWS --password-stdin "${ecr_registry}"
  docker pull "$ACTIVE_IMAGE"

  SECRET_JSON=$(aws secretsmanager get-secret-value --region "${region}" \
    --secret-id "${secret_arn}" --query '{v:SecretString,id:VersionId}' --output json)
  SECRET_FP=$(echo "$SECRET_JSON" | python3 -c 'import sys,json,hashlib;print(hashlib.sha256(json.load(sys.stdin)["v"].encode()).hexdigest()[:16])')
  SECRET_VERSION=$(echo "$SECRET_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')

  docker run -d --name "podinfo-$ACTIVE_COLOR" \
    --restart unless-stopped \
    -p "$PORT:9898" \
    -e ENVIRONMENT="${env}" \
    -e COLOR="$ACTIVE_COLOR" \
    -e SECRET_FINGERPRINT="$SECRET_FP" \
    -e SECRET_VERSION_ID="$SECRET_VERSION" \
    "$ACTIVE_IMAGE"
fi
