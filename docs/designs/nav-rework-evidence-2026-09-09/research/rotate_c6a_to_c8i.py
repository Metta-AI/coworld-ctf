"""Rotate one owned benchmark slot without loading or copying GitHub credentials."""
import json
from datetime import datetime, timezone
from pathlib import Path

from metta.setup.tools.sandbox.ec2 import get_ec2_client, launch_instance, wait_for_running

ROOT = Path(__file__).resolve().parent
SOURCE_ID = "i-0b37d010a49d1a53d"
TARGET_NAME = "jamesboggs-nav-throughput-c8i"


def record(event, **fields):
    row = {"time": datetime.now(timezone.utc).isoformat(), "event": event, **fields}
    with (ROOT / "C8I_PROVISION.jsonl").open("a") as out:
        out.write(json.dumps(row) + "\n")
    print(json.dumps(row), flush=True)


def main():
    ec2 = get_ec2_client()
    reservations = ec2.describe_instances(InstanceIds=[SOURCE_ID])["Reservations"]
    assert len(reservations) == 1 and reservations[0]["OwnerId"] == "015142856185"
    source = reservations[0]["Instances"][0]
    tags = {tag["Key"]: tag["Value"] for tag in source["Tags"]}
    assert tags.get("Name") == "jamesboggs-nav-throughput-c6a"
    assert tags.get("metta:user") == "jamesboggs"
    existing = ec2.describe_instances(Filters=[
        {"Name": "tag:Name", "Values": [TARGET_NAME]},
        {"Name": "instance-state-name", "Values": ["pending", "running", "stopping", "stopped"]},
    ])["Reservations"]
    if existing:
        for reservation in existing:
            for instance in reservation["Instances"]:
                record("existing_target", instance_id=instance["InstanceId"],
                       state=instance["State"]["Name"], ip=instance.get("PublicIpAddress"))
        return
    if source["State"]["Name"] != "stopped":
        ec2.stop_instances(InstanceIds=[SOURCE_ID])
        record("source_stop_requested", instance_id=SOURCE_ID)
        ec2.get_waiter("instance_stopped").wait(InstanceIds=[SOURCE_ID])
    record("source_stopped", instance_id=SOURCE_ID)
    # Source is the vanilla Ubuntu AMI used by metta box, not a snapshot of its disk.
    instance_id = launch_instance(
        ec2, name=TARGET_NAME, instance_type="c8i-flex.4xlarge",
        key_name=source["KeyName"], sg_id=source["SecurityGroups"][0]["GroupId"],
        user_data="#!/bin/bash\nset -eu\napt-get update\napt-get install -y git curl xz-utils build-essential python3\n",
        username="jamesboggs", git_ref="20234cc7", image_id=source["ImageId"],
        repo="Metta-AI/coworld-ctf", volume_size=200,
    )
    record("target_launched", instance_id=instance_id, instance_type="c8i-flex.4xlarge")
    ip = wait_for_running(ec2, instance_id)
    record("target_running", instance_id=instance_id, ip=ip)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        details = getattr(error, "response", {}).get("Error", {})
        record("error", kind=type(error).__name__, code=details.get("Code"),
               message=details.get("Message", "See the last recorded operation; no exception locals emitted."))
        raise SystemExit(1)
