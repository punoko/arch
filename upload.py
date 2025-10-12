"""Upload image to openstack cloud."""

import argparse
import datetime
import hashlib
import logging
import sys
from pathlib import Path

import openstack
from openstack.image.v2.image import Image

logging.basicConfig(format="%(message)s", level=logging.INFO)
logger = logging.getLogger(__name__)

parser = argparse.ArgumentParser()
parser.add_argument("image", type=Path)
parser.add_argument("-n", "--name", type=str, default="punoko")
args = parser.parse_args()

version = datetime.datetime.now(tz=datetime.UTC).date().strftime("%Y.%m.%d")

logger.info("Connecting to openstack")
os = openstack.connect()  # requires environment variables

logger.info("Searching for old images")
filters = {"name": args.name, "visibility": "private"}
images: list[Image] = os.search_images(filters=filters)

logger.info("Preparing image metadata")
width = 10
filename = Path(args.image).resolve()
logger.info("%s: %s", "filename".rjust(width), filename)
version = datetime.datetime.now(tz=datetime.UTC).date().strftime("%Y.%m.%d")
logger.info("%s: %s", "version".rjust(width), version)
with filename.open("rb") as f:
    sha256 = hashlib.file_digest(f, "sha256").hexdigest()
logger.info("%s: %s", "sha256".rjust(width), sha256)
with filename.open("rb") as f:
    md5 = hashlib.file_digest(f, "md5").hexdigest()
logger.info("%s: %s", "md5".rjust(width), md5)

logger.info("Uploading image %s", args.name)
new = os.create_image(
    allow_duplicates=True,
    architecture="x86_64",
    disk_format="qcow2",
    filename=filename,
    hw_disk_bus="virtio",
    hw_firmware_type="uefi",
    hw_video_model="virtio",
    hw_vif_model="virtio",
    md5=md5,
    min_disk=2,
    min_ram=1,
    name=args.name,
    os_distro="arch",
    os_type="linux",
    os_version=version,
    sha256=sha256,
    timeout=600,
    visibility="private",
)
if not isinstance(new, Image):
    logger.error("Upload fail")
    sys.exit(1)
logger.info("Upload success")

logger.info("Old images to delete: %s", len(images))
for image in images:
    logger.info("Deleting image version:%s id:%s", image.os_version, image.id)
    os.delete_image(name_or_id=image.id)

logger.error("End of script")
