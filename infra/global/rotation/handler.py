"""Secrets Manager rotation function for a standalone random token.

Implements the four rotation steps for a secret with no downstream
credential store: a fresh token is generated in createSecret and promoted
in finishSecret. Token format `dkyd_<32 alnum>` matches the CloudWatch Logs
data-protection custom identifier so any accidental log leak is masked.
"""
import logging
import secrets
import string

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ALPHABET = string.ascii_letters + string.digits


def handler(event, context):
    arn = event["SecretId"]
    token = event["ClientRequestToken"]
    step = event["Step"]
    client = boto3.client("secretsmanager")

    metadata = client.describe_secret(SecretId=arn)
    versions = metadata["VersionIdsToStages"]
    if token not in versions:
        raise ValueError(f"Version {token} not found for secret {arn}")
    if "AWSCURRENT" in versions[token]:
        logger.info("Version %s already AWSCURRENT, nothing to do", token)
        return
    if "AWSPENDING" not in versions[token]:
        raise ValueError(f"Version {token} not AWSPENDING for secret {arn}")

    if step == "createSecret":
        create_secret(client, arn, token)
    elif step == "setSecret":
        pass  # no downstream service to update
    elif step == "testSecret":
        test_secret(client, arn, token)
    elif step == "finishSecret":
        finish_secret(client, arn, token, versions)
    else:
        raise ValueError(f"Unknown step {step}")


def create_secret(client, arn, token):
    try:
        client.get_secret_value(SecretId=arn, VersionId=token, VersionStage="AWSPENDING")
        logger.info("createSecret: AWSPENDING already exists")
    except client.exceptions.ResourceNotFoundException:
        value = "dkyd_" + "".join(secrets.choice(ALPHABET) for _ in range(32))
        client.put_secret_value(
            SecretId=arn,
            ClientRequestToken=token,
            SecretString=value,
            VersionStages=["AWSPENDING"],
        )
        logger.info("createSecret: new AWSPENDING version stored")


def test_secret(client, arn, token):
    value = client.get_secret_value(
        SecretId=arn, VersionId=token, VersionStage="AWSPENDING"
    )["SecretString"]
    if not (value.startswith("dkyd_") and len(value) == 37):
        raise ValueError("testSecret: pending value has unexpected format")
    logger.info("testSecret: pending value validated")


def finish_secret(client, arn, token, versions):
    current = next(v for v, stages in versions.items() if "AWSCURRENT" in stages)
    client.update_secret_version_stage(
        SecretId=arn,
        VersionStage="AWSCURRENT",
        MoveToVersionId=token,
        RemoveFromVersionId=current,
    )
    logger.info("finishSecret: promoted %s to AWSCURRENT", token)
